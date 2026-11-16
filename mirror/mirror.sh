#!/bin/sh
# vault-mirror: keeps a copy of the vault in an S3-compatible bucket (Google
# Cloud Storage, DigitalOcean Spaces, AWS S3, Cloudflare R2, MinIO, ...) and
# restores a new or wiped vault volume from it.
#
# Everything comes from .env; with BUCKET_NAME unset the service only reports
# ready and idles:
#   BUCKET_NAME                bucket to mirror into (unset = mirror off)
#   BUCKET_PROVIDER            rclone's S3 provider name: GCS, DigitalOcean,
#                              AWS, Cloudflare, Minio, ... (default Other)
#   BUCKET_ENDPOINT            S3 endpoint URL (not needed for AWS)
#   BUCKET_REGION              region, where the provider wants one
#   BUCKET_ACCESS_KEY / BUCKET_SECRET_KEY   S3 (HMAC) key pair
#   BUCKET_PREFIX              folder inside the bucket (default: bucket root)
#   BUCKET_SYNC_INTERVAL_S     seconds between mirror passes (default 300)
#   BUCKET_HISTORY_DAYS        days to keep replaced/deleted versions
#                              (default 30, 0 = keep forever)
#
# Layout in the bucket:
#   <prefix>/vault/                current state of the vault
#   <prefix>/history/<UTC time>/   what a pass replaced or deleted, as it was
#
# One direction only: the volume is the source, the bucket is the copy. The
# single exception is the restore at start, without git: a volume this script
# has not seen before and that holds no content is filled from a non-empty
# bucket before the MCP server and the wiki come up (they wait for this
# container's healthcheck). With git configured there is no restore: the
# server's `git clone` fills the volume, and the bucket is a second copy.
#
# Two marker files in the volume root, without git only (with git the server
# would commit them), neither mirrored:
#   .mirror-known      this volume has been seen: restored, adopted or started
#                      empty. Without it nothing is mirrored, so a wiped or
#                      swapped volume cannot empty the copy. With it the
#                      volume is mirrored as it is, even with every note
#                      deleted: the deleted notes go to history/.
#   .mirror-restoring  a restore is under way; a restart finishes it.
#
# Symlinks are not mirrored, and a bucket keeps no empty folders.

set -u

DIR=/vault
READY=/tmp/mirror-ready
KNOWN="$DIR/.mirror-known"
RESTORING="$DIR/.mirror-restoring"
INTERVAL=${BUCKET_SYNC_INTERVAL_S:-300}
HISTORY_DAYS=${BUCKET_HISTORY_DAYS:-30}
GIT_URL=${MARKDOWN_VAULT_MCP_GIT_REPO_URL:-}
RETRY=30

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) vault-mirror: $*"; }
idle() { while :; do sleep 3600; done; }

# A value that is not a positive number would turn the loop below into a spin.
case "$INTERVAL" in
  '' | *[!0-9]* | 0) log "BUCKET_SYNC_INTERVAL_S='$INTERVAL' is not a positive number; using 300"; INTERVAL=300 ;;
esac
case "$HISTORY_DAYS" in
  '' | *[!0-9]*) log "BUCKET_HISTORY_DAYS='$HISTORY_DAYS' is not a number; keeping history forever"; HISTORY_DAYS=0 ;;
esac

rm -f "$READY"

if [ -z "${BUCKET_NAME:-}" ]; then
  log "BUCKET_NAME is not set; mirror is off"
  touch "$READY"
  idle
fi

# rclone is configured through the environment only: no config file, so no
# secret on disk. The remote is called `store`.
: > /tmp/rclone.conf
export RCLONE_CONFIG=/tmp/rclone.conf
export RCLONE_CONFIG_STORE_TYPE=s3
export RCLONE_CONFIG_STORE_PROVIDER="${BUCKET_PROVIDER:-Other}"
export RCLONE_CONFIG_STORE_ACCESS_KEY_ID="${BUCKET_ACCESS_KEY:-}"
export RCLONE_CONFIG_STORE_SECRET_ACCESS_KEY="${BUCKET_SECRET_KEY:-}"
# The bucket has to exist already. Without this rclone checks for it and tries
# to create it before the first upload, which keys limited to one bucket's
# objects are not allowed to do.
export RCLONE_CONFIG_STORE_NO_CHECK_BUCKET=true
[ -n "${BUCKET_ENDPOINT:-}" ] && export RCLONE_CONFIG_STORE_ENDPOINT="$BUCKET_ENDPOINT"
[ -n "${BUCKET_REGION:-}" ] && export RCLONE_CONFIG_STORE_REGION="$BUCKET_REGION"

PREFIX=$(echo "${BUCKET_PREFIX:-}" | sed 's|^/*||; s|/*$||')
BASE="store:${BUCKET_NAME}${PREFIX:+/$PREFIX}"
LIVE="$BASE/vault"
HIST="$BASE/history"

# True when the volume holds nothing of the vault itself: only the wiki's own
# files, git's folder, this script's markers or the filesystem's lost+found
# may be there.
no_content() {
  [ -z "$(find "$DIR" -mindepth 1 -maxdepth 1 \
    ! -name lost+found ! -name .git ! -name '.mirror-*' \
    ! -name CONFIG.md ! -name Library ! -name _plug ! -name '.silverbullet*' \
    2>/dev/null | head -1)" ]
}

# The server and the wiki wait for this container, so it holds them back only
# while a restore may still be needed: git is off and either an earlier
# restore was cut short, or the volume is new to this script and has no
# content. In every other case a broken bucket setting costs the copy, never
# the service.
must_wait() {
  [ -z "$GIT_URL" ] && { [ -e "$RESTORING" ] || { [ ! -e "$KNOWN" ] && no_content; }; }
}

# Git moves files around while it clones, pulls or rebases; a pass taken in
# the middle would file the files it has not written yet under history/.
git_busy() {
  [ ! -e "$DIR/.git/HEAD" ] || [ -e "$DIR/.git/index.lock" ] ||
    [ -e "$DIR/.git/rebase-merge" ] || [ -e "$DIR/.git/rebase-apply" ]
}

# Changes whenever git rewrites the tree: a pull, a rebase, a commit.
git_stamp() {
  stat -c '%n %Y %s' "$DIR/.git/index" "$DIR/.git/HEAD" "$DIR/.git/ORIG_HEAD" 2>/dev/null
}

last_err() { tail -1 /tmp/lsf.err | cut -c1-300; }

# Prints the top level of the bucket copy. Fails when the bucket cannot be
# listed (wrong name, keys or endpoint); a missing <prefix>/vault in an
# existing bucket is simply an empty listing.
remote_listing() { rclone lsf --max-depth 1 "$LIVE" 2>/tmp/lsf.err; }

# The marker goes to the folder's owner, like everything else in the volume.
mark_known() {
  : > "$KNOWN"
  chown "$(stat -c %u:%g "$DIR")" "$KNOWN"
}

if [ -z "${BUCKET_ACCESS_KEY:-}" ] || [ -z "${BUCKET_SECRET_KEY:-}" ]; then
  log "BUCKET_NAME is set but BUCKET_ACCESS_KEY / BUCKET_SECRET_KEY are not; nothing is mirrored"
  if must_wait; then
    log "the volume may need a restore, so the server stays down until the keys are set"
  else
    touch "$READY"
  fi
  idle
fi

# --- Start without git: does this volume need a restore? ---
if [ -z "$GIT_URL" ]; then
  # New to this script and without content: a fresh install or a wiped volume.
  # The bucket decides which.
  if [ ! -e "$RESTORING" ] && [ ! -e "$KNOWN" ] && no_content; then
    until listing=$(remote_listing); do
      log "cannot list $LIVE: $(last_err); retrying in ${RETRY}s"
      sleep "$RETRY"
    done
    if [ -n "$listing" ]; then
      : > "$RESTORING"
    else
      log "the bucket copy is empty; nothing to restore"
    fi
  fi
  # The marker survives a restart in the middle of a restore, so a half-filled
  # volume is completed instead of being mirrored back over the bucket.
  if [ -e "$RESTORING" ]; then
    log "restoring the vault from $LIVE"
    until rclone copy "$LIVE" "$DIR" --exclude "/.mirror-*" --log-level NOTICE 2>&1; do
      log "restore failed; retrying in ${RETRY}s"
      sleep "$RETRY"
    done
    chown -R "${PUID:-1000}:${PGID:-1000}" "$DIR"
    mark_known
    rm -f "$RESTORING"
    log "restore done: $(find "$DIR" -type f ! -name '.mirror-*' | wc -l | tr -d ' ') files"
  fi
  if [ ! -e "$KNOWN" ]; then
    no_content || log "the volume already has content; mirroring it from now on"
    mark_known
  fi
fi

touch "$READY"
if [ "$HISTORY_DAYS" -gt 0 ]; then
  log "running: mirror to $LIVE every ${INTERVAL}s, history kept ${HISTORY_DAYS} days"
else
  log "running: mirror to $LIVE every ${INTERVAL}s, history kept forever"
fi

# Decides whether the volume may be mirrored right now.
may_mirror() {
  if [ -z "$GIT_URL" ]; then
    # Without the marker this is not the volume the script started on.
    if [ ! -e "$KNOWN" ]; then
      log "$KNOWN is gone: the volume was wiped or swapped while running; not mirroring. Restart vault-mirror to restore or adopt it"
      return 1
    fi
    return 0
  fi
  # With git the tree itself tells: nothing is mirrored while git is at work,
  # nor a tree without content over a copy that has some (a clone not yet
  # checked out, a wiped volume).
  git_busy && return 1
  if no_content; then
    if ! listing=$(remote_listing); then
      log "cannot list $LIVE: $(last_err)"
      return 1
    fi
    if [ -n "$listing" ]; then
      log "the volume has no content but the bucket does; not mirroring"
      return 1
    fi
  fi
  return 0
}

mirror_pass() {
  ran=0
  may_mirror || return 0
  ran=1
  stamp=$(date -u +%Y-%m-%dT%H%M%SZ)
  # .git: history lives in the git remote. _plug and .silverbullet*: the wiki
  # rebuilds them, and they would fill the history with noise. One attempt:
  # the next pass is the retry.
  rclone sync "$DIR" "$LIVE" --backup-dir "$HIST/$stamp" \
    --exclude "/.git/**" --exclude "/_plug/**" --exclude "/.silverbullet*" \
    --exclude "/.mirror-*" --exclude "/lost+found/**" \
    --retries 1 --log-level INFO --stats 0 >/tmp/sync.log 2>&1
  rc=$?
  # What the pass did, one line per file.
  grep ' INFO ' /tmp/sync.log |
    grep -v -e 'nothing to transfer' -e 'Set directory modification time' -e 'INFO  : *$'
  if [ "$rc" -ne 0 ]; then
    err=$(grep -e ' ERROR ' -e ' CRITICAL' -e 'Failed' /tmp/sync.log | tail -1 |
      sed 's|^[0-9/]* [0-9:]* ||' | cut -c1-300)
    log "mirror pass failed (rclone exit $rc): ${err:-no error line in the rclone output}"
  fi
}

# History folders are named by the time of the pass, so age is read from the
# name: an object's own modification time is the note's, not the deletion's.
# Only folders named like a pass are touched.
prune_history() {
  [ "$HISTORY_DAYS" -gt 0 ] || return 0
  cutoff=$(date -u -d "@$(($(date +%s) - HISTORY_DAYS * 86400))" +%Y-%m-%dT%H%M%SZ)
  rclone lsf --dirs-only "$HIST" 2>/dev/null | tr -d '/' | while read -r name; do
    case "$name" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
      *) continue ;;
    esac
    if [ "$name" \< "$cutoff" ]; then
      rclone purge "$HIST/$name" 2>&1 && log "history $name removed"
    fi
  done
}

# With git the server pulls and rebases on its own clock, and nothing here can
# lock it out: the check before a pass says nothing about the seconds the pass
# takes. A pass that git overlapped has copied a tree in motion, so it is
# taken again a few seconds later, once git is done, instead of leaving the
# copy wrong until the next interval. A pass skipped because git was busy is
# retried the same way.
mirror_round() {
  tries=1
  while :; do
    before=$(git_stamp)
    mirror_pass
    [ -n "$GIT_URL" ] || return 0
    if git_busy; then
      why="git started work during the pass"
    elif [ "$ran" -eq 1 ] && [ "$(git_stamp)" != "$before" ]; then
      why="git changed the tree during the pass"
    else
      return 0
    fi
    if [ "$tries" -ge 3 ]; then
      [ "$ran" -eq 1 ] && log "$why; leaving it to the next pass"
      return 0
    fi
    [ "$ran" -eq 1 ] && log "$why; mirroring again"
    tries=$((tries + 1))
    sleep 5
  done
}

next_prune=0
while :; do
  mirror_round
  now=$(date +%s)
  if [ "$now" -ge "$next_prune" ]; then
    prune_history
    next_prune=$((now + 86400))
  fi
  sleep "$INTERVAL"
done
