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

`.github/workflows/okf-maintenance.yml` runs nightly (02:30 UTC) on the same runner and in the
same `ram-deploy` queue. It pipes `scripts/okf_maintenance.py` into the server container, which
calls the server's own MCP tools on localhost with the bearer from the container's env, so every
change is an ordinary server write: `okf_convert_links` (wikilinks the wiki inserts), `.md` added
to extensionless links SilverBullet leaves after a rename, `okf_generate_index` for the root
**and every folder** (a root call only creates missing indexes, it never refreshes existing
ones), then `okf_validate` + `get_broken_links`; the job fails on a conformance failure or a
broken link. It has **no checkout step on purpose**: `git clean` would delete the gitignored
`.env` and config files the running containers bind-mount from the same workspace, so it runs
the script from the last deploy's checkout.

## Architecture

Six services in `docker-compose.yml` (compose project `ram-brain`): the MCP stack (the first
three) and the browser wiki (the last three).

- **`markdown-vault-mcp`** — the server (`serve --transport http --host 0.0.0.0 --port 8000`).
  Deliberately **no `ports:`** — the only ingress is through cloudflared. Two volumes:
  `vault-data → /vault` (git-managed clone, initially empty) and `app-data → /data`
  (FTS index + embeddings + HTTP session KV). Keeping `/data` out of `/vault` is
  mandatory so index/state never get committed to the repo. Three non-obvious knobs:
  - **`entrypoint:` is overridden** to `chown` a still-root-owned `/vault` before handing
    over to the image's own `/usr/local/bin/docker-entrypoint.sh`. Load-bearing: named
    volumes mount root-owned and the stock entrypoint fixes only `/data`, so a fresh
    `vault-data` volume would kill the managed clone with "Permission denied". It runs as
    root because the image sets no `USER` — the stock entrypoint drops to `appuser` via
    `gosu` itself. (This replaced a separate one-shot `init-perms` service, which left an
    `Exited` container in every listing.)
  - **`cpus: "2.0"` + `cpu_shares: 256`.** FastEmbed/onnxruntime sizes its thread pool to
    the core count, so the boot reindex used to pin all 8 cores of the host for as long as
    the re-embed took (see "Boot-time reindex" below).
    Embeddings now come from the Gemini API, so a re-embed costs API calls rather than CPU;
    the cap stays as a guard in case the provider is switched back to local fastembed.
  - **`patches/sitecustomize.py` on `PYTHONPATH`** (mounted `./patches:/etc/ram/patches:ro`).
    Python imports it at startup; it fills the `index` that Gemini's OpenAI-compat endpoint
    omits on the first embedding (protobuf drops the default `0`). Without it the server's
    `sorted(..., key=lambda d: d.index)` raises `TypeError` on every batch, and indexing
    dies. Single-query search would still work, which hides the failure. It is a no-op for
    responses that carry every index. Remove the file, the mount and `PYTHONPATH` once the
    upstream fix (`index or 0`) ships in a release.
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
  Authelia also serves **forward-auth** (`/api/authz/forward-auth`) for the wiki; its
  `access_control.default_policy: one_factor` is what lets the logged-in user through there.
- **`wiki-sync`** — `alpine/git` running `wiki/sync.sh` (mounted `:ro`). Clones the vault into
  the **`wiki-data`** volume on first start, then commits + pushes browser edits and pulls
  agents' changes on the MCP server's own `GIT_PUSH_DELAY_S` / `GIT_PULL_INTERVAL_S` and git
  credentials from `.env`. Non-obvious knobs:
  - **Rebase with `-X theirs`**: in a rebase "theirs" is the local commit being replayed, so the
    browser edit wins a conflicting hunk. A rebase that still stops is aborted and retried; the
    commits stay local until it goes through.
  - **`.git/info/exclude`** lists SilverBullet's own files (`CONFIG.md`, `Library/`, `_plug/`,
    `.silverbullet*`). It is local to the clone and never committed, so those files never reach
    the vault repo or the agents' index. `sync.sh` rewrites it on every start.
  - **Wiki settings come from this repo.** `wiki/space/` (`CONFIG.md`: page tree open on the
    left by default; `Library/wiki-style.md`: fonts) is mounted `:ro` and copied over the clone
    on every start, so edits made through SilverBullet's own settings screen are overwritten on
    the next deploy. Both pages carry `pageDecoration.hide` so they stay out of the tree.
  - The token never touches disk: the credential helper in `.git/config` reads it from env.
  - Its healthcheck (`/data/.git` exists) gates `wiki`: SilverBullet on an empty folder would
    set up a fresh space there and the clone would then refuse the non-empty directory.
- **`wiki`** — SilverBullet (**pinned `2.12.1-slim`**, no Chromium) on `wiki-data`. Pinned
  because 3.0 moves `CONFIG.md` to `Library/Config.md` and runs `space-lua` only from `Library/`;
  bump it by hand and check `wiki/space/` still applies. **No auth of its own
  and no `ports:`**: the only way in is `wiki-proxy`. `SB_INDEX_PAGE=README` because the vault
  has no `index.md`. Runs as root (owner of the fresh volume), same as `wiki-sync`, so files
  from either side stay writable by both.
- **`wiki-proxy`** — Caddy with `wiki/Caddyfile` (mounted `:ro`): `forward_auth` to
  `authelia:9091`, then `reverse_proxy wiki:3000`. Two exceptions skip the login, both static
  files with nothing from the vault: the favicon/manifest-icon paths, served from `wiki/icons/`
  (mounted `:ro`), and **`/service_worker.js`**. Browsers refuse to register a service worker
  whose script answers with a redirect, and that request got Authelia's login redirect, which
  broke SilverBullet's offline cache with an error banner on every load. Sets
  `X-Forwarded-Proto: https` on the auth subrequest because TLS ends at Cloudflare and Authelia
  needs the public scheme to match the cookie domain and build the redirect. Cloudflared routes
  `<WIKI_DOMAIN>` here; the Authelia session cookie is on the parent domain, so one login covers
  the portal and the wiki.

**Boot-time reindex.** The server decides what changed by diffing the vault against
`/data/state.json`, a path→SHA-256 snapshot. Older server versions rewrote that snapshot only on
a full reindex, so every note written through MCP since the last one came back as `added` at the
next start and was embedded a second time (once 57 notes, ~70 s of every core). On 6.1.1 that no
longer happens: the restart after the OKF migration, which had edited all 116 notes through MCP,
reported `0 added, 0 modified` and re-embedded nothing. If a restart ever shows a large `added`
count again, this is where to look; the `cpus` cap is the guard.

Data flow: `agents ─HTTPS→ Cloudflare edge → cloudflared →` either `markdown-vault-mcp →
/vault (git) + /data` (MCP traffic) or `→ authelia` (the browser leg of the OAuth flow). The
wiki: `browser → cloudflared → wiki-proxy → (authelia forward-auth) → wiki → wiki-data`, with
`wiki-sync` moving its edits through the vault repo to the server's next pull.
TLS terminates at the edge; inside the network it's plain HTTP. **Auth is enforced by the
MCP server — bearer token OR its own OIDC proxy (which delegates login to Authelia) — not by
Cloudflare Access.**

## Configuration

Configuration lives in three gitignored files, each with a committed `*.example` template:
`.env`, `cloudflared/config.yml`, and `authelia/configuration.yml` (+ `authelia/users_database.yml`).

`.env` (all app vars are `MARKDOWN_VAULT_MCP_*`): core vault paths, the **embeddings block**
(`EMBEDDING_PROVIDER=openai` pointed at Google AI Studio: `OPENAI_BASE_URL` = Gemini's
OpenAI-compat endpoint, `OPENAI_EMBEDDING_MODEL=gemini-embedding-2`, the key in the **bare**
`OPENAI_API_KEY`, which has no prefix, plus `EMBED_CONTEXT=true`. The choice was made with
`bench/`; changing provider, model or `EMBED_CONTEXT` forces a full re-embed on the next start),
the **search tuning** (`DEFAULT_SEARCH_MODE=semantic` and `LENGTH_DOWNWEIGHT_ALPHA=0.01`. The upstream
alpha of 0.25 divides each score by `1 + 0.25·ln(chunks)` and, with Gemini's narrow score band,
ranks one-chunk notes above the right answer: top-1 accuracy was 16%, against 98% at 0.01.
Re-check alpha with `bench/` plus a staging run if the model changes),
`OKF_MODE=on` (the vault follows the Open Knowledge Format v0.2; a copy of the spec is a plain
vault note, `reference/okf/SPEC.md`, so MCP-only agents can `read` it: every note has a `type`, `status` is OKF lifecycle only and workflow state
lives in `state`, `index.md`/`log.md` are reserved. `on` adds ~205 units to the instructions, so
`INSTRUCTIONS_EXTRA` must stay around 600 units to keep the total under 2,048. `OKF_WRITE` stays
off: it re-serialises the whole frontmatter on every edit),
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
  force-recreates `authelia` + `cloudflared` after re-materializing their configs, and
  `markdown-vault-mcp`, `wiki-proxy` + `wiki-sync` for their bind-mounted patch, Caddyfile and
  sync script. A plain
  `up -d` (or editing the file on the host) silently keeps the stale in-memory config.
- **OIDC client (`ram-brain`) must satisfy the MCP OAuth flow, or login half-works then fails:**
  its `audience` whitelist must include the MCP resource (`https://<MCP_DOMAIN>` and
  `https://<MCP_DOMAIN>/mcp`) — MCP clients send it as an RFC 8707 `resource` param and Authelia
  returns `invalid_target` otherwise; and `token_endpoint_auth_method` must be
  `client_secret_basic` (FastMCP authenticates to the token endpoint with HTTP Basic) — else the
  code→token exchange fails with `invalid_client`.
- **This repo is public: nothing about the vault's content goes in it.** That covers note names,
  folder layout, employers, projects and people. The MCP instructions are the server's generated
  guidance plus `MARKDOWN_VAULT_MCP_INSTANCE_DESCRIPTION` / `_INSTRUCTIONS_EXTRA` from `.env`
  (private, via the `DOTENV` secret); keep those two generic. Vault-specific authoring rules live
  in the vault's own `_conventions.md` files. The old `instructions.md`, injected through the
  deprecated `MARKDOWN_VAULT_MCP_INSTRUCTIONS`, was removed for this reason. It also replaced the
  server's own guidance and ran past Claude Code's ~2,048-character instructions limit.
- **Never commit secrets, and never place a secret inside the vault repo** — the vault is
  pushed to `github.com/<owner>/<vault-repo>`, so anything under `/vault` leaves the host. The
  real `.env`, `cloudflared/config.yml`, and `authelia/*.yml` are gitignored; only `*.example`
  templates are committed.
- The file watcher auto-disables because `GIT_PULL_INTERVAL_S > 0`. That is expected —
  external changes arrive via periodic pull, not inotify. Not a bug.

## Two-writer / concurrency model (know before touching sync)

Two writers, each on its **own clone**, meeting only in `<owner>/<vault-repo>`:

- **The MCP server** (`/vault`). Every client, bearer or OAuth, maps to the **same** single git
  identity. It serializes its commits, pushes `GIT_PUSH_DELAY_S` after the last write, and pulls
  every `GIT_PULL_INTERVAL_S` **with a rebase**: its un-pushed commits are replayed on top of the
  remote; on a conflicting file it keeps the remote version and saves its own as a separate
  conflict file. After every pull tick it reindexes whatever changed
  (`vault.py` `_reconcile_on_tick` → `reconcile_index_with_head`), so pushed edits become
  searchable within one interval with no manual `reindex`.
- **`wiki-sync`** (`wiki-data`), on the same timings, author `<GIT_COMMIT_NAME> (wiki)`, rebasing
  with `-X theirs` so the browser edit wins a conflicting hunk.

A push from anywhere else (laptop clone, GitHub web editor) is handled the same way as the
wiki's. **Nothing may write into the server's `/vault` working tree directly**: uncommitted
files there block its rebase and never reach the index. A GitHub push webhook
(`/github-webhook`, `MARKDOWN_VAULT_MCP_GITHUB_WEBHOOK_SECRET`) would make pushes reach the
server at once; it is not enabled. Agents avoid lost updates by folder convention only
(`agents/<id>/…` private, `shared/…` append-preferred with `## [agent-id]` attribution) —
neither writer enforces this.
