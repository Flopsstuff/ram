# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **deployment**, not an application. It stands up `pvliesdonk/markdown-vault-mcp` as a
single, always-on remote MCP server — a git-backed markdown "shared brain" that multiple
AI agents on different machines read and write concurrently, plus a self-hosted **Authelia**
OIDC provider so the server accepts **two auth paths at once (multi-auth): a static bearer
token for headless agents and OAuth 2.1 (OIDC) for GUI clients**. Everything here is a docker
compose stack plus its env template and per-service config templates. There is **no source
code, no build, no lint, no test suite** — do not invent those commands.

The **Design rationale** section of `README.md` records the "why" behind the fixed decisions
and the alternatives that were considered and dropped. (This rationale used to live in a local
`plan.md`, now removed.) Where any older design note and the committed files disagree, the
committed files win. Two things an earlier draft got wrong: cloudflared is **no longer
single-origin** — it now routes two hostnames via a mounted `cloudflared/config.yml` ingress
file (credentials stay env-driven); and auth is **no longer bearer-only** — it is multi-auth
(bearer + OAuth via Authelia). The OAuth migration is planned in the vault at
`projects/ram/oauth-authelia-plan.md`.

## Operating commands

```bash
docker compose up -d                         # bring up the stack
docker compose logs -f markdown-vault-mcp    # watch clone + FTS index build; readiness
docker compose down                          # stop (named volumes persist)
docker compose down -v                       # ALSO wipe vault-data + app-data + authelia-data (destructive)

curl -i https://<MCP_DOMAIN>/mcp                                    # expect 401 + WWW-Authenticate (no token)
curl -i https://<MCP_DOMAIN>/mcp -H "Authorization: Bearer <TOKEN>" # bearer path: expect an MCP response
curl -sI https://<AUTH_DOMAIN>/.well-known/openid-configuration         # Authelia up: 200
curl -sI https://<MCP_DOMAIN>/.well-known/oauth-authorization-server    # OIDC/multi-auth on: 200
```

CI/CD: `.github/workflows/deploy.yml` deploys to a self-hosted runner on push to `main` (and a
weekly image-refresh cron), materializing every gitignored config from a GitHub secret first
(see Configuration). "Verification" means the curls above, plus a headless agent connecting with
the bearer (`claude mcp add -t http -s user brain https://<MCP_DOMAIN>/mcp -H "Authorization: Bearer <TOKEN>"`),
plus a GUI client completing the OAuth flow (add `https://<MCP_DOMAIN>/mcp`, Auth = OAuth → log in at `<AUTH_DOMAIN>`).

## Architecture

Four services in `docker-compose.yml` (compose project `ram-brain`):

- **`init-perms`** — one-shot alpine that `chown -R 1000:1000 /vault /data`, then exits.
  Non-obvious and load-bearing: named volumes mount root-owned, the app image runs as
  UID 1000 (`appuser`), and its entrypoint fixes only `/data`, never `/vault`. Without
  this, the managed `git clone` into `/vault` dies with "Permission denied". The MCP
  service `depends_on` it with `condition: service_completed_successfully`.
- **`markdown-vault-mcp`** — the server (`serve --transport http --host 0.0.0.0 --port 8000`).
  Deliberately **no `ports:`** — the only ingress is through cloudflared. Two volumes:
  `vault-data → /vault` (git-managed clone, initially empty) and `app-data → /data`
  (FTS index + embeddings + HTTP session KV). Keeping `/data` out of `/vault` is
  mandatory so index/state never get committed to the repo.
- **`cloudflared`** — the tunnel. Credentials are still env-driven (`command: tunnel run
  ${CF_TUNNEL_ID}` + `TUNNEL_CRED_CONTENTS` inlined), but ingress is now a **mounted
  `cloudflared/config.yml`** (`--config /etc/cloudflared/config.yml`, `:ro`), because two
  public hostnames share this one tunnel and a single `TUNNEL_URL` origin can't split them.
  The file has host→service rules: `<MCP_DOMAIN> → markdown-vault-mcp:8000` and
  `<AUTH_DOMAIN> → authelia:9091`, plus a `http_status:404` catch-all. Both hostnames are
  DNS-routed (`cloudflared tunnel route dns`) to the same tunnel; the real hostnames + tunnel
  ID live only in the gitignored `config.yml`, not in committed files.
- **`authelia`** — the OIDC identity provider for the OAuth login path, reachable only through
  cloudflared at `<AUTH_DOMAIN>` (**no `ports:`**). Runs as root. Config is mounted read-only
  (`./authelia/configuration.yml`, `./authelia/users_database.yml`); all mutable state (SQLite
  + notifications) is on the **`authelia-data` named volume** at `/var/lib/authelia` so the CD
  runner's `git clean` can't wipe it. The single user in `users_database.yml` **is** the
  allowlist (deny-by-default). Token lifespans are ~1 year (`mcp_long_lived` profile;
  `id_token` must match `access_token`) because MCP clients don't reliably refresh.

Data flow: `agents ─HTTPS→ Cloudflare edge → cloudflared →` either `markdown-vault-mcp →
/vault (git) + /data` (MCP traffic) or `→ authelia` (the browser leg of the OAuth flow).
TLS terminates at the edge; inside the network it's plain HTTP. **Auth is enforced by the
MCP server — bearer token OR its own OIDC proxy (which delegates login to Authelia) — not by
Cloudflare Access.**

## Configuration

Configuration lives in three gitignored files, each with a committed `*.example` template:
`.env`, `cloudflared/config.yml`, and `authelia/configuration.yml` (+ `authelia/users_database.yml`).

`.env` (all app vars are `MARKDOWN_VAULT_MCP_*`): core vault paths, `EMBEDDING_PROVIDER=fastembed`,
the `BEARER_TOKEN`, the **OIDC block** (`OIDC_CONFIG_URL` = `https://<AUTH_DOMAIN>/.well-known/openid-configuration`,
`OIDC_CLIENT_ID=ram-brain`, `OIDC_CLIENT_SECRET` = *plaintext* whose pbkdf2 hash is in Authelia's
config, `OIDC_JWT_SIGNING_KEY` = stable 64-hex, `OIDC_REQUIRED_SCOPES=openid,email`), managed-git
settings (`GIT_REPO_URL`, `GIT_USERNAME=x-access-token`, `GIT_TOKEN` = fine-grained PAT), and the
two cloudflared vars (`CF_TUNNEL_ID`, `TUNNEL_CRED_CONTENTS`). **`AUTH_MODE` is intentionally
unset** — auto-detect enables multi-auth from bearer + OIDC both being present; forcing
`AUTH_MODE=oidc-proxy` risks disabling the bearer path.

The Authelia/cloudflared config files carry secrets **and** the real hostnames, so they are
gitignored too. Generate Authelia secrets with the `authelia crypto …` subcommands (see README);
the JWKS private key and the pbkdf2 client-secret hash are inlined into `configuration.yml`.

When adding config, update **both** the committed `*.example` template (no real values) and the
real gitignored file. **CD note:** `actions/checkout` runs `git clean`, wiping the gitignored
files, so `deploy.yml` re-materializes each from a GitHub secret every run — `DOTENV → .env`,
`CLOUDFLARED_CONFIG`, `AUTHELIA_CONFIG`, `AUTHELIA_USERS`. Adding a new config file means adding
a matching secret + a materialize step, or the runner won't have it. **After a config change you
MUST update the corresponding secret AND redeploy** — editing the local file alone does nothing
for the runner (it reads the secret, not git).

## Invariants — violating these breaks the deployment

- **No `ports:` on any service.** Ingress is cloudflared-only, by design.
- **`/data` stays separate from `/vault`.** Index/embeddings/state must never enter git.
- **Git committer identity is mandatory** (`GIT_COMMIT_NAME`/`_EMAIL`) — container git has
  no global user, so auto-commits fail silently without it.
- **Git remote must be HTTPS.** SSH remotes are rejected at startup when a token is set;
  there is no SSH auth path. The fine-grained PAT must belong to the account that owns the
  repo (a fine-grained PAT can't reach a repo where it's only a collaborator).
- **Never put Cloudflare Access in front of `<MCP_DOMAIN>` OR `<AUTH_DOMAIN>`** — it injects its
  own auth and breaks the bearer header for headless agents (the #1 "configured everything, still
  401") and the OAuth browser flow for GUI clients.
- **`OIDC_JWT_SIGNING_KEY` must be stable across restarts.** If unset/rotated, FastMCP mints an
  ephemeral key and all OAuth tokens die on restart. (Rotating it *deliberately* is the OAuth
  kill switch.) In the OAuth token lifespans, **`id_token` must match `access_token`** — its
  `exp` gates the session, so a shorter `id_token` silently caps the token's real life.
- **Authelia state stays on the `authelia-data` named volume, config stays read-only.** Point
  `storage.local.path` / notifier at `/var/lib/authelia`, never at the `/config` bind mount —
  CD's `git clean` wipes the bind-mounted config dir on every deploy.
- **Config-mounted services must be force-recreated to reload.** `docker compose up -d` does NOT
  recreate a container when only a bind-mounted config FILE's contents change, so `deploy.yml`
  force-recreates `authelia` + `cloudflared` after re-materializing their configs. A plain
  `up -d` (or editing the file on the host) silently keeps the stale in-memory config.
- **OIDC client (`ram-brain`) must satisfy the MCP OAuth flow, or login half-works then fails:**
  its `audience` whitelist must include the MCP resource (`https://<MCP_DOMAIN>` and
  `https://<MCP_DOMAIN>/mcp`) — MCP clients send it as an RFC 8707 `resource` param and Authelia
  returns `invalid_target` otherwise; and `token_endpoint_auth_method` must be
  `client_secret_basic` (FastMCP authenticates to the token endpoint with HTTP Basic) — else the
  code→token exchange fails with `invalid_client`.
- **Never commit secrets, and never place a secret inside the vault repo** — the vault is
  pushed to `github.com/<owner>/<vault-repo>`, so anything under `/vault` leaves the host. The
  real `.env`, `cloudflared/config.yml`, and `authelia/*.yml` are gitignored; only `*.example`
  templates are committed.
- The file watcher auto-disables because `GIT_PULL_INTERVAL_S > 0`. That is expected —
  external changes arrive via periodic pull, not inotify. Not a bug.

## Two-writer / concurrency model (know before touching sync)

One shared server identity — every client, whether it authenticates with the bearer token or
via OAuth, maps to the **same** single git identity for all agents. The server serializes commits
and pulls **fetch + fast-forward-only**. If the operator pushes to `<owner>/<vault-repo>` from anywhere
else (web editor, laptop clone) while the server holds un-pushed commits, histories diverge
and the ff-only pull refuses to merge — manual reconciliation required. Safest rule: edit
the vault **through the server**. Agents avoid lost updates by folder convention only
(`agents/<id>/…` private, `shared/…` append-preferred with `## [agent-id]` attribution) —
the server enforces none of this.
