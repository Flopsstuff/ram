# Install your own ram

This recipe stands up a new, independent instance from scratch: its own vault, its own hostname,
its own host. The result is one docker compose stack: you fill in the configuration once and
run `docker compose up -d`. Nothing else is needed; deploying from GitHub Actions is optional
and comes last (step 6). Plan about an hour; most of it is waiting for DNS. What each piece
does and why it is built this way is in [README.md](README.md).

> **Pick a storage mode first.** The vault always lives on the `vault-data` docker volume. A
> git remote and a bucket are optional and independent, so there are four modes:
>
> | Mode | What you get | Steps to skip |
> | --- | --- | --- |
> | **Git** (the template's default) | every write committed and pushed to a GitHub repo: an off-host copy, full history, a merge when two sides edit one note | **(bucket only)** |
> | **Volume only** | a plain folder on the volume. No off-host copy, no history, no rollback of an overwritten note | **(git only)**, **(bucket only)** |
> | **Bucket** | the plain folder, mirrored to an S3-compatible bucket every few minutes, with replaced and deleted files kept for 30 days. A new, empty volume is filled from the bucket | **(git only)** |
> | **Git + bucket** | git as above, plus the bucket as a second copy. An empty volume is filled by `git clone`, never from the bucket | none |
>
> The wiki works in every mode. With git it has its own clone, and a browser edit reaches the
> agents' search after the push delay plus the pull interval. Without git it works on the
> server's own folder, and a browser edit is searchable within seconds. Without git there is
> also no merge: when an agent and the browser write the same file at once, the last write
> wins.

## 0. What you need

| Item | Notes |
| --- | --- |
| An always-on host with Docker + Compose v2 | No inbound ports: all traffic arrives through the tunnel. |
| A domain on Cloudflare | **One hostname**, `<DOMAIN>` (for example `brain.` of your domain). Everything is served from it, by path: the MCP endpoint at `/mcp`, the wiki at `/wiki/`, the login portal at `/sso/`. |
| A GitHub account **(git only)** | Owns the vault repo. The fine-grained token in step 1 must belong to this same account: it can't reach a repo where it is only a collaborator. |
| An S3-compatible bucket **(bucket only)** | Google Cloud Storage, DigitalOcean Spaces, AWS S3, Cloudflare R2 or MinIO. Step 2.4. |
| A Google AI Studio API key | For `gemini-embedding-2`. Create one at <https://aistudio.google.com/apikey>. |
| Where you prepare the configuration (the host itself, or a laptop) | `git`, `docker`, `cloudflared`, `openssl`. Also `gh`, logged in, for the git mode and for step 6. |

## 1. Repositories

1. **Infra repo.** Clone this repository onto the host. Fork it first if you want to deploy
   from GitHub Actions (step 6) or keep changes of your own. Real configuration never lands in
   git, only the `*.example` templates, so a fork can stay public.
2. **Vault repo (git only).** Create a private repo with one first commit:
   ```bash
   gh repo create <owner>/<vault-repo> --private --add-readme
   ```
3. **The vault's rules.** Add a root `_conventions.md` to the vault (without git, write it
   through the server once it is up): which folder holds what,
   required frontmatter, how to link notes, and "never write secret values". Agents fetch it
   with `get_conventions` before writing, and every write result repeats it. Folders can get
   their own `_conventions.md` later; they add to the root rules.
4. **Token for the server (git only).** A fine-grained personal access token. Its owner is the vault
   repo's owner, it has access to that one repo only, with *Contents: Read and write*.

## 2. Configuration

Everything below happens in your clone of the infra repo. The real files are gitignored.

### 2.1 `.env`

Copy `.env.example` to `.env` and fill in:

| Variable | Value |
| --- | --- |
| `MARKDOWN_VAULT_MCP_BASE_URL` | `https://<DOMAIN>`, with no path: the MCP server owns the root of the hostname |
| `MARKDOWN_VAULT_MCP_BEARER_TOKEN` | `openssl rand -hex 32`: the shared token for headless agents |
| `MARKDOWN_VAULT_MCP_GIT_REPO_URL` **(git only)** | `https://github.com/<owner>/<vault-repo>.git` (HTTPS only). Without git, leave every `GIT_*` variable unset |
| `MARKDOWN_VAULT_MCP_GIT_TOKEN` **(git only)** | the token from step 1.4 |
| `MARKDOWN_VAULT_MCP_GIT_COMMIT_NAME` / `_EMAIL` **(git only)** | the identity on the server's commits; required with git |
| `WIKI_VOLUME` | **without git:** `vault-data`, so the wiki works on the server's volume. **With git:** leave it unset; the wiki gets its own clone on `wiki-data`. `wiki-sync` refuses to start on a wrong pairing and says so in its log |
| `BUCKET_*` **(bucket only)** | step 2.4 |
| `OPENAI_API_KEY` | the AI Studio key. The bare name, no prefix: the server talks to Gemini through its OpenAI-compatible endpoint |
| `MARKDOWN_VAULT_MCP_INSTANCE_DESCRIPTION` | one line on what this vault is for |
| `MARKDOWN_VAULT_MCP_INSTRUCTIONS_EXTRA` | your rules for agents: language, search habits, when to offer saving knowledge. Keep both under ~500 characters in total: Claude Code cuts a server's instructions at 2,048 |
| `MARKDOWN_VAULT_MCP_OIDC_CONFIG_URL` | `https://<DOMAIN>/sso/.well-known/openid-configuration`: Authelia lives under `/sso` |
| the other `MARKDOWN_VAULT_MCP_OIDC_*` | step 2.2 |
| `CF_TUNNEL_ID`, `TUNNEL_CRED_CONTENTS` | step 2.3 |
| `OKF_MAINTENANCE_AT` (optional) | when the daily OKF upkeep runs: `HH:MM` in UTC, or in `TZ` if you set it. Unset means `02:30`; `off` disables it |

Leave `AUTH_MODE` unset. With both the bearer token and the OIDC block present, the server
enables both login paths by itself.

Keep `MARKDOWN_VAULT_MCP_EXCLUDE` as the template has it. Its last four patterns are
SilverBullet's own files (`CONFIG.md`, `Library/`, `_plug/`, `.silverbullet*`). Without git the
wiki keeps them in the vault folder itself, and these patterns are what keeps them out of the index and the agents' search results.
The names are therefore reserved at the vault root: a note at such a path is not indexed.

### 2.2 Authelia

Copy `authelia/configuration.yml.example` and `authelia/users_database.yml.example` to their
real names and replace `<DOMAIN>` with your hostname. These values in `configuration.yml` hold
the hostname or the `/sso` prefix:

| Value | Set to |
| --- | --- |
| `server.address` | `'tcp://:9091/sso'`, as the template has it. The path is the prefix Authelia is served under |
| `session.cookies[].domain` | `<DOMAIN>`: the hostname itself |
| `session.cookies[].authelia_url` | `https://<DOMAIN>/sso` |
| `session.cookies[].default_redirection_url` | `https://<DOMAIN>/wiki/` |
| `redirect_uris` of the `ram-brain` client | `https://<DOMAIN>/auth/callback` |
| `audience` of the `ram-brain` client | `https://<DOMAIN>` and `https://<DOMAIN>/mcp` |

With them the login portal is `https://<DOMAIN>/sso/` and the OIDC issuer is
`https://<DOMAIN>/sso`.

**The `/sso` prefix is written in three places, and they must agree:** `server.address` here,
the `/sso/` locations in `proxy/nginx.conf`, and `MARKDOWN_VAULT_MCP_OIDC_CONFIG_URL` in `.env`.
The templates agree as shipped, so leave the prefix alone. `/auth` cannot be used instead: the
MCP server owns `/auth/callback`.

Then generate the secrets:

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
cloudflared tunnel login                  # opens a browser, pick your domain
cloudflared tunnel create <tunnel>        # prints the tunnel ID and a creds file
cloudflared tunnel route dns <tunnel> <DOMAIN>
```

In `.env`, set `CF_TUNNEL_ID` to the tunnel ID and `TUNNEL_CRED_CONTENTS` to the creds file's
JSON on one line. That is all the tunnel needs. There is no ingress file: compose points the
tunnel at the `proxy` service, and `proxy` routes by path.

**Do not put Cloudflare Access in front of `<DOMAIN>`.** It replaces the bearer header headless
agents send and gets in the way of both Authelia login flows.

### 2.4 Bucket (bucket only)

The `vault-mirror` service copies the vault into the bucket with rclone. It does not create the
bucket: create it first, with a key pair that can list, read, write and delete objects in it.

**Google Cloud Storage.** Create the bucket. Then open *Cloud Storage → Settings →
Interoperability* and create an HMAC key, best for a service account that has object access to
this one bucket. The access key and secret are shown once.

**DigitalOcean Spaces.** Create a Space; its name is the bucket name. Then generate a Spaces
access key. `<region>` is the Space's region slug.

| Variable | Google Cloud Storage | DigitalOcean Spaces |
| --- | --- | --- |
| `BUCKET_NAME` | `<bucket>` | `<bucket>` |
| `BUCKET_PROVIDER` | `GCS` | `DigitalOcean` |
| `BUCKET_ENDPOINT` | `https://storage.googleapis.com` | `https://<region>.digitaloceanspaces.com` |
| `BUCKET_ACCESS_KEY` | the HMAC access key | the Spaces access key |
| `BUCKET_SECRET_KEY` | the HMAC secret | the Spaces secret key |

`.env.example` also lists the values for AWS S3 and Cloudflare R2. Three more variables are
optional:

| Variable | Default | Meaning |
| --- | --- | --- |
| `BUCKET_PREFIX` | the bucket root | a folder inside the bucket, so one bucket can hold more than this vault |
| `BUCKET_SYNC_INTERVAL_S` | `300` | seconds between mirror passes |
| `BUCKET_HISTORY_DAYS` | `30` | days to keep replaced and deleted files; `0` keeps them forever |

All of this rides in `.env`, so in the `DOTENV` secret. There is no extra config file and no
extra secret.

**What ends up in the bucket.**

- `<prefix>/vault/`: the vault as it is now. Symlinks are not copied, and a bucket keeps no
  empty folders.
- `<prefix>/history/<UTC time>/`: the files one mirror pass replaced or deleted, as they were
  before it, at the same paths. The folder is named after the time of that pass, for example
  `2026-01-31T142500Z`.

`.git/` and SilverBullet's caches (`_plug/`, `.silverbullet*`) are not copied.

**Restore.** It is automatic and happens only without git: when `vault-mirror` starts on a
volume it has not seen before, finds no notes in it and a copy in the bucket, it downloads the
copy before the server and the wiki come up. So moving to a new host, or recovering from a lost volume, is a normal deploy with the
same `BUCKET_*` values. With git the volume is filled by `git clone` and the bucket is never
read back. Two things follow:

- The mirror leaves a marker file, `.mirror-known`, in the volume it works on. A wiped or
  replaced volume has no marker, so it is restored, never mirrored over the bucket. A vault
  you emptied yourself keeps the marker: the deletion is mirrored, the notes move to
  `history/`, and nothing comes back on the next start.
- The deploy waits up to 15 minutes for a restore. A vault of notes takes seconds; if yours
  takes longer, the deploy fails, the restore goes on in the `vault-mirror` container, and you
  run the deploy again once its log says `restore done`.
- Without git and with an empty volume, while the bucket cannot be listed (wrong name, keys or
  endpoint), `vault-mirror` keeps retrying, and the server and the wiki wait for it: it cannot
  tell yet whether there is something to restore. Its log names the error. Once the volume has
  notes, a broken bucket setting stops only the mirroring.

**One old version back.** In your provider's console or any S3 client, open
`<prefix>/history/`, find the folder for the pass that replaced the file (the first one after
the bad edit) and download the file. Then put the text back through the wiki or an agent. Do
not copy it into `<prefix>/vault/`: the bucket is a one-way copy, an object changed there does
not reach the running server, and the next pass replaces it. A version exists only if a mirror
pass saw it: two edits between two passes leave one history entry, not two.

## 3. Start

On the host, in your clone, with the three configuration files in place (`.env`,
`authelia/configuration.yml`, `authelia/users_database.yml`):

```bash
docker compose up -d
```

That is the whole install. On its first start with git the server clones the vault and embeds
it: seconds for a fresh vault, one embedding call per section for a big one. The wiki makes its
own clone next to it. Without git the vault starts empty, or is first filled from the bucket if
the bucket has a copy, and the wiki opens the same folder.

**Day to day**, all on the host, in the clone:

| To | Run |
| --- | --- |
| apply a changed `.env` | `docker compose up -d` |
| apply a changed config file or script | `docker compose up -d --force-recreate <service>`. Compose does not notice that a mounted file changed, so a plain `up -d` keeps the old one |
| update to the newest images | `docker compose pull`, then `docker compose up -d`. Nothing does this for you |
| take a new version of this repo | `git pull`, then `docker compose up -d --force-recreate` |
| read a service's log | `docker compose logs -f <service>` |
| stop | `docker compose down`. The data stays in the volumes; `down -v` deletes it |

**OKF upkeep.** The `okf-maintenance` service tidies the vault once a day, at
`OKF_MAINTENANCE_AT`: wikilinks the wiki inserts become markdown links, links the wiki left
without `.md` get it back, every folder's `index.md` is regenerated, and an audit lists notes
that break the format and links that lead nowhere. The report is in its log:

```bash
docker compose logs okf-maintenance
```

To run it now and see the report:

```bash
docker compose exec okf-maintenance \
  python /etc/ram/scripts/okf_maintenance.py
```

## 4. Verify

| Check | Expect |
| --- | --- |
| `curl -i https://<DOMAIN>/mcp` | `401` with a `WWW-Authenticate` header |
| `curl -i https://<DOMAIN>/mcp -H "Authorization: Bearer <TOKEN>"` | an MCP response |
| `curl -sI https://<DOMAIN>/sso/.well-known/openid-configuration` | `200` |
| `curl -sI https://<DOMAIN>/` | `302` to `/wiki/` |
| `curl -sI https://<DOMAIN>/wiki/` | `302` to `https://<DOMAIN>/sso/?rd=…` |
| `https://<DOMAIN>/sso/` in a browser | the Authelia login portal |
| `https://<DOMAIN>` in a browser | the Authelia login, then the vault at `/wiki/` with its page tree on the left |
| `docker compose logs vault-mirror` on the host **(bucket only)** | `running: mirror to …`, and no `mirror pass failed` after it |
| `docker compose logs wiki-sync` on the host, if the wiki does not come up | a line that says which `WIKI_VOLUME` setting it expects |
| `docker compose logs okf-maintenance` on the host | `next run at …` |

## 5. Connect agents

- **Claude Code**, for every project of the user:
  ```bash
  claude mcp add -t http -s user ram https://<DOMAIN>/mcp \
    -H "Authorization: Bearer <TOKEN>"
  ```
- **GUI clients** (Claude web and mobile, ChatGPT developer mode): add
  `https://<DOMAIN>/mcp`, choose OAuth, and log in at the Authelia portal the client opens
  (`https://<DOMAIN>/sso/`).

### If the OAuth login fails

Two fixes go into the `ram-brain` client in `authelia/configuration.yml`:

- **`invalid_target` at the login redirect.** MCP clients send
  `resource=https://<DOMAIN>/mcp` (RFC 8707). Add `https://<DOMAIN>` and
  `https://<DOMAIN>/mcp` to the client's `audience`.
- **`invalid_client` at the token exchange.** The server authenticates with HTTP Basic. Set
  `token_endpoint_auth_method: 'client_secret_basic'`.

And check the addresses: `MARKDOWN_VAULT_MCP_OIDC_CONFIG_URL` must carry the `/sso` prefix, and
the hostname must be the same in `.env` and in `authelia/configuration.yml` (the table in step
2.2).

## 6. Deploy from GitHub Actions (optional)

`.github/workflows/deploy.yml` runs the same `docker compose` for you, on a self-hosted runner
on the host: on every push to `main` of your fork, on demand, and once a week to refresh the
images. Skip this step and the stack works the same; you then update it by hand (step 3).

1. **Runner.** Register a self-hosted runner for **your** fork: *Settings → Actions → Runners →
   New self-hosted runner*, and follow the commands GitHub shows. Install it as a service so it
   comes back after a reboot. Its user must be able to run `docker`.
2. **Secrets.** The deploy job starts from a clean checkout, so it rebuilds every gitignored
   file from a secret on each run:

   ```bash
   gh secret set DOTENV          < .env
   gh secret set AUTHELIA_CONFIG < authelia/configuration.yml
   gh secret set AUTHELIA_USERS  < authelia/users_database.yml
   ```

3. **First deploy.**

   ```bash
   gh workflow run deploy.yml
   gh run watch
   ```

From now on a config change means: edit the file, update its secret, deploy. The runner reads
the secret, not your local file. Every push to `main` deploys too; put `[skip ci]` in a commit
message to skip one. A stack you started by hand keeps its data when the runner takes over: the
compose project, and so the volumes, are the same.

## Rotating credentials

Change the value and apply it as in step 3. If you deploy from GitHub: update the secret and
deploy.

| Rotate | Effect |
| --- | --- |
| `MARKDOWN_VAULT_MCP_BEARER_TOKEN` | every bearer agent needs the new token |
| `MARKDOWN_VAULT_MCP_GIT_TOKEN` | sync stops for the server and the wiki until `.env` has the new one |
| `BUCKET_ACCESS_KEY` / `BUCKET_SECRET_KEY` | mirroring stops until `.env` has the new pair |
| `MARKDOWN_VAULT_MCP_OIDC_JWT_SIGNING_KEY` | the **OAuth kill switch**: every OAuth token dies at once |
| a password in `users_database.yml` | that user logs in with the new one |

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

To add someone: edit `authelia/users_database.yml`, then
`docker compose up -d --force-recreate authelia`, so Authelia reads the new file. If you deploy
from GitHub: `gh secret set AUTHELIA_USERS < authelia/users_database.yml`, then deploy.

**Who gets in.** With the shipped `default_policy: one_factor`, every user in the file can log
in to both the wiki and MCP over OAuth. To narrow it:
- the wiki: add `access_control.rules` for `<DOMAIN>` with a `subject`, such as
  `'group:wiki'`. The wiki is the only thing these rules are asked about;
- MCP over OAuth: give the `ram-brain` client its own authorization policy with the same kind
  of `subject`.

**What it does not do.** Authelia only decides who gets in. Behind it everyone acts as the same
writer:
- everyone who logs in can read and change the whole vault; there are no per-folder rights;
- with git, history does not say which person made a change: the server commits under one
  identity, and the wiki adds a `(wiki)` suffix to it. Without git there is no history at all;
- agents with the bearer token never pass through Authelia and all share one token.

That suits a team that keeps one shared knowledge base and trusts each other. For a private
brain, each person should install their own instance.

**Passwords.** Authelia's notifier here writes to a file, not email, so "forgot password" mails
never arrive. An admin resets a password by putting a new hash into `users_database.yml`.
Configure an SMTP notifier to get self-service resets and two-factor (TOTP) enrollment.

## A second instance on the same host

- **Compose project name.** Give the second instance a different `name:` in its
  `docker-compose.yml`. With the same name, the two stacks would share containers and volumes.
- **Runner**, if you deploy from GitHub. The second instance needs its own runner checkout.
  Also rename the workflow's `concurrency.group`, so the two deploys are not queued as one.
- **Bucket.** Two instances can share one bucket only with different `BUCKET_PREFIX` values.
- **Hostname, tunnel and Authelia.** Each instance gets its own. The tunnel hands every request
  to one `proxy`, so it cannot serve two stacks, and Authelia's cookie and issuer belong to one
  hostname.

## Moving from three hostnames

Earlier versions of this repo used three hostnames, one each for the MCP server, the login
portal and the wiki, split by an ingress file for the tunnel. To move such an install to one
hostname:

1. **Pick `<DOMAIN>`.** Keep the old MCP hostname if you can: bearer agents then go on working
   with the address they have.
2. **Take the new version** of this repo (`git pull`).
3. **Change the configuration as in the templates.**
   - `authelia/configuration.yml`: `server.address` becomes `'tcp://:9091/sso'`, and the
     `session.cookies` block gets the three values from the table in step 2.2. If `<DOMAIN>`
     is not the old MCP hostname, the client's `redirect_uris` and `audience` change too.
   - `.env`: `MARKDOWN_VAULT_MCP_OIDC_CONFIG_URL` gets the `/sso` prefix, and
     `MARKDOWN_VAULT_MCP_BASE_URL` changes if the hostname does.
   - `authelia/users_database.yml` stays as it is.
   - `cloudflared/config.yml` is no longer read. Delete it.
4. **Deploy.** By hand:
   ```bash
   docker compose up -d --force-recreate --remove-orphans
   ```
   `--remove-orphans` takes away the old `wiki-proxy` container. If you deploy from GitHub:
   update the `DOTENV` and `AUTHELIA_CONFIG` secrets, then deploy. The `CLOUDFLARED_CONFIG`
   secret is no longer read and can be deleted.
5. **DNS.** Remove the two records that are no longer used, the old login and wiki hostnames,
   in the Cloudflare dashboard. If `<DOMAIN>` is a new name, route it to the tunnel as in step
   2.3.

What to expect afterwards:

- **OAuth clients log in again**: Authelia's issuer address has changed.
- **Bearer agents** keep working if `<DOMAIN>` is the old MCP hostname. Otherwise give them the
  new address.
- **The wiki moves** to `https://<DOMAIN>/wiki/`. An installed PWA has to be reinstalled.
- **No login loop from a stale cookie**: the session cookie is renamed (`session.name:
  'ram_session'` in `authelia/configuration.yml`), so a browser's old parent-domain cookie is
  ignored rather than shadowing the new one. Keep that rename when you edit the config.
