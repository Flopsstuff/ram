#!/bin/sh
# vault-mirror: keeps a copy of the vault in an S3-compatible bucket (Google
# Cloud Storage, DigitalOcean Spaces, AWS S3, Cloudflare R2, MinIO, ...) and
# restores an empty vault volume from it.
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
# single exception is the restore at start: an EMPTY volume is filled from a
# non-empty bucket before the MCP server and the wiki come up (they wait for
# this container's healthcheck). With git configured there is no restore: the
# server's `git clone` fills the volume, and the bucket is a second copy.
#
# Safety: a volume without content is never mirrored over a bucket that has
# some, so a wiped volume cannot empty the copy.

set -u

DIR=/vault
READY=/tmp/mirror-ready
RESTORING="$DIR/.mirror-restoring"
INTERVAL=${BUCKET_SYNC_INTERVAL_S:-300}
HISTORY_DAYS=${BUCKET_HISTORY_DAYS:-30}
GIT_URL=${MARKDOWN_VAULT_MCP_GIT_REPO_URL:-}
RETRY=30

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) vault-mirror: $*"; }
idle() { while :; do sleep 3600; done; }

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

# The server and the wiki wait for this container, so it holds them back only
# while a restore may still be needed: git is off and the volume has no
# content, or an earlier restore was cut short. In every other case a broken
# bucket setting costs the copy, never the service.
must_wait() { [ -z "$GIT_URL" ] && { [ -e "$RESTORING" ] || no_content; }; }

# True when the volume holds nothing worth mirroring: only the wiki's own
# files, git's folder or the filesystem's lost+found may be there.
no_content() {
  [ -z "$(find "$DIR" -mindepth 1 -maxdepth 1 \
    ! -name lost+found ! -name .git ! -name .mirror-restoring \
    ! -name CONFIG.md ! -name Library ! -name _plug ! -name '.silverbullet*' \
    2>/dev/null | head -1)" ]
}

# Git moves files around while it clones, pulls or rebases; a pass taken in
# the middle would file the files it has not written yet under history/.
git_busy() {
  [ -n "$GIT_URL" ] || return 1
  [ ! -e "$DIR/.git/HEAD" ] || [ -e "$DIR/.git/index.lock" ] ||
    [ -e "$DIR/.git/rebase-merge" ] || [ -e "$DIR/.git/rebase-apply" ]
}

last_err() { tail -1 /tmp/lsf.err | cut -c1-300; }

# Prints the top level of the bucket copy. Fails when the bucket cannot be
# listed (wrong name, keys or endpoint); a missing <prefix>/vault in an
# existing bucket is simply an empty listing.
remote_listing() { rclone lsf --max-depth 1 "$LIVE" 2>/tmp/lsf.err; }

if [ -z "${BUCKET_ACCESS_KEY:-}" ] || [ -z "${BUCKET_SECRET_KEY:-}" ]; then
  log "BUCKET_NAME is set but BUCKET_ACCESS_KEY / BUCKET_SECRET_KEY are not; nothing is mirrored"
  if must_wait; then
    log "the volume has no content, so the server stays down until the keys are set"
  else
    touch "$READY"
  fi
  idle
fi

# --- Restore (no-git modes, volume without content) ---
if must_wait; then
  until listing=$(remote_listing); do
    log "cannot list $LIVE: $(last_err); retrying in ${RETRY}s"
    sleep "$RETRY"
  done
  # The marker survives a restart in the middle of a restore, so a half-filled
  # volume is completed instead of being mirrored back over the bucket.
  if [ -e "$RESTORING" ] || { no_content && [ -n "$listing" ]; }; then
    log "restoring the vault from $LIVE"
    : > "$RESTORING"
    until rclone copy "$LIVE" "$DIR" --exclude "/.mirror-restoring" --log-level NOTICE 2>&1; do
      log "restore failed; retrying in ${RETRY}s"
      sleep "$RETRY"
    done
    chown -R "${PUID:-1000}:${PGID:-1000}" "$DIR"
    rm -f "$RESTORING"
    log "restore done: $(find "$DIR" -type f | wc -l | tr -d ' ') files"
  elif [ -z "$listing" ]; then
    log "the bucket copy is empty; nothing to restore"
  fi
fi

touch "$READY"
log "running: mirror to $LIVE every ${INTERVAL}s, history kept ${HISTORY_DAYS} days"

mirror_pass() {
  git_busy && return 0
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
  stamp=$(date -u +%Y-%m-%dT%H%M%SZ)
  # .git: history lives in the git remote. _plug and .silverbullet*: the wiki
  # rebuilds them, and they would fill the history with noise.
  rclone sync "$DIR" "$LIVE" --backup-dir "$HIST/$stamp" \
    --exclude "/.git/**" --exclude "/_plug/**" --exclude "/.silverbullet*" \
    --exclude "/.mirror-restoring" --exclude "/lost+found/**" \
    --log-level INFO --stats 0 >/tmp/sync.log 2>&1
  rc=$?
  grep -v -e 'nothing to transfer' -e 'Set directory modification time' /tmp/sync.log
  [ "$rc" -eq 0 ] || log "mirror pass failed (rclone exit $rc)"
  return "$rc"
}

# History folders are named by the time of the pass, so age is read from the
# name: an object's own modification time is the note's, not the deletion's.
prune_history() {
  [ "$HISTORY_DAYS" -gt 0 ] 2>/dev/null || return 0
  cutoff=$(date -u -d "@$(($(date +%s) - HISTORY_DAYS * 86400))" +%Y-%m-%dT%H%M%SZ)
  rclone lsf --dirs-only "$HIST" 2>/dev/null | tr -d '/' | while read -r name; do
    if [ "$name" \< "$cutoff" ]; then
      rclone purge "$HIST/$name" 2>&1 && log "history $name removed"
    fi
  done
}

next_prune=0
while :; do
  mirror_pass
  now=$(date +%s)
  if [ "$now" -ge "$next_prune" ]; then
    prune_history
    next_prune=$((now + 86400))
  fi
  sleep "$INTERVAL"
done
