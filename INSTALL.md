# Install your own ram

This recipe stands up a new, independent instance from scratch: its own vault, its own domains,
its own host. Plan about an hour; most of it is waiting for DNS and the first deploy. What each
piece does and why it is built this way is in [README.md](README.md).

## 0. What you need

| Item | Notes |
| --- | --- |
| An always-on host with Docker + Compose v2 | No inbound ports: all traffic arrives through the tunnel. |
| A domain on Cloudflare | Three hostnames under **one parent domain**: `<MCP_DOMAIN>`, `<AUTH_DOMAIN>`, `<WIKI_DOMAIN>` (for example `brain.`, `auth.` and `wiki.` of the same domain). Authelia's login cookie is set on the parent, so it must cover all three. |
| A GitHub account | Owns the vault repo. The fine-grained token in step 1 must belong to this same account: it can't reach a repo where it is only a collaborator. |
| A Google AI Studio API key | For `gemini-embedding-2`. Create one at <https://aistudio.google.com/apikey>. |
| On your laptop | `git`, `gh` (logged in), `docker`, `cloudflared`, `openssl`. |

## 1. Repositories

1. **Infra repo.** Copy this repository under your account (fork it, or create a new repo and
   push this one into it). Real configuration never lands in git, only the `*.example`
   templates, so the repo can stay public.
2. **Vault repo.** Create a private repo with one first commit:
   ```bash
   gh repo create <owner>/<vault-repo> --private --add-readme
   ```
3. **The vault's rules.** Add a root `_conventions.md` to the vault: which folder holds what,
   required frontmatter, how to link notes, and "never write secret values". Agents fetch it
   with `get_conventions` before writing, and every write result repeats it. Folders can get
   their own `_conventions.md` later; they add to the root rules.
4. **Token for the server.** A fine-grained personal access token. Its owner is the vault
   repo's owner, it has access to that one repo only, with *Contents: Read and write*.

## 2. Configuration

Everything below happens in your clone of the infra repo. The real files are gitignored.

### 2.1 `.env`

Copy `.env.example` to `.env` and fill in:

| Variable | Value |
| --- | --- |
| `MARKDOWN_VAULT_MCP_BASE_URL` | `https://<MCP_DOMAIN>` |
| `MARKDOWN_VAULT_MCP_BEARER_TOKEN` | `openssl rand -hex 32`: the shared token for headless agents |
| `MARKDOWN_VAULT_MCP_GIT_REPO_URL` | `https://github.com/<owner>/<vault-repo>.git` (HTTPS only) |
| `MARKDOWN_VAULT_MCP_GIT_TOKEN` | the token from step 1.4 |
| `MARKDOWN_VAULT_MCP_GIT_COMMIT_NAME` / `_EMAIL` | the identity on the server's commits; required |
| `OPENAI_API_KEY` | the AI Studio key. The bare name, no prefix: the server talks to Gemini through its OpenAI-compatible endpoint |
| `MARKDOWN_VAULT_MCP_INSTANCE_DESCRIPTION` | one line on what this vault is for |
| `MARKDOWN_VAULT_MCP_INSTRUCTIONS_EXTRA` | your rules for agents: language, search habits, when to offer saving knowledge. Keep both under ~500 characters in total: Claude Code cuts a server's instructions at 2,048 |
| `MARKDOWN_VAULT_MCP_OIDC_*` | step 2.2 |
| `CF_TUNNEL_ID`, `TUNNEL_CRED_CONTENTS` | step 2.3 |

Leave `AUTH_MODE` unset. With both the bearer token and the OIDC block present, the server
enables both login paths by itself.

### 2.2 Authelia

Copy `authelia/configuration.yml.example` and `authelia/users_database.yml.example` to their
real names, replace the placeholders with your hostnames, then generate the secrets:

```bash
IMG=authelia/authelia:latest
# JWKS private key → paste into configuration.yml (identity_providers.oidc.jwks[].key)
docker run --rm --entrypoint authelia -u "$(id -u):$(id -g)" -v "$PWD/authelia":/keys $IMG \
  crypto pair rsa generate --directory /keys
# OIDC client secret: the plaintext → .env (MARKDOWN_VAULT_MCP_OIDC_CLIENT_SECRET),
# the $pbkdf2$ hash → configuration.yml (clients[].client_secret)
docker run --rm --entrypoint authelia $IMG \
  crypto hash generate pbkdf2 --variant sha512 --random --random.length 72
# your login password → its hash goes into users_database.yml
docker run --rm --entrypoint authelia $IMG crypto hash generate argon2 --password '<login-password>'
# hmac, session, storage and jwt secrets: run once for each → configuration.yml
docker run --rm --entrypoint authelia $IMG crypto rand --length 64 --charset alphanumeric
```

Also set `MARKDOWN_VAULT_MCP_OIDC_JWT_SIGNING_KEY` in `.env` to `openssl rand -hex 32` and
never change it: a new key logs every OAuth client out. Check the config before deploying:

```bash
docker run --rm --entrypoint authelia -v "$PWD/authelia":/config $IMG \
  validate-config --config /config/configuration.yml
```

### 2.3 Cloudflare Tunnel

```bash
cloudflared tunnel login                               # opens a browser, pick your domain
cloudflared tunnel create <name>                       # prints the tunnel ID and a creds file
cloudflared tunnel route dns <name> <MCP_DOMAIN>
cloudflared tunnel route dns <name> <AUTH_DOMAIN>
cloudflared tunnel route dns <name> <WIKI_DOMAIN>
```

Copy `cloudflared/config.yml.example` to `cloudflared/config.yml` and set the tunnel ID and
the three hostnames. In `.env`, set `CF_TUNNEL_ID` to the tunnel ID and
`TUNNEL_CRED_CONTENTS` to the creds file's JSON on one line.

**Do not put Cloudflare Access in front of any of these hostnames.** It replaces the bearer
header headless agents send and gets in the way of both Authelia login flows.

## 3. Host and runner

1. Install Docker on the host. The user that runs the GitHub runner must be able to run
   `docker`.
2. Register a self-hosted runner for **your** infra repo: *Settings → Actions → Runners →
   New self-hosted runner*, and follow the commands GitHub shows. Install it as a service so it
   comes back after a reboot.

## 4. GitHub secrets

The deploy job rebuilds every gitignored file from a secret on each run:

```bash
gh secret set DOTENV             < .env
gh secret set CLOUDFLARED_CONFIG < cloudflared/config.yml
gh secret set AUTHELIA_CONFIG    < authelia/configuration.yml
gh secret set AUTHELIA_USERS     < authelia/users_database.yml
```

From now on, a config change means: edit the file, update its secret, deploy. The runner
reads the secret, not your local file.

## 5. First deploy

```bash
gh workflow run deploy.yml
gh run watch
```

Every later push to `main` deploys too; put `[skip ci]` in a commit message to skip one. On
its first start the server clones the vault and embeds it: seconds for a fresh vault, one
embedding call per section for a big one. The wiki makes its own clone next to it.

## 6. Verify

| Check | Expect |
| --- | --- |
| `curl -i https://<MCP_DOMAIN>/mcp` | `401` with a `WWW-Authenticate` header |
| `curl -i https://<MCP_DOMAIN>/mcp -H "Authorization: Bearer <TOKEN>"` | an MCP response |
| `curl -sI https://<AUTH_DOMAIN>/.well-known/openid-configuration` | `200` |
| `curl -sI https://<WIKI_DOMAIN>/` | `302` to `https://<AUTH_DOMAIN>/…` |
| `https://<WIKI_DOMAIN>` in a browser | the Authelia login, then the vault with its page tree on the left |

## 7. Connect agents

- **Claude Code**, for every project of the user:
  ```bash
  claude mcp add -t http -s user ram https://<MCP_DOMAIN>/mcp \
    -H "Authorization: Bearer <TOKEN>"
  ```
- **GUI clients** (Claude web and mobile, ChatGPT developer mode): add
  `https://<MCP_DOMAIN>/mcp`, choose OAuth, and log in at `<AUTH_DOMAIN>`.
- More clients and OAuth troubleshooting: [README → Connect and verify](README.md#connect-and-verify).

## Several people on one instance

Authelia's user file holds as many users as you like. Each gets a password hash, generated as
in step 2.2:

```yaml
users:
  alice:
    displayname: 'Alice'
    password: '$argon2id$...'
    email: 'alice@example.com'
    groups: ['admins']
  bob:
    displayname: 'Bob'
    password: '$argon2id$...'
    email: 'bob@example.com'
    groups: ['wiki']
```

To add someone: edit `authelia/users_database.yml`, run
`gh secret set AUTHELIA_USERS < authelia/users_database.yml`, deploy. The deploy recreates
Authelia, which then reads the new file.

**Who gets in.** With the shipped `default_policy: one_factor`, every user in the file can log
in to both the wiki and MCP over OAuth. To narrow it:
- the wiki: add `access_control.rules` for `<WIKI_DOMAIN>` with a `subject`, such as
  `'group:wiki'`;
- MCP over OAuth: give the `ram-brain` client its own authorization policy with the same kind
  of `subject`.

**What it does not do.** Authelia only decides who gets in. Behind it everyone acts as the same
writer:
- everyone who logs in can read and change the whole vault; there are no per-folder rights;
- git history does not say which person made a change: the server commits under one identity,
  and the wiki adds a `(wiki)` suffix to it;
- agents with the bearer token never pass through Authelia and all share one token.

That suits a team that keeps one shared knowledge base and trusts each other. For a private
brain, each person should install their own instance.

**Passwords.** Authelia's notifier here writes to a file, not email, so "forgot password" mails
never arrive. An admin resets a password by putting a new hash into `users_database.yml`.
Configure an SMTP notifier to get self-service resets and two-factor (TOTP) enrollment.

## A second instance on the same host

- **Compose project name.** Give the second instance a different `name:` in its
  `docker-compose.yml`. With the same name, the two stacks would share containers and volumes.
- **Runner.** The second instance needs its own runner checkout. Also rename the workflow's
  `concurrency.group`, so the two deploys are not queued as one.
- **Tunnel and Authelia.** Separate ones are simplest. Sharing them works, but then a change to
  one instance can break the other.
