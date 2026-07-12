#!/usr/bin/env bash
#
# Build a Claude Desktop .mcpb bundle for a REMOTE (HTTP) MCP server.
#
# It wraps `mcp-remote` (a local stdio <-> HTTPS bridge) so Claude Desktop can
# talk to a remote streamable-HTTP MCP server. The bearer token is NOT baked in:
# it is declared as a `user_config` field and entered at install time, stored
# securely by Claude Desktop. The produced .mcpb is therefore safe to share.
#
# Defaults target this repo's `ram` server by reading MARKDOWN_VAULT_MCP_BASE_URL
# from .env. Override via env vars to build a bundle for any other remote MCP
# server, e.g.:
#
#   MCPB_NAME=foo MCPB_URL=https://foo.example/mcp ./build-mcpb.sh
#
# Requires: node + npm (Claude Desktop ships its own Node at runtime, so the
# built bundle needs nothing extra on the end-user's machine).

set -euo pipefail

# ---- paths ----
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

read_dotenv_var() {
  local key="$1" file="$ROOT/.env" line value
  [ -f "$file" ] || return 1
  line="$(grep -E "^${key}=" "$file" | tail -n 1 || true)"
  [ -n "$line" ] || return 1
  value="${line#*=}"
  value="${value%$'\r'}"
  case "$value" in
    \"*) value="${value#\"}"; value="${value%\"}" ;;
    \'*) value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s\n' "$value"
}

# ---- config (override via env) ----
export MCPB_NAME="${MCPB_NAME:-ram}"
export MCPB_DISPLAY="${MCPB_DISPLAY:-RAM — Random Agents Memories}"
export MCPB_VERSION="${MCPB_VERSION:-1.0.0}"
export MCPB_DESC="${MCPB_DESC:-Connect to ram-brain, the shared git-backed second-brain vault, over MCP (remote HTTPS bridged locally by mcp-remote).}"
export MCPB_AUTHOR="${MCPB_AUTHOR:-ram-brain}"
export MCP_REMOTE_VERSION="${MCP_REMOTE_VERSION:-latest}"

if [ -z "${MCPB_URL:-}" ]; then
  MCPB_BASE_URL="$(read_dotenv_var MARKDOWN_VAULT_MCP_BASE_URL || true)"
  if [ -z "$MCPB_BASE_URL" ] || [[ "$MCPB_BASE_URL" == *"<MCP_DOMAIN>"* ]]; then
    echo "ERROR: MCPB_URL is unset and MARKDOWN_VAULT_MCP_BASE_URL is missing or unfilled in .env" >&2
    exit 1
  fi
  export MCPB_URL="${MCPB_BASE_URL%/}/mcp"
fi

if [ -z "${MCPB_HOMEPAGE:-}" ]; then
  MCPB_BASE_URL="${MCPB_BASE_URL:-$(read_dotenv_var MARKDOWN_VAULT_MCP_BASE_URL || true)}"
  if [ -z "$MCPB_BASE_URL" ]; then
    MCPB_BASE_URL="${MCPB_URL%/mcp}"
  fi
  export MCPB_HOMEPAGE="${MCPB_BASE_URL%/}"
fi

export WORK="$ROOT/desktop"            # gitignored build workspace (regenerated)
OUT="$ROOT/${MCPB_NAME}.mcpb"          # gitignored output artifact

# ---- prerequisites ----
command -v node >/dev/null 2>&1 || { echo "ERROR: node not found on PATH" >&2; exit 1; }
command -v npm  >/dev/null 2>&1 || { echo "ERROR: npm not found on PATH"  >&2; exit 1; }

echo "==> building '${MCPB_NAME}.mcpb' for ${MCPB_URL}"
mkdir -p "$WORK"

# ---- package.json (pins the mcp-remote dependency) ----
cat > "$WORK/package.json" <<EOF
{
  "name": "${MCPB_NAME}-mcpb",
  "version": "${MCPB_VERSION}",
  "private": true,
  "description": "Build deps for the ${MCPB_NAME} .mcpb bundle (wraps mcp-remote).",
  "dependencies": { "mcp-remote": "${MCP_REMOTE_VERSION}" }
}
EOF

# ---- install the bridge ----
echo "==> installing mcp-remote@${MCP_REMOTE_VERSION}"
npm install --prefix "$WORK" --omit=dev --no-audit --no-fund >/dev/null

# ---- optional: introspect the server so we can DECLARE its tools ----
# Claude Desktop exposes a bundle's tools to the model from the manifest's
# `tools` array. A runtime tools/list alone is NOT enough (prompts/resources are
# surfaced, tools are not). If a token is provided we query the server and
# declare every tool; otherwise we fall back to tools_generated.
rm -f "$WORK/tools.json" "$WORK/ignore.json"
if [ -n "${MCPB_INTROSPECT_TOKEN:-}" ]; then
  echo "==> introspecting tools from ${MCPB_URL}"
  node - <<'NODE' || echo "   (introspection failed — falling back to tools_generated)"
const fs = require("fs");
const url = process.env.MCPB_URL, token = process.env.MCPB_INTROSPECT_TOKEN, WORK = process.env.WORK;
async function rpc(sid, method, params, notif) {
  const b = { jsonrpc: "2.0", method };
  if (!notif) b.id = 1;
  if (params !== undefined) b.params = params;
  const h = { Authorization: "Bearer " + token, "Content-Type": "application/json",
              Accept: "application/json, text/event-stream", "User-Agent": "curl/8.7.1" };
  if (sid) h["mcp-session-id"] = sid;
  const r = await fetch(url, { method: "POST", headers: h, body: JSON.stringify(b) });
  const ns = r.headers.get("mcp-session-id") || sid;
  let res = null;
  for (const ln of (await r.text()).split(/\r?\n/)) {
    const t = ln.trim();
    if (t.startsWith("data:")) { try { res = JSON.parse(t.slice(5).trim()); } catch {} }
  }
  return { sid: ns, res };
}
(async () => {
  const a = await rpc(null, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "mcpb-build", version: "0" } });
  await rpc(a.sid, "notifications/initialized", undefined, true);
  const t = await rpc(a.sid, "tools/list", {});
  const all = ((t.res && t.res.result && t.res.result.tools) || [])
    .map(x => ({ name: x.name, description: (x.title || x.description || x.name).split("\n")[0].slice(0, 140) }));
  if (!all.length) throw new Error("no tools returned");
  // Optional allow-list: keep only MCPB_TOOLS_INCLUDE, ignore the rest at the
  // bridge. Claude Desktop bridges local tools to the cloud model, and a huge
  // tool set (34 tools / ~75KB) does not get surfaced — so trim to essentials.
  const include = (process.env.MCPB_TOOLS_INCLUDE || "").split(",").map(s => s.trim()).filter(Boolean);
  const declared = include.length ? all.filter(x => include.includes(x.name)) : all;
  const ignore = include.length ? all.filter(x => !include.includes(x.name)).map(x => x.name) : [];
  fs.writeFileSync(WORK + "/tools.json", JSON.stringify(declared));
  fs.writeFileSync(WORK + "/ignore.json", JSON.stringify(ignore));
  console.log("   declared " + declared.length + " tools" + (ignore.length ? ", ignoring " + ignore.length + " at the bridge" : ""));
})().catch(err => { console.error("   introspection error:", err.message); process.exit(1); });
NODE
fi

# ---- manifest.json (emitted by node so ${...} template vars survive verbatim) ----
echo "==> writing manifest.json"
node - <<'NODE'
const fs = require("fs");
const e = process.env;
let declaredTools = null, ignoreTools = [];
try { declaredTools = JSON.parse(fs.readFileSync(e.WORK + "/tools.json", "utf8")); } catch {}
try { ignoreTools = JSON.parse(fs.readFileSync(e.WORK + "/ignore.json", "utf8")); } catch {}
// mcp-remote filters both tools/list and tools/call by --ignore-tool, so the
// trimmed set never reaches Claude Desktop.
const proxyArgs = ["${__dirname}/node_modules/mcp-remote/dist/proxy.js", e.MCPB_URL, "--header", "Authorization:${AUTH_HEADER}"];
for (const n of ignoreTools) proxyArgs.push("--ignore-tool", n);
const manifest = {
  manifest_version: "0.3",
  name: e.MCPB_NAME,
  display_name: e.MCPB_DISPLAY,
  version: e.MCPB_VERSION,
  description: e.MCPB_DESC,
  author: { name: e.MCPB_AUTHOR },
  homepage: e.MCPB_HOMEPAGE,
  // Claude Desktop surfaces bundle tools to the model from this DECLARED list.
  // With a token we introspect and list them all; without, we fall back to the
  // (weaker) tools_generated hint.
  ...(declaredTools && declaredTools.length ? { tools: declaredTools } : { tools_generated: true }),
  prompts_generated: true,
  server: {
    type: "node",
    entry_point: "node_modules/mcp-remote/dist/proxy.js",
    mcp_config: {
      command: "node",
      // ${__dirname} is an mcpb template var (bundle dir at runtime).
      // ${AUTH_HEADER} is expanded by mcp-remote from the env below.
      // ${user_config.token} is filled in by Claude Desktop at install time.
      args: proxyArgs,
      env: { AUTH_HEADER: "Bearer ${user_config.token}" },
    },
  },
  user_config: {
    token: {
      type: "string",
      title: "Bearer token",
      description:
        "Shared bearer token for this MCP server (ask the operator). " +
        "Not stored in the bundle; Claude Desktop keeps it securely.",
      sensitive: true,
      required: true,
    },
  },
};
fs.writeFileSync(e.WORK + "/manifest.json", JSON.stringify(manifest, null, 2) + "\n");
NODE

# ---- pack ----
echo "==> packing"
npx --yes @anthropic-ai/mcpb pack "$WORK" "$OUT" >/dev/null

echo "==> done"
ls -lh "$OUT"
