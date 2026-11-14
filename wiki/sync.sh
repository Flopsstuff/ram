#!/bin/sh
# wiki-sync: keeps the wiki's working copy of the vault in step with the vault
# repo on GitHub, so edits made in the browser reach the MCP server through git
# and agents' edits reach the browser.
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

export GIT_USERNAME="${MARKDOWN_VAULT_MCP_GIT_USERNAME:-x-access-token}"
export GIT_TOKEN="${MARKDOWN_VAULT_MCP_GIT_TOKEN:?MARKDOWN_VAULT_MCP_GIT_TOKEN is not set}"
URL="${MARKDOWN_VAULT_MCP_GIT_REPO_URL:?MARKDOWN_VAULT_MCP_GIT_REPO_URL is not set}"
NAME="${MARKDOWN_VAULT_MCP_GIT_COMMIT_NAME:-ram} (wiki)"
EMAIL="${MARKDOWN_VAULT_MCP_GIT_COMMIT_EMAIL:?MARKDOWN_VAULT_MCP_GIT_COMMIT_EMAIL is not set}"
HELPER='!f() { echo "username=${GIT_USERNAME}"; echo "password=${GIT_TOKEN}"; }; f'

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) wiki-sync: $*"; }

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
