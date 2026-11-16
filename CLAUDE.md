# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **deployment**, not an application. It stands up `pvliesdonk/markdown-vault-mcp` as a
single, always-on remote MCP server — a markdown "shared brain" that multiple
AI agents on different machines read and write concurrently, plus a self-hosted **Authelia**
OIDC provider so the server accepts **two auth paths at once (multi-auth): a static bearer
token for headless agents and OAuth 2.1 (OIDC) for GUI clients**. Everything here is a docker
compose stack plus its env template and per-service config templates. There is **no source
code, no build, no lint, no test suite** — do not invent those commands.

The vault always lives on the `vault-data` volume. A git remote and an S3-compatible bucket are
independent, optional add-ons chosen in `.env` (see "Storage modes" under Architecture).
**Production runs the git mode**; git-backed is one mode of four, not a requirement.

The **Design rationale** section of `README.md` records the "why" behind the fixed decisions
and the alternatives that were considered and dropped. (This rationale used to live in a local
`plan.md`, now removed.) Where any older design note and the committed files disagree, the
committed files win. Two things older notes get wrong: cloudflared is **single-origin again** —
the stack has **one public hostname**, `<DOMAIN>`, the tunnel hands every request to one nginx
(`proxy`), and nginx routes by path (`/wiki/` → the wiki, `/sso/` → Authelia, the rest → the
MCP server). The three hostnames, the mounted `cloudflared/config.yml` ingress file that split
them and the Caddy container in front of the wiki are gone; and auth is **no longer
bearer-only** — it is multi-auth (bearer + OAuth via Authelia). The OAuth migration is planned
in the vault at `projects/ram/oauth-authelia-plan.md`.

## Operating commands

```bash
docker compose up -d                         # bring up the stack
docker compose logs -f markdown-vault-mcp    # watch clone + FTS index build; readiness
docker compose down                          # stop (named volumes persist)
docker compose down -v                       # ALSO wipe vault-data + app-data + authelia-data + wiki-data (destructive)

curl -i https://<DOMAIN>/mcp                                     # expect 401 + WWW-Authenticate (no token)
curl -i https://<DOMAIN>/mcp -H "Authorization: Bearer <TOKEN>"  # bearer path: expect an MCP response
curl -sI https://<DOMAIN>/sso/.well-known/openid-configuration   # Authelia up, under /sso: 200
curl -sI https://<DOMAIN>/.well-known/oauth-authorization-server # OIDC/multi-auth on: 200
curl -sI https://<DOMAIN>/                                       # proxy up: 302 to /wiki/
curl -sI https://<DOMAIN>/wiki/                                  # no session: 302 to the portal, /sso/?rd=…
```

**The stack must work from `docker compose up -d` alone**: someone fills in the config files
once and has the whole service. Anything the service does on a schedule therefore runs inside
the stack (git sync, the bucket mirror, the OKF upkeep), never in a GitHub workflow. CD is an
optional layer on top, and this production instance uses it.

CI/CD (optional): `.github/workflows/deploy.yml` deploys to a self-hosted runner on push to `main` (and a
weekly image-refresh cron), materializing every gitignored config from a GitHub secret first
(see Configuration). "Verification" means the curls above, plus a headless agent connecting with
the bearer (`claude mcp add -t http -s user brain https://<DOMAIN>/mcp -H "Authorization: Bearer <TOKEN>"`),
plus a GUI client completing the OAuth flow (add `https://<DOMAIN>/mcp`, Auth = OAuth → log in at
the portal, `https://<DOMAIN>/sso/`), plus the wiki opening at `https://<DOMAIN>/wiki/` after
that same login.

## Architecture

Eight services in `docker-compose.yml` (compose project `ram-brain`): the MCP server, the
tunnel, the path-routing proxy, Authelia, the browser wiki (two services), the optional bucket
mirror and the OKF upkeep.

**One hostname, routed by path.** Everything public is under `<DOMAIN>`; `proxy` (nginx) decides
by path:

| Path | Goes to | Login |
| --- | --- | --- |
| `/mcp`, `/authorize`, `/token`, `/register`, `/auth/callback`, `/.well-known/...`, `/transfer/...` (upload/download links), `/health` and everything else at the root | `markdown-vault-mcp` | bearer or OAuth, enforced by the server |
| `/wiki/` | `wiki` (SilverBullet, `SB_URL_PREFIX=/wiki`) | Authelia session, checked by nginx `auth_request` |
| `/sso/` | `authelia`: login portal + OIDC provider | — |
| exactly `/` | 302 to `/wiki/` | — |

**Storage modes.** All four are set in `.env`; nothing in `docker-compose.yml` changes between
them. The switch for git is `MARKDOWN_VAULT_MCP_GIT_REPO_URL` (read by the server, `wiki-sync`
and `vault-mirror` alike), the switch for the bucket is `BUCKET_NAME`.

| Mode | `.env` | Wiki works on | An empty `vault-data` is filled from |
| --- | --- | --- | --- |
| Volume only | no `GIT_*`, no `BUCKET_*`, `WIKI_VOLUME=vault-data` | the server's `vault-data` | nothing (starts empty) |
| Git (production) | Git block, `WIKI_VOLUME` unset | its own clone on `wiki-data` | `git clone` |
| Bucket | `BUCKET_*`, `WIKI_VOLUME=vault-data` | the server's `vault-data` | the bucket |
| Git + bucket | both blocks, `WIKI_VOLUME` unset | its own clone on `wiki-data` | `git clone`; the bucket is a second copy, never restored from |

- **`markdown-vault-mcp`** — the server (`serve --transport http --host 0.0.0.0 --port 8000`).
  Deliberately **no `ports:`** — the only ingress is through cloudflared and `proxy`. It owns
  the **root of the hostname**: `proxy` sends it every path no other location claims. Two volumes:
  `vault-data → /vault` (the vault: a git-managed clone with git, a plain folder without;
  initially empty) and `app-data → /data`
  (FTS index + embeddings + HTTP session KV). Keeping `/data` out of `/vault` is
  mandatory so index/state never get committed to the repo. Without `GIT_REPO_URL` the server
  runs without git: no `get_history`/`get_diff`, and its **file watcher is on** (it is
  auto-disabled only when a periodic git pull or the webhook owns change detection), so a file
  another process writes into `/vault` is indexed about `FILE_WATCHER_DEBOUNCE_S` (default 2)
  seconds later. It `depends_on` `vault-mirror` being healthy, because an empty volume may first
  be filled from the bucket. Three non-obvious knobs:
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
- **`cloudflared`** — the tunnel, **single-origin and configured from the environment alone**:
  `command: tunnel --no-autoupdate run ${CF_TUNNEL_ID}`, `TUNNEL_CRED_CONTENTS` inlined, and
  `TUNNEL_URL=http://proxy:80` set in compose. There is no `--config`, no mounted file and no
  ingress rules: one hostname has one origin, and the split by path happens in `proxy`. (It
  used to mount a `cloudflared/config.yml` with a rule per hostname; that file, its template
  and its GitHub secret no longer exist.) The hostname is DNS-routed to the tunnel once
  (`cloudflared tunnel route dns <tunnel> <DOMAIN>`). The real name lives in Cloudflare DNS, in
  `.env` and in `authelia/configuration.yml`, never in compose or any committed file. `cloudflared/` is
  gitignored as a whole: it is where the output of `cloudflared tunnel create` tends to be
  kept.
- **`proxy`** — `nginx:stable-alpine` with `proxy/nginx.conf` mounted `:ro` at
  `/etc/nginx/conf.d/default.conf` (so the whole file sits inside nginx's `http` block), and
  `wiki/icons/` mounted `:ro` at `/srv/icons`. **No `ports:`**; it is the only thing cloudflared
  talks to, and the only way to `authelia` and `wiki`. It replaced a Caddy container
  (`wiki-proxy`) that stood in front of the wiki alone. Routing is the table above. Non-obvious
  knobs:
  - **The MCP server keeps the root** (`location /`), because MCP clients look for the OAuth
    metadata at the root of the host. Every other app gets its own prefix here; a planned admin
    panel would go under `/admin/`. A prefix must not collide with a path the server serves:
    `/auth` is taken by `/auth/callback`.
  - **Paths are passed through unchanged**: nothing strips `/sso` or `/wiki`. Each backend
    knows its own prefix instead: Authelia from the path in `server.address`, SilverBullet from
    `SB_URL_PREFIX`.
  - **No hostname in the file** (`listen 80 default_server`, `server_name _`): it answers for
    whatever host the tunnel sends and passes that `Host` on.
  - **Backend names are resolved at request time**: `resolver 127.0.0.11` (Docker's DNS) plus
    variables in `proxy_pass` (`set $mcp …`, `$authelia`, `$wiki`). With the names written
    straight into `proxy_pass`, nginx resolves them once at start: it would refuse to start
    while a backend is still coming up, and keep a dead address after a backend is recreated,
    which a deploy does to `authelia` and the server.
  - **`absolute_redirect off`**: nginx's own redirects (`/` → `/wiki/`, `/sso` → `/sso/`,
    `/wiki` → `/wiki/`) are sent as paths. An absolute one would carry `http://`, the scheme of
    this hop.
  - **Request bodies: `client_max_body_size 8m`, and `100m` under `/transfer/` only.** The
    MCP endpoint itself refuses more than 4 MiB; `/transfer/` is the server's upload and
    download links (`create_upload_link` / `create_download_link`, the token in the path is
    the credential), where the server takes up to 100 MiB, as does Cloudflare. The small cap
    is there for `/register`: it is public and has no limit of its own.
  - **`proxy_redirect http://$http_host/ /` turns the server's redirects to itself into
    paths.** The server builds its few such redirects (a trailing slash: `/mcp/` → `/mcp`)
    from the scheme it was called with, `http` on this hop; it trusts forwarded headers from
    localhost only. The rule must match this host and nothing else: the OAuth flow ends in a
    redirect to the client's own address, often `http://127.0.0.1:<port>/…`, and a rule that
    rewrote every `http://` Location turned that into a path and broke every login.
  - **No `depends_on`.** nginx has to be up before the MCP server, not after it: the server
    reads Authelia's OIDC discovery through the public URL when it starts (a failure exits it,
    and the restart policy retries), which needs the tunnel and this proxy. Depending on
    `wiki` would also make that wait for the wiki's clone.
  - **The server's routes, all exact paths**: `/mcp`, `/authorize`, `/token`, `/register`,
    `/revoke`, `/consent`, `/auth/callback`, `/health`, `/health/ready`,
    `/.well-known/oauth-authorization-server`, `/.well-known/oauth-protected-resource/mcp`
    and `/transfer/<token>`. It answers 404 for `/` and for anything under `/wiki`, `/sso` or
    `/admin`. Root `/.well-known/` must never be sent to Authelia: its discovery belongs at
    `/sso/.well-known/openid-configuration` only.
  - **The MCP location turns buffering off** (`proxy_buffering`, `proxy_request_buffering`) and
    sets read and send timeouts to **1 h**. The server's answers are streams (streamable HTTP,
    SSE): buffered, they would reach the client late or never, and an open stream may stay
    silent far longer than nginx's default 60 s.
  - **`X-Forwarded-Proto: https`** goes to every backend, with `Host` and `X-Forwarded-Host`:
    TLS ends at Cloudflare and this hop is plain HTTP, so each backend has to be told the
    public scheme; Authelia needs it to match the cookie and build the login redirect. A
    `proxy_set_header` inside a location replaces the whole set inherited from the `server`
    block, so the `/wiki/` location repeats it, and `/internal/authz` sets its own: there the
    public scheme travels in `X-Original-URL`. Keep that in mind when adding a header to one
    location.
  - **The wiki's login is `auth_request`.** Every `/wiki/` request first goes, as a subrequest
    through the `internal` location `/internal/authz`, to Authelia's
    `/api/authz/auth-request`, without the body and with the public address in
    `X-Original-URL` (`https://…`) and the method in `X-Original-Method`. A session passes, and
    the `Remote-User`/`-Groups`/`-Email`/`-Name` headers Authelia answers with are handed to
    SilverBullet. Otherwise Authelia answers 401 with the portal's address in `Location`, and
    `error_page 401 =302` turns that into the redirect to `https://<DOMAIN>/sso/?rd=…`.
  - **Two exceptions under `/wiki/` skip the login**, both static files with nothing from the
    vault: the favicon/manifest-icon files (`/wiki/.client/favicon.svg` and the like), served
    by nginx itself from `wiki/icons/` in place of SilverBullet's own, and
    **`/wiki/service_worker.js`**. Browsers refuse to register a service worker whose script
    answers with a redirect, and that request would get Authelia's login redirect, which broke
    SilverBullet's offline cache with an error banner on every load. The service worker's scope
    and the web manifest's scope are `/wiki/`, so it never sees a request for `/mcp` or `/sso`.
    That location names the upstream path in full (`proxy_pass $wiki/wiki/service_worker.js`),
    so SilverBullet is asked for this one file however the request line was spelled.
  - **A `..` path segment is refused in any encoding** (`..`, `%2e%2e`, bounded by a slash,
    `%2f`, `%5c`, the ends or a `?`) → 400. nginx picks the location from the decoded,
    normalised path but hands the backend the path as it was sent, so `/wiki/x/..%2fservice_worker.js`
    matched the public service-worker location while the backend got a different path — the way
    the login and the `/.proxy`/`.shell` blocks below were slipped on the stand. A lone encoded
    slash is left alone: SilverBullet uses `%2F` in a note path under `/.revisions/`, and no
    path here needs a `..` segment.
  - **Two SilverBullet endpoints answer 403 for everybody**, logged in or not, because a
    script in a note runs with the reader's session (both `^~` prefix matches, so no trailing
    trick reaches them): `/wiki/.shell` (runs a command in the wiki's container; also off in
    SilverBullet itself via `SB_SHELL_BACKEND`, see `wiki`) and `/wiki/.proxy` (makes
    SilverBullet fetch any URL, which from inside the compose network reaches the other
    containers and the host's network). The price of the second: SilverBullet cannot install
    a library from a URL; the wiki's settings come from `wiki/space/` anyway.
  - **`/wiki/` raises the body cap to 100m** for attachment uploads; the 8m default is for the
    MCP side. `/internal/authz` lifts the cap altogether (`client_max_body_size 0`): the login
    subrequest is checked against the caller's Content-Length, and under the 8m default an
    upload above it failed there, as a 500. The access log uses a format without the query string, and `/transfer/` turns its
    log off, so an OAuth `code` or a capability token stays out of nginx's log.
- **`authelia`** — the OIDC identity provider for the OAuth login path and the login in front
  of the wiki, reachable only through `proxy` under `/sso/` (**no `ports:`**). Runs as root.
  Config is mounted read-only
  (`./authelia/configuration.yml`, `./authelia/users_database.yml`); all mutable state (SQLite
  + notifications) is on the **`authelia-data` named volume** at `/var/lib/authelia` so the CD
  runner's `git clean` can't wipe it. The single user in `users_database.yml` **is** the
  allowlist (deny-by-default). Token lifespans are ~1 year (`mcp_long_lived` profile;
  `id_token` must match `access_token`) because MCP clients don't reliably refresh.
  **`server.address: 'tcp://:9091/sso'`**: the path is the prefix Authelia is served under, so
  the portal is `https://<DOMAIN>/sso/` and the OIDC issuer is `https://<DOMAIN>/sso`. The
  session cookie's `domain` is **the hostname itself** (there is no parent domain to share any
  more), with `authelia_url: https://<DOMAIN>/sso` and
  `default_redirection_url: https://<DOMAIN>/wiki/`. **`session.name: 'ram_session'`**, not the
  default `authelia_session`: moving from the old three-hostname layout, a browser keeps its
  stale parent-domain cookie, and a matching name would shadow the fresh one and loop the login;
  a new name is simply ignored.
  Authelia also answers nginx's **`auth_request`** (`/api/authz/auth-request`) for the wiki; its
  `access_control.default_policy: one_factor` is what lets the logged-in user through there.
- **`wiki-sync`** — `alpine/git` running `wiki/sync.sh` (mounted `:ro`) on `/data`, which is
  the volume named by `${WIKI_VOLUME:-wiki-data}`. The script has two branches, picked by
  `GIT_REPO_URL`. **With git** it clones the vault into the **`wiki-data`** volume on first
  start, then commits + pushes browser edits and pulls
  agents' changes on the MCP server's own `GIT_PUSH_DELAY_S` / `GIT_PULL_INTERVAL_S` and git
  credentials from `.env`. **Without git** it does three things and idles: `chown`s a still
  root-owned volume to `PUID:PGID` (default 1000, the server's user), copies the wiki settings
  in, and marks itself ready. There is nothing to sync: the wiki and the server share one
  folder. Non-obvious knobs:
  - **It refuses a `WIKI_VOLUME` that does not match the git setting**: one log line, a 30 s
    sleep, exit 1, so the restart loop stays slow and readable, and `wiki` never starts. Git +
    `vault-data` is the dangerous pairing (a second writer in the server's working tree) and is
    refused before the script touches anything; no git + `wiki-data` would give the wiki an
    empty folder nobody fills.
  - **Rebase with `-X theirs`**: in a rebase "theirs" is the local commit being replayed, so the
    browser edit wins a conflicting hunk. A rebase that still stops is aborted and retried; the
    commits stay local until it goes through.
  - **`.git/info/exclude`** (git only) lists SilverBullet's own files (`CONFIG.md`, `Library/`,
    `_plug/`, `.silverbullet*`). It is local to the clone and never committed, so those files
    never reach the vault repo or the agents' index. `sync.sh` rewrites it on every start.
    Without git the same files sit in the server's folder, and only
    `MARKDOWN_VAULT_MCP_EXCLUDE` keeps them away from agents (see Configuration).
  - **Wiki settings come from this repo.** `wiki/space/` (`CONFIG.md`: page tree open on the
    left by default; `Library/wiki-style.md`: fonts) is mounted `:ro` and copied over the wiki's
    folder on every start, in both modes, so edits made through SilverBullet's own settings
    screen are overwritten on the next deploy. Both pages carry `pageDecoration.hide` so they
    stay out of the tree. The copies are `chown`ed to the folder's owner, so SilverBullet, which
    runs as that user, can still write next to them.
  - The token never touches disk: the credential helper in `.git/config` reads it from env.
  - Its healthcheck is the marker file **`/tmp/wiki-ready`** (it used to be "`/data/.git`
    exists", which means nothing without git). `sync.sh` creates it once the clone, or the
    shared folder, and the settings are in place. It gates `wiki`: SilverBullet on an empty
    folder would set up a fresh space there and the clone would then refuse the non-empty
    directory.
  - It `depends_on` `vault-mirror` being healthy: on the shared volume a restore from the
    bucket has to come before the settings are copied in.
- **`wiki`** — SilverBullet (**pinned `2.12.1-slim`**, no Chromium) on the same
  `${WIKI_VOLUME:-wiki-data}` as `wiki-sync`. Pinned
  because 3.0 moves `CONFIG.md` to `Library/Config.md` and runs `space-lua` only from `Library/`;
  bump it by hand and check `wiki/space/` still applies. **No auth of its own
  and no `ports:`**: the only way in is `proxy`, which lets in nobody without an Authelia
  session. **`SB_URL_PREFIX=/wiki`**: it is served under that path, at
  `https://<DOMAIN>/wiki/`, and `proxy` passes the path through unchanged. `SB_INDEX_PAGE=README`
  because the vault has no `index.md`. **`SB_SHELL_BACKEND=off`**: by default SilverBullet runs
  shell commands in its container for whoever is logged in, a script in a note included, and
  nothing here needs that (`wiki-sync` does the git work). SilverBullet takes its UID from the owner of `/data`.
  With git that is root (owner of the fresh `wiki-data` volume), same as `wiki-sync`, so files
  from either side stay writable by both. On the shared volume it is 1000, the server's user, for the same
  reason: both write the same files.
- **`vault-mirror`** — `rclone/rclone:1.76` running `mirror/mirror.sh` (mounted `:ro`) on
  `vault-data`, **no `ports:`** (it only dials out). With `BUCKET_NAME` unset it reports healthy
  and idles; that is all production sees of it. With it set, every `BUCKET_SYNC_INTERVAL_S`
  (default 300) it runs `rclone sync /vault → <prefix>/vault` in an S3-compatible bucket (GCS
  through HMAC interoperability keys, DigitalOcean Spaces, AWS S3, Cloudflare R2, MinIO). It is
  a backup with auto-restore, **not two-way sync**: an object edited in the bucket never
  reaches a running server, and the next pass replaces it. Non-obvious knobs:
  - **History.** Each pass runs with `--backup-dir <prefix>/history/<UTC time>/`, so a file the
    pass replaces or deletes is moved there as it was. Folders older than `BUCKET_HISTORY_DAYS`
    (default 30, `0` = forever) are purged once a day. Age is read from the folder's **name**:
    an object's own modification time is the note's, not the deletion's. Only folders named
    like a pass (`2026-01-31T142500Z`) are ever purged.
  - **Two marker files in the volume root, without git only** (with git the server would
    commit them); neither is mirrored:
    - **`.mirror-known`**: this volume has been seen by the script: restored, adopted with
      content already in it, or started empty against an empty bucket. It is what tells a
      volume that was emptied on purpose from one that was wiped: the marker lives in the
      volume and goes with it on `docker compose down -v`.
    - **`.mirror-restoring`**: a restore is under way. A restart in the middle finds it and
      finishes the restore; without it the half-filled volume would count as content and be
      mirrored back over the bucket.
  - **Restore, without git only.** At start, a volume with no `.mirror-known` and no content
    (`no_content`: `.git`, `lost+found`, the markers and SilverBullet's own files do not
    count) plus a non-empty bucket copy means `rclone copy` from the bucket, then `chown` to
    `PUID:PGID`. A volume with the marker is never restored into, even with every note
    deleted: a deploy recreates this container while the server is running, and a restore
    then would bring deleted notes back under it. With git there is no restore: the server's
    `git clone` fills the volume and the bucket is a second copy.
  - **What is mirrored.** Without git: the volume as it is, once it has `.mirror-known`.
    Deleting every note is mirrored like any other change, and the notes go to `history/`.
    Without the marker nothing is mirrored (the volume was wiped or swapped while running;
    the log says so, and a restart restores or adopts it). With git there are no markers: a
    tree with no content is not mirrored over a bucket copy that has some.
  - **Not mirrored:** `.git/` (history lives in the git remote), `_plug/` and `.silverbullet*`
    (the wiki rebuilds them, and they would fill the history with noise), symlinks. `CONFIG.md`
    and `Library/` **are** mirrored. A bucket keeps no empty folders, so a restore brings none
    back.
  - **A failed pass is one log line** with rclone's last error; the next pass is the retry
    (`--retries 1`).
  - **Its healthcheck (`/tmp/mirror-ready`) gates `markdown-vault-mcp` and `wiki-sync`**, so
    neither sees a half-restored folder. `start_period: 15m` is how long a restore may take before `docker compose up` gives up
    on the dependency. It is kept under the deploy job's `timeout-minutes: 20`, so a restore
    that fits is followed by the rest of the stack in the same run. A longer one fails the
    deploy, but the container keeps restoring (`restart: unless-stopped`); run the deploy
    again once its log says `restore done`. It holds
    them back only while a restore may still be needed (`must_wait`): git is off and either
    `.mirror-restoring` is there, or the volume has neither `.mirror-known` nor content. Then missing keys or a bucket that cannot
    be listed (wrong name, keys or endpoint) keep the server down, retrying every 30 s; look at
    this log first when the server does not start. In every other case, git mode included, a
    broken bucket setting costs the copy and a line in the log, never the service.
  - **With git, a pass is skipped while git is at work** (`git_busy`: no `.git/HEAD` yet,
    `index.lock`, a rebase in progress). A pass taken in the middle of a clone or a rebase
    would file the files git has not written yet under `history/`. That check is one moment
    before the pass, and the script cannot lock the server's git out, so it also compares
    git's state (`git_stamp`: `.git/index`, `HEAD`, `ORIG_HEAD`) before and after: a pass
    that git overlapped, or one skipped because git was busy, is taken again 5 s later, three
    times at most, instead of leaving a tree in motion in the bucket until the next interval.
  - **rclone is configured by env only**: the script exports `RCLONE_CONFIG_STORE_*` from the
    `BUCKET_*` variables and points `RCLONE_CONFIG` at an empty file, so no secret is on disk
    and there is no config file or extra GitHub secret. The remote exists only inside the
    script's process: a `docker compose exec vault-mirror rclone …` has no `store:` remote.
  - `init: true`, because `sh` as PID 1 would ignore SIGTERM. The bucket must already exist.

- **`okf-maintenance`** — the daily OKF upkeep: the server's own image running
  `scripts/okf_maintenance.py --schedule` (mounted `:ro`), as user 1000, no volume, no
  `ports:`. It used to be a GitHub workflow on the CD runner, which an install without a
  runner never ran. Once a day at `OKF_MAINTENANCE_AT` (default `02:30`, in `TZ`, default UTC;
  `off` disables it) it runs the script as a child process, which calls the server's MCP tools
  over the compose network (`OKF_MCP_URL`) with the bearer, so every change is an ordinary
  server write: `okf_convert_links` (wikilinks the wiki inserts), `.md` added to extensionless
  links SilverBullet leaves after a rename, `okf_generate_index` for the root **and every
  folder** (a root call only creates missing indexes, it never refreshes existing ones), then
  `okf_validate` + `get_broken_links`. Non-obvious knobs:
  - **The report is this container's log** (`docker compose logs okf-maintenance`); nothing
    else shows that the audit found a broken link or a note without `type`. A run exits 0
    clean, 1 when the audit found something, 2 when it could not run.
  - **A run that could not reach the server is retried** after 10 minutes, three attempts in
    all: a deploy may be recreating the server at that moment. (The old workflow sat in the
    `ram-deploy` queue for the same reason.)
  - **It gets only the variables it reads**, through `environment:` interpolation from `.env`,
    not the whole `env_file`: the bearer, the OKF mode, the schedule, `TZ` and the retry
    pause (`OKF_MAINTENANCE_RETRY_S`, default 600; not in `.env.example`, few need it). A
    variable the script reads has to be listed there, or `.env` cannot set it.
  - **The image's healthcheck is disabled** here: it probes a server on localhost.
  - It idles, with one log line saying why, when `MARKDOWN_VAULT_MCP_OKF_MODE` is `off`, the
    bearer is missing, or the time is not `HH:MM`. A server without OKF tools makes a run a
    no-op.
  - Run it now: `docker compose exec okf-maintenance python /etc/ram/scripts/okf_maintenance.py`.

**Boot-time reindex.** The server decides what changed by diffing the vault against
`/data/state.json`, a path→SHA-256 snapshot. Older server versions rewrote that snapshot only on
a full reindex, so every note written through MCP since the last one came back as `added` at the
next start and was embedded a second time (once 57 notes, ~70 s of every core). On 6.1.1 that no
longer happens: the restart after the OKF migration, which had edited all 116 notes through MCP,
reported `0 added, 0 modified` and re-embedded nothing. If a restart ever shows a large `added`
count again, this is where to look; the `cpus` cap is the guard.

Data flow: `agents ─HTTPS→ Cloudflare edge → cloudflared → proxy →` either
`markdown-vault-mcp → /vault + /data` (MCP traffic: everything outside `/wiki/` and `/sso/`) or
`→ authelia` (`/sso/`: the portal and the browser leg of the OAuth flow). The wiki, with git:
`browser → cloudflared → proxy → (auth_request to authelia) → wiki → wiki-data`,
with `wiki-sync` moving its edits through the vault repo to the server's next pull. The wiki,
without git: the same path ends in `wiki → vault-data`, the server's own folder, and the
server's file watcher indexes the edit. The bucket: `vault-data → vault-mirror → bucket`, and
back only as a restore onto an empty volume without git.
TLS terminates at the edge; inside the network it's plain HTTP. **Auth is enforced by the
MCP server — bearer token OR its own OIDC proxy (which delegates login to Authelia) — not by
Cloudflare Access.** The wiki has no auth of its own: `proxy` asks Authelia about every request
to it.

## Configuration

Configuration lives in three gitignored files, each with a committed `*.example` template:
`.env`, `authelia/configuration.yml` and `authelia/users_database.yml`. The tunnel has no file
of its own: its two values are in `.env`, and its origin is fixed in compose. The real hostname
is written in two of them, `.env` and `authelia/configuration.yml`; `proxy/nginx.conf` and
`docker-compose.yml` are committed and carry none.

`.env` (all app vars are `MARKDOWN_VAULT_MCP_*`): core vault paths, `BASE_URL=https://<DOMAIN>`
(the root of the hostname, no path; the OAuth redirect URI is `BASE_URL` + `/auth/callback`),
**`EXCLUDE`** (besides
`.obsidian/**`, `.trash/**` and `.git/**` it lists SilverBullet's own files: `CONFIG.md`,
`Library/**`, `_plug/**`, `.silverbullet*`. Without git the wiki keeps them in the server's
folder, and this is the only thing that hides them from agents and the index; with git they
never reach the server's clone, so the patterns have nothing to match there unless a note in
the repo uses one of these names), the **embeddings block**
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
the `BEARER_TOKEN`, the **OIDC block** (`OIDC_CONFIG_URL` = `https://<DOMAIN>/sso/.well-known/openid-configuration`,
`OIDC_CLIENT_ID=ram-brain`, `OIDC_CLIENT_SECRET` = *plaintext* whose pbkdf2 hash is in Authelia's
config, `OIDC_JWT_SIGNING_KEY` = stable 64-hex, `OIDC_REQUIRED_SCOPES=openid,email`), the
**storage block** (below), and the
two cloudflared vars (`CF_TUNNEL_ID`, `TUNNEL_CRED_CONTENTS`). **`AUTH_MODE` is intentionally
unset** — auto-detect enables multi-auth from bearer + OIDC both being present; forcing
`AUTH_MODE=oidc-proxy` risks disabling the bearer path.

`OKF_MAINTENANCE_AT` (and `TZ`) set when the `okf-maintenance` service runs; both have no
prefix, and a `.env` without them means 02:30 UTC.

The storage block picks the mode (table under Architecture). Its variables:

- **`WIKI_VOLUME`** — the named volume the wiki works on. Unset means `wiki-data` (with git);
  `vault-data` without git. It has no prefix and two readers: compose interpolates it into the
  `volumes:` of `wiki` and `wiki-sync`, and `sync.sh` reads it to check the pairing.
- **Managed-git settings**, optional as a block: `GIT_REPO_URL`, `GIT_USERNAME=x-access-token`,
  `GIT_TOKEN` = fine-grained PAT, `GIT_COMMIT_NAME`/`_EMAIL`, `GIT_PULL_INTERVAL_S`,
  `GIT_PUSH_DELAY_S`, `GIT_LFS`. Without git, the whole block is deleted or commented out.
- **`BUCKET_*`**, optional as a block and without the `MARKDOWN_VAULT_MCP_` prefix, read only
  by `vault-mirror`: `BUCKET_NAME` (unset = mirror off), `BUCKET_PROVIDER` (rclone's S3
  provider name: `GCS`, `DigitalOcean`, `AWS`, `Cloudflare`, `Minio`; default `Other`),
  `BUCKET_ENDPOINT` (not needed for AWS), `BUCKET_REGION` (where the provider wants one),
  `BUCKET_ACCESS_KEY` / `BUCKET_SECRET_KEY`, `BUCKET_PREFIX` (a folder inside the bucket),
  `BUCKET_SYNC_INTERVAL_S` (300), `BUCKET_HISTORY_DAYS` (30). They all ride in the `DOTENV`
  secret; the bucket needs no config file, no new secret and no materialize step.

The Authelia config files carry secrets **and** the real hostname, so they are
gitignored too. Generate Authelia secrets with the `authelia crypto …` subcommands (see
`INSTALL.md`, step 2.2);
the JWKS private key and the pbkdf2 client-secret hash are inlined into `configuration.yml`.

When adding config, update **both** the committed `*.example` template (no real values) and the
real gitignored file. **CD note:** `actions/checkout` runs `git clean`, wiping the gitignored
files, so `deploy.yml` re-materializes each from a GitHub secret every run — `DOTENV → .env`,
`AUTHELIA_CONFIG`, `AUTHELIA_USERS`. (There is no cloudflared secret any more: the tunnel is
configured from `.env`.) Adding a new config file means adding
a matching secret + a materialize step, or the runner won't have it. **After a config change you
MUST update the corresponding secret AND redeploy** — editing the local file alone does nothing
for the runner (it reads the secret, not git).

## Invariants — violating these breaks the deployment

- **No `ports:` on any service.** Ingress is cloudflared-only, by design, and behind it
  `proxy`-only: no other service is an origin of the tunnel.
- **The MCP server owns the root of the hostname; a prefix must not collide with its routes.**
  MCP clients look for the OAuth metadata at the root of the host, so the server cannot move
  under a prefix. Everything else gets a prefix of its own in `proxy/nginx.conf` (`/wiki/`,
  `/sso/`, a future `/admin/`), and that prefix must not shadow a path the server serves:
  `/mcp`, `/authorize`, `/token`, `/register`, `/auth/callback`, `/.well-known/…`,
  `/transfer/…`, `/health`. `/auth` in particular is taken.
- **The `/sso` and `/wiki` prefixes are each written in more than one file, and the copies must
  agree.** `/sso`: `server.address` in `authelia/configuration.yml`, the `/sso/` locations in
  `proxy/nginx.conf`, and `MARKDOWN_VAULT_MCP_OIDC_CONFIG_URL` in `.env` (plus `authelia_url`
  in the session cookie block). `/wiki`: `SB_URL_PREFIX` in `docker-compose.yml` and the
  `/wiki/` locations in `proxy/nginx.conf` (plus `default_redirection_url`). Two of these files
  are gitignored, so a change of prefix also means new `DOTENV` / `AUTHELIA_CONFIG` secrets.
- **`proxy/nginx.conf` carries no hostname.** It is committed and this repo is public; it
  matches any host (`server_name _`) and its redirects are relative. The real name stays in
  `.env`, `authelia/configuration.yml` and Cloudflare DNS.
- **One hostname means one browser origin, and that is an accepted trade-off.** The wiki, the
  login portal and the MCP OAuth endpoints share it. SilverBullet runs scripts found in notes,
  and notes are written by agents, so a script in a note can reach `/sso/` and the OAuth
  endpoints with the reader's session; separate hostnames used to prevent that. It was chosen
  for a simpler install (one name, one DNS record, three config files) because the wiki is a
  review tool for the owner and agents are told to treat notes as data. **A new browser-facing
  app under a prefix inherits this**: it shares the origin with the wiki, so anything a note's
  script can do in the reader's browser, it can do to that app too. A Content-Security-Policy
  on `/wiki/` was tried in a real browser and not shipped: SilverBullet works under one, and it
  blocks a script's direct requests to the other prefixes, but it holds only with the wiki's
  service worker switched off and images from other sites blocked, and it never stops a
  script from sending the tab itself to another address. If an app on this hostname must be
  out of the wiki's reach, the wiki needs a hostname of its own.
- **`/data` stays separate from `/vault`.** Index/embeddings/state must never enter git, or the
  bucket.
- **`WIKI_VOLUME` must match the git setting**: unset (`wiki-data`) with `GIT_REPO_URL`,
  `vault-data` without it. `wiki-sync` enforces this and refuses to start otherwise. Do not
  weaken that check: git + `vault-data` puts a second writer into the server's working tree.
- **SilverBullet's names are reserved at the vault root**: `CONFIG.md`, `Library/`, `_plug/`,
  `.silverbullet*`. They are in `MARKDOWN_VAULT_MCP_EXCLUDE`, so a note at such a path is not
  indexed: it is missing from search, listings and folders. The patterns are anchored at the
  root (`notes/CONFIG.md` is an ordinary note). `EXCLUDE` is not access control: `read` and
  `write` with the exact path still work, so an agent that knows the name can open or change
  the wiki's settings. `EXCLUDE` applies in every mode, but only without git is it
  load-bearing: there, dropping the four patterns hands the wiki's settings and caches to
  agents and the index.
- **A wiped volume is never mirrored over the bucket, and the two markers (`.mirror-known`,
  `.mirror-restoring`) are not to be created or removed by hand.** Without git the script
  mirrors only a volume that carries `.mirror-known` and restores only into one that has
  neither the marker nor content; with git it refuses a tree without content when the bucket
  has some. That is what makes `docker compose down -v`, or a restart in the middle of a
  restore, harmless to the bucket copy, and what keeps a restore from running under a live
  server. A change to `mirror/mirror.sh` has to keep both properties.
- **The bucket is a copy, never an input.** Nothing reads it except the restore of a new or
  wiped volume without git. Editing objects there changes nothing on the server.
- **With git, the committer identity is mandatory** (`GIT_COMMIT_NAME`/`_EMAIL`) — container git
  has no global user, so auto-commits fail silently without it.
- **With git, the remote must be HTTPS.** SSH remotes are rejected at startup when a token is set;
  there is no SSH auth path. The fine-grained PAT must belong to the account that owns the
  repo (a fine-grained PAT can't reach a repo where it's only a collaborator).
- **Never put Cloudflare Access in front of `<DOMAIN>`**, on any path — it injects its
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
  force-recreates `authelia` after re-materializing its configs, and
  `proxy`, `markdown-vault-mcp`, `wiki-sync`, `vault-mirror` + `okf-maintenance` for their
  bind-mounted `nginx.conf`, patch, sync script, mirror script and upkeep script. A plain
  `up -d` (or editing the file on the host) silently keeps the stale in-memory config.
  `cloudflared` is not in that list any more: its configuration is all env, which compose does
  notice.
- **OIDC client (`ram-brain`) must satisfy the MCP OAuth flow, or login half-works then fails:**
  its `audience` whitelist must include the MCP resource (`https://<DOMAIN>` and
  `https://<DOMAIN>/mcp`) — MCP clients send it as an RFC 8707 `resource` param and Authelia
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
- **Never commit secrets, and never place a secret inside the vault** — with git the vault is
  pushed to `github.com/<owner>/<vault-repo>`, with a bucket it is copied there and old versions
  stay in `history/`, so anything under `/vault` leaves the host. The
  real `.env` and `authelia/*.yml` are gitignored, as is the whole `cloudflared/` folder (tunnel
  credential files); only `*.example` templates are committed.
- With git, the file watcher auto-disables because `GIT_PULL_INTERVAL_S > 0`. That is expected —
  external changes arrive via periodic pull, not inotify. Not a bug. Without git the watcher is
  on, and it is the only thing that gets browser edits into the index.

## Two-writer / concurrency model (know before touching sync)

The model depends on the storage mode. Production is the first one.

### With git

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
wiki's. **Nothing may write into the server's `/vault` working tree directly** (this rule is
for the git mode only): uncommitted
files there block its rebase and never reach the index. `vault-mirror` mounts the same volume
but only reads it in this mode. A GitHub push webhook
(`/github-webhook`, `MARKDOWN_VAULT_MCP_GITHUB_WEBHOOK_SECRET`) would make pushes reach the
server at once; it is not enabled. Agents avoid lost updates by folder convention only
(`agents/<id>/…` private, `shared/…` append-preferred with `## [agent-id]` attribution) —
neither writer enforces this.

### Without git

Two writers on **one shared folder**, the `vault-data` volume, both running as UID 1000:

- **The MCP server** writes notes into `/vault` and indexes its own writes.
- **SilverBullet** writes the same folder directly. The server's **file watcher** sees the
  change and indexes it after `FILE_WATCHER_DEBOUNCE_S` (default 2 s), so a browser edit is
  searchable within seconds, instead of up to push delay + pull interval. `wiki-sync` takes no
  part after start.

There is no rebase, so the "no direct writes into `/vault`" rule does not apply: here a direct
write is the design. There is also **no merge and no conflict file: the last write wins.** When
an agent and the browser save the same file at once, the earlier version is gone. With a
bucket it survives in `history/` only if a mirror pass had copied it before it was
overwritten. There is no `get_history`/`get_diff` either. The folder convention above is the
only protection, as with git.

`vault-mirror` is not a third writer: apart from its two marker files it writes into `/vault`
only during a restore, and a restore runs only on a volume it has not seen and that has no
content (or to finish one that was cut short). On the first start that is before the other two
come up; a volume the server is already working on carries `.mirror-known` and is left alone.
