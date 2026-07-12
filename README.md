# ram — Random Agents Memories

Central, always-on **shared "second brain"** for multiple AI agents across machines.
A single [`markdown-vault-mcp`](https://github.com/pvliesdonk/markdown-vault-mcp) server
owns a git-backed markdown vault (auto-commit / push / periodic pull), is exposed on the
public internet through a **Cloudflare Tunnel**, and accepts **two auth paths at once
(multi-auth): a static bearer token for headless agents, and OAuth 2.1 (OIDC) via a
self-hosted [Authelia](https://www.authelia.com/) for interactive GUI clients.**

```
agents ─HTTPS─► Cloudflare edge ─► cloudflared ─┬─► markdown-vault-mcp ─► /vault (git: your-org/vault)
  │  (bearer OR OAuth)                           │        └────────────► /data (index, embeddings, sessions)
  └─ OAuth login ───────────────────────────────┴─► authelia  (OIDC IdP @ <AUTH_DOMAIN>)
```

- **Domain:** `https://<MCP_DOMAIN>/mcp` — the MCP endpoint
- **IdP domain:** `https://<AUTH_DOMAIN>` — Authelia login (used only during the OAuth flow)
- **Vault repo:** `https://github.com/your-org/vault.git` (private, managed read-write)
- **Auth:** multi-auth — static bearer (`Authorization: Bearer <token>`) **or** OAuth 2.1 (DCR + PKCE)
- **Transport:** streamable HTTP · **Embeddings:** local FastEmbed

## Files

| File | Purpose | In git? |
| --- | --- | --- |
| `docker-compose.yml` | services: `init-perms`, `markdown-vault-mcp`, `cloudflared`, `authelia` | ✅ |
| `.env.example` / `.env` | env template / **real secrets** (bearer, OIDC, git PAT, tunnel) | ✅ / 🚫 |
| `cloudflared/config.yml.example` / `.yml` | tunnel ingress template / **real** (tunnel ID + hostnames) | ✅ / 🚫 |
| `authelia/configuration.yml.example` / `.yml` | Authelia+OIDC template / **real** (secrets, JWKS, client) | ✅ / 🚫 |
| `authelia/users_database.yml.example` / `.yml` | allowlist template / **real** (user + password hash) | ✅ / 🚫 |

cloudflared routes two hostnames through one tunnel via `cloudflared/config.yml` ingress
rules (`<MCP_DOMAIN> → markdown-vault-mcp:8000`, `<AUTH_DOMAIN> → authelia:9091`). Tunnel credentials
stay inline in `.env` (`CF_TUNNEL_ID`, `TUNNEL_CRED_CONTENTS`); only ingress lives in the file.

## First-time setup

1. **Server secrets** — copy `.env.example` → `.env` and fill:
   - `MARKDOWN_VAULT_MCP_BEARER_TOKEN` (`openssl rand -hex 32`);
   - `MARKDOWN_VAULT_MCP_GIT_TOKEN` (GitHub fine-grained PAT, *Contents: Read and write* on the vault repo);
   - the `MARKDOWN_VAULT_MCP_OIDC_*` block — client secret (plaintext, see step 2) and a
     **stable** `openssl rand -hex 32` signing key. Leave `AUTH_MODE` unset (auto-detect
     enables multi-auth from bearer + OIDC both being present).

2. **Authelia (OIDC IdP)** — copy both `.example` files under `authelia/` to their real
   names and fill secrets:
   ```bash
   IMG=authelia/authelia:latest
   # JWKS private key → paste into configuration.yml (identity_providers.oidc.jwks[].key)
   docker run --rm --entrypoint authelia -u "$(id -u):$(id -g)" -v "$PWD/authelia":/keys $IMG \
     crypto pair rsa generate --directory /keys
   # client secret: plaintext → .env (OIDC_CLIENT_SECRET), $pbkdf2$ hash → configuration.yml
   docker run --rm --entrypoint authelia $IMG \
     crypto hash generate pbkdf2 --variant sha512 --random --random.length 72
   # login password hash → users_database.yml
   docker run --rm --entrypoint authelia $IMG crypto hash generate argon2 --password '<login-password>'
   # hmac / session / storage / jwt secrets (run once each) → configuration.yml
   docker run --rm --entrypoint authelia $IMG crypto rand --length 64 --charset alphanumeric
   ```
   Validate before deploying:
   ```bash
   docker run --rm --entrypoint authelia -v "$PWD/authelia":/config $IMG \
     validate-config --config /config/configuration.yml
   ```
   The single user in `users_database.yml` **is** the allowlist (deny-by-default: no other
   users exist).

3. **Cloudflare Tunnel** (once, on a machine with a browser):
   ```bash
   cloudflared tunnel login
   cloudflared tunnel create my-tunnel                       # prints TUNNEL_ID + creds json path
   cloudflared tunnel route dns my-tunnel <MCP_DOMAIN>   # MCP host
   cloudflared tunnel route dns my-tunnel <AUTH_DOMAIN>  # IdP host — BOTH point at the same tunnel
   ```
   Copy `cloudflared/config.yml.example` → `cloudflared/config.yml`, set the tunnel ID and
   the two real hostnames, then put into `.env`:
   - `CF_TUNNEL_ID` = the printed tunnel UUID.
   - `TUNNEL_CRED_CONTENTS` = the creds JSON on one line (`python3 -c "import json;..."`).
   - **Do NOT** enable Cloudflare Access on either hostname — it breaks the bearer header for
     headless agents and injects its own auth in front of the OAuth flow.

4. **Bring up:**
   ```bash
   docker compose up -d
   docker compose logs -f markdown-vault-mcp   # watch for a successful clone + index build
   ```

### Deploying via CI (self-hosted runner)

`.github/workflows/deploy.yml` deploys on push to `main`. Because `actions/checkout` runs
`git clean` (wiping untracked, gitignored files), the runner **materializes** each secret
file from a GitHub Actions secret every run:

| Secret | Materializes |
| --- | --- |
| `DOTENV` | `.env` (full contents, incl. the `OIDC_*` vars) |
| `CLOUDFLARED_CONFIG` | `cloudflared/config.yml` |
| `AUTHELIA_CONFIG` | `authelia/configuration.yml` |
| `AUTHELIA_USERS` | `authelia/users_database.yml` |

Set them with `gh secret set <NAME> < <file>`. Authelia's SQLite + notifications live on the
`authelia-data` named volume, so they survive the `git clean`.

**Config changes need a redeploy, not just an edit.** `docker compose up -d` recreates a
container only on image / env / volume-definition changes — it does **not** reload a
bind-mounted config file whose *contents* changed. So the deploy force-recreates `authelia`
and `cloudflared` after re-materializing their configs. If you change `authelia/*.yml` or
`cloudflared/config.yml` on the host directly, run
`docker compose up -d --force-recreate authelia cloudflared` (or `docker compose restart authelia`)
— a plain `up -d` silently keeps the old in-memory config.

### OAuth troubleshooting

Two client-config requirements the MCP OAuth flow depends on (both live in
`authelia/configuration.yml.example`):

- **`invalid_target` at the login redirect** → the client is missing the MCP resource in its
  `audience` whitelist. MCP clients send `resource=https://<MCP_DOMAIN>/mcp` (RFC 8707 Resource
  Indicators); Authelia rejects any resource not whitelisted. Add both `https://<MCP_DOMAIN>`
  and `https://<MCP_DOMAIN>/mcp` to the client `audience`.
- **`invalid_client` at token exchange** → auth-method mismatch. FastMCP's oidc-proxy
  authenticates to Authelia's token endpoint with HTTP Basic, so the client must be
  `token_endpoint_auth_method: 'client_secret_basic'` (not `client_secret_post`).

## Verify

```bash
# enforcement + bearer path
curl -i https://<MCP_DOMAIN>/mcp                                    # expect HTTP 401 + WWW-Authenticate
curl -i https://<MCP_DOMAIN>/mcp -H "Authorization: Bearer <TOKEN>" # expect a proper MCP response
# OAuth discovery chain
curl -s -o /dev/null -w '%{http_code}\n' https://<AUTH_DOMAIN>/.well-known/openid-configuration       # 200
curl -s -o /dev/null -w '%{http_code}\n' https://<MCP_DOMAIN>/.well-known/oauth-authorization-server # 200
```

Connect a **headless** agent (Claude Code) with the bearer:

```bash
claude mcp add -t http -s user brain https://<MCP_DOMAIN>/mcp \
  -H "Authorization: Bearer <TOKEN>"
```

Connect a **GUI** client (ChatGPT Developer mode, Claude web/mobile connector): add
`https://<MCP_DOMAIN>/mcp` with Auth = **OAuth**. The client performs DCR + PKCE, you log
in at Authelia (`<AUTH_DOMAIN>`), and the tools appear. Tokens last ~1 year — MCP clients
do not reliably refresh, so the session equals the access-token lifetime.

## Operating notes

- **One writer is safest.** Prefer editing the vault *through the server*. If you also push to
  the vault repo directly (web editor, laptop clone) while the server has un-pushed commits, the
  ff-only pull will refuse to merge (histories diverge) — reconcile manually.
- **Concurrent agents:** namespace by folder (`agents/<id>/…`, `shared/…`); in `shared/` prefer
  append over rewriting another agent's lines; add `## [agent-id]` attribution headers.
- **Rotating credentials:** rotating `BEARER_TOKEN` logs out bearer agents; rotating `GIT_TOKEN`
  stops sync until `.env` is updated and the server restarts. Rotating
  `MARKDOWN_VAULT_MCP_OIDC_JWT_SIGNING_KEY` is the **OAuth kill switch** — it invalidates every
  issued OAuth token at once (bearer unaffected); changing the Authelia user password blocks new
  logins.

## Design rationale

Why the deployment is shaped this way (the "why" behind the fixed decisions):

- **Single central server, one shared identity.** One `markdown-vault-mcp` instance, one
  vault, one working tree — so every agent sees the others' writes in real time. All clients
  (bearer or OAuth) map to the same single-tenant vault; agent separation is by folder
  convention (`agents/<id>/…` private, `shared/…` append-preferred), not server-enforced.
- **Multi-auth: static bearer *and* OAuth (OIDC) via Authelia.** A single shared bearer is the
  simplest, most reliable auth for headless/programmatic clients, and it stays. OAuth 2.1 was
  layered on *additively* (the server accepts either credential) because GUI clients — ChatGPT
  Developer mode, Claude web/mobile — expect a browser login flow that a static header can't
  drive. Authelia is the IdP: self-hosted, one Go binary + SQLite, and — critically — it allows
  **arbitrary token lifespans**. Tokens are set to ~1 year on purpose: current MCP clients do
  not reliably refresh, so the session lives exactly as long as the access token; the `id_token`
  lifetime must match the `access_token` because its `exp` gates the session. The kill switch for
  year-long tokens is rotating `OIDC_JWT_SIGNING_KEY` (see Operating notes).
- **Two public hostnames, one tunnel, ingress in `config.yml`.** cloudflared used to forward a
  single `TUNNEL_URL` origin; adding Authelia needs a second public hostname (`<AUTH_DOMAIN>`)
  for the browser leg of the OAuth flow, so routing moved into `cloudflared/config.yml` ingress
  rules (host → service). Both hostnames are DNS-routed to the *same* tunnel. The real hostnames
  and tunnel ID stay out of git (the file is gitignored and materialized from a secret on CI), so
  the domain remains private.
- **HTTPS git remote + a PAT owned by the repo owner.** The remote must be HTTPS — SSH remotes
  are rejected at startup when a token is set. A GitHub **fine-grained PAT can only reach repos
  owned by its own account** — not repos where it is merely a collaborator — so the PAT must
  belong to the account that **owns** the vault repo, scoped to *Contents: Read and write*.
- **`/data` is separate from `/vault`.** The FTS index, embeddings, and HTTP session state live
  in `/data` deliberately, so they never get committed into the vault git repo.
- **`init-perms` one-shot is load-bearing.** Named volumes mount root-owned; the app runs as
  UID 1000 and its entrypoint fixes only `/data`, never `/vault`. Without a one-shot
  `chown -R 1000:1000 /vault /data`, the managed clone into `/vault` dies with "Permission denied".
  (Authelia runs as root, so its named volume needs no such fix.)
- **Cloudflare Tunnel ingress, no published ports, never Cloudflare Access.** TLS terminates at
  the edge; inside the network it's plain HTTP. Auth is the MCP server's (bearer or its own OIDC
  proxy) — **not** Cloudflare Access, on either hostname. Access injects its own auth and breaks
  both the bearer header (headless) and the OAuth flow (GUI).
- **Transport is streamable HTTP, not SSE.** Cloudflare Tunnel proxies streamable-HTTP cleanly;
  SSE can hit buffering/timeout issues.
- **Frequent fast-forward-only pull, no push webhook.** The server pulls `fetch` + ff-only on an
  interval, enough to pick up the operator's own edits; the trade-off is the two-writer caveat
  under **Operating notes**.

### Considered and dropped

- **Cloudflare Access or Pocket ID as the IdP** — Access caps *all* token lifetimes at 1 month
  (monthly re-login on every client); Pocket ID hardcodes access tokens at 1 hour. Both defeat
  the "practically never re-login" goal, so self-hosted Authelia (arbitrary lifespans) won.
- **Multiple vaults / per-agent namespaces / per-agent branches** — the server is single-tenant
  (one instance = one vault = one branch).
- **SSH remotes / deploy keys** — no SSH auth path; HTTPS + PAT only.
- **GitHub push webhook** for instant pickup of external pushes — the frequent periodic pull
  covers it.
