#!/bin/sh
# wiki-sync: prepares the folder SilverBullet works on, in one of two modes
# picked by MARKDOWN_VAULT_MCP_GIT_REPO_URL, the same switch the MCP server uses.
#
# Without git (URL unset; WIKI_VOLUME=vault-data): the wiki works directly on
# the server's own vault volume. This script only hands a fresh volume to the
# server's user, copies the wiki settings in and idles; the server's file
# watcher picks browser edits up by itself.
#
# With git (URL set; WIKI_VOLUME unset or wiki-data): keeps the wiki's own
# working copy of the vault in step with the vault repo on GitHub, so edits
# made in the browser reach the MCP server through git and agents' edits reach
# the browser.
#
# It reuses the MCP server's own git settings from .env, so both writers behave
# the same way:
#   MARKDOWN_VAULT_MCP_GIT_REPO_URL / _GIT_USERNAME / _GIT_TOKEN   remote + auth
#   MARKDOWN_VAULT_MCP_GIT_COMMIT_NAME / _GIT_COMMIT_EMAIL          identity
#   MARKDOWN_VAULT_MCP_GIT_PUSH_DELAY_S     commit + push after this many seconds
#                                           with no further change (debounce)
#   MARKDOWN_VAULT_MCP_GIT_PULL_INTERVAL_S  pull this often while there is
#                                           nothing local to push
#
# Conflicts: local commits are rebased onto the remote with `-X theirs`, which
# in a rebase means the commit being replayed (the browser edit) wins on a
# conflicting hunk; non-conflicting remote changes in the same file are kept.
# A rebase that still stops (e.g. edit vs. delete) is aborted and retried on
# the next round, and the log says so.
#
# The token never lands on disk: the credential helper stored in .git/config
# reads it from this container's environment.

set -u

DIR=/data
PUSH_DELAY=${MARKDOWN_VAULT_MCP_GIT_PUSH_DELAY_S:-30}
PULL_INTERVAL=${MARKDOWN_VAULT_MCP_GIT_PULL_INTERVAL_S:-300}
TICK=5
RETRY=30

READY=/tmp/wiki-ready            # the healthcheck; the wiki waits for it
URL="${MARKDOWN_VAULT_MCP_GIT_REPO_URL:-}"
VOLUME="${WIKI_VOLUME:-wiki-data}"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) wiki-sync: $*"; }

# A wrong pairing is refused, slowly, so the restart loop stays readable.
refuse() { log "$*"; sleep "$RETRY"; exit 1; }

# Wiki settings and style from the infra repo (wiki/space/, mounted read-only):
# copied over on every start, so the repo is their source of truth. With git
# they land only on excluded paths (CONFIG.md, Library/), never in the vault
# repo. The copies go to the folder's owner, so SilverBullet, which runs as
# that user, can still write next to them (libraries it installs).
copy_settings() {
  [ -d /etc/wiki/space ] || return 0
  cp -R /etc/wiki/space/. "$DIR"/
  owner=$(stat -c %u:%g "$DIR")
  for item in /etc/wiki/space/* /etc/wiki/space/.[!.]*; do
    [ -e "$item" ] && chown -R "$owner" "$DIR/$(basename "$item")"
  done
  log "wiki settings copied in"
}

rm -f "$READY"

# --- Without git: the wiki shares the server's vault volume ---
if [ -z "$URL" ]; then
  [ "$VOLUME" = vault-data ] ||
    refuse "no git remote is set, so the wiki must share the server's volume: set WIKI_VOLUME=vault-data"
  [ -d "$DIR/.git" ] && log "note: $DIR has a .git folder; without a remote the server commits locally only"
  # A fresh named volume is root-owned. The MCP server runs as PUID:PGID and
  # SilverBullet takes its user from the folder's owner, so the folder has to
  # change hands before either starts writing.
  if [ "$(stat -c %u "$DIR")" = 0 ]; then
    chown -R "${PUID:-1000}:${PGID:-1000}" "$DIR"
  fi
  copy_settings
  touch "$READY"
  log "running without git on the server's volume; nothing to sync"
  while :; do sleep 3600; done
fi

# --- With git: own clone, synced through the vault repo ---
# The server's working tree must have one writer only: a second one would
# block its rebase and bypass its index.
[ "$VOLUME" = wiki-data ] ||
  refuse "a git remote is set, so the wiki needs its own clone: leave WIKI_VOLUME unset (wiki-data), not '$VOLUME'"

export GIT_USERNAME="${MARKDOWN_VAULT_MCP_GIT_USERNAME:-x-access-token}"
export GIT_TOKEN="${MARKDOWN_VAULT_MCP_GIT_TOKEN:?MARKDOWN_VAULT_MCP_GIT_TOKEN is not set}"
NAME="${MARKDOWN_VAULT_MCP_GIT_COMMIT_NAME:-ram} (wiki)"
EMAIL="${MARKDOWN_VAULT_MCP_GIT_COMMIT_EMAIL:?MARKDOWN_VAULT_MCP_GIT_COMMIT_EMAIL is not set}"
HELPER='!f() { echo "username=${GIT_USERNAME}"; echo "password=${GIT_TOKEN}"; }; f'

if [ ! -d "$DIR/.git" ]; then
  if [ -n "$(ls -A "$DIR")" ]; then
    log "$DIR is neither empty nor a git clone; refusing to touch it"
    exit 1
  fi
  log "cloning the vault"
  git -c credential.helper="$HELPER" clone -q "$URL" "$DIR" || exit 1
fi
cd "$DIR" || exit 1

git config credential.helper "$HELPER"
git config user.name "$NAME"
git config user.email "$EMAIL"

# SilverBullet's own files (settings, installed libraries, plug cache) stay in
# this copy only. .git/info/exclude is local: it is never committed, so the
# vault repo and the MCP server never see these paths.
cat > .git/info/exclude <<'EOF'
CONFIG.md
Library/
_plug/
.silverbullet*
EOF

copy_settings
touch "$READY"

# Rebase local commits onto the remote, then push. Returns non-zero, with the
# rebase aborted, when either step fails; the caller retries later.
sync_remote() {
  if ! git pull -q --rebase -X theirs 2>&1; then
    git rebase --abort 2>/dev/null
    log "pull --rebase failed; local commits kept, retrying in ${RETRY}s"
    return 1
  fi
  if ! git push -q 2>&1; then
    log "push failed; retrying in ${RETRY}s"
    return 1
  fi
  return 0
}

ahead() { git rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0; }

last_sig=""
changed_at=0
next_pull=0
next_retry=0
log "running: push ${PUSH_DELAY}s after the last edit, pull every ${PULL_INTERVAL}s"

while :; do
  now=$(date +%s)

  # Stage everything so content changes to new files count too; staging is
  # harmless because everything staged gets committed anyway.
  git add -A
  if ! git diff --cached --quiet; then
    sig=$(git diff --cached | sha1sum)
    if [ "$sig" != "$last_sig" ]; then
      last_sig=$sig
      changed_at=$now
    elif [ $((now - changed_at)) -ge "$PUSH_DELAY" ]; then
      files=$(git diff --cached --name-only)
      count=$(echo "$files" | wc -l | tr -d ' ')
      first=$(echo "$files" | head -1)
      if [ "$count" -gt 1 ]; then
        msg="wiki: edit $first (+$((count - 1)) more)"
      else
        msg="wiki: edit $first"
      fi
      git commit -q -m "$msg" && log "$msg"
      last_sig=""
      next_retry=0
    fi
  fi

  if [ "$(ahead)" -gt 0 ] && [ "$now" -ge "$next_retry" ] && git diff --cached --quiet; then
    if sync_remote; then
      log "pushed"
      next_pull=$((now + PULL_INTERVAL))
    else
      next_retry=$((now + RETRY))
    fi
  elif [ "$now" -ge "$next_pull" ] && git diff --cached --quiet; then
    before=$(git rev-parse HEAD)
    if git pull -q --rebase -X theirs 2>&1; then
      [ "$(git rev-parse HEAD)" != "$before" ] && log "pulled $(git rev-parse --short HEAD)"
    else
      git rebase --abort 2>/dev/null
      log "pull failed; retrying next round"
    fi
    next_pull=$((now + PULL_INTERVAL))
  fi

  sleep "$TICK"
done
