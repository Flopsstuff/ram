"""Nightly OKF upkeep for the vault, run inside the markdown-vault-mcp container.

`.github/workflows/okf-maintenance.yml` pipes this file into
`docker compose exec -T markdown-vault-mcp python -`. It talks to the server
over MCP on localhost with the bearer token from the container's own
environment, so every change goes through the server: committed, pushed and
reindexed like any agent's write. Nothing here touches the vault's files.

Steps:
1. `okf_convert_links`: wikilinks (the wiki's editor still inserts them)
   become root-relative markdown links.
2. Markdown links without `.md`: SilverBullet rewrites links that way when a
   page is renamed or moved in the browser, and the server treats them as
   broken. Each one whose `<target>.md` exists gets `.md` added; spaces become
   `%20` and `<...>` brackets are dropped.
3. `okf_generate_index` for the root and every folder. A call on the root only
   creates missing indexes, it never refreshes an existing one, so each folder
   gets its own call. Unchanged indexes produce no commit.
4. `okf_validate` and `get_broken_links`: the summary is printed as markdown
   for the job summary, and the exit code is non-zero if a note lacks `type`,
   frontmatter does not parse, an index carries frontmatter, or a link is
   broken.
"""

import asyncio
import json
import os
import sys

from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport

URL = "http://127.0.0.1:8000/mcp"


def _payload(result):
    data = result.structured_content
    if data is None and result.content:
        data = json.loads(result.content[0].text)
    if isinstance(data, dict) and set(data) == {"result"}:
        return data["result"]
    return data


def _with_md(raw: str) -> str:
    """`/a/b c#H` or `</a/b c#H>` -> `/a/b%20c.md#H`."""
    target = raw[1:-1] if raw.startswith("<") and raw.endswith(">") else raw
    path, sep, fragment = target.partition("#")
    if not path.lower().endswith(".md"):
        path += ".md"
    return path.replace(" ", "%20") + sep + fragment


async def main() -> int:
    token = os.environ["MARKDOWN_VAULT_MCP_BEARER_TOKEN"]
    transport = StreamableHttpTransport(URL, headers={"Authorization": f"Bearer {token}"})
    out = ["## OKF maintenance", ""]

    async with Client(transport) as client:

        async def call(tool, **args):
            return _payload(await client.call_tool(tool, args))

        # 1. Wikilinks -> markdown links.
        converted = await call("okf_convert_links")
        out.append(f"- **convert_links:** `{json.dumps(converted, ensure_ascii=False)}`")

        # 2. Extensionless markdown links left by the wiki.
        fixed, skipped = [], []
        for link in await call("get_broken_links", wait_for_pending_writes=True):
            raw = link.get("raw_target") or ""
            target = link.get("target_path") or ""
            if link.get("link_type") != "markdown" or target.lower().endswith(".md"):
                continue
            try:
                await call("read", path=target + ".md")
            except Exception:
                skipped.append(f"{link['source_path']} → {raw}")
                continue
            note = await call("read", path=link["source_path"])
            old, new = f"]({raw})", f"]({_with_md(raw)})"
            lines = note["content"].split("\n")
            for number, line in enumerate(lines, start=1):
                while old in line:
                    note = await call("read", path=link["source_path"])
                    await call(
                        "edit",
                        path=link["source_path"],
                        old_text=old,
                        new_text=new,
                        line_start=number,
                        line_end=number,
                        if_match=note["etag"],
                    )
                    line = line.replace(old, new, 1)
                    fixed.append(f"{link['source_path']}: {raw} → {_with_md(raw)}")
        out.append(f"- **links given `.md`:** {len(fixed)}")
        out += [f"  - `{entry}`" for entry in fixed]
        if skipped:
            out.append(f"- **broken links with no `.md` match (left as is):** {len(skipped)}")
            out += [f"  - `{entry}`" for entry in skipped]

        # 3. Indexes: root first (creates missing ones), then every folder.
        folders = await call("list_folders", wait_for_pending_writes=True)
        for folder in [""] + [f for f in folders if f]:
            await call("okf_generate_index", folder=folder)
        out.append(f"- **indexes regenerated:** {len(folders)} folders")

        # 4. Audit.
        report = await call("okf_validate")
        broken = await call("get_broken_links", wait_for_pending_writes=True)

    failures = {
        key: report[key]["count"]
        for key in ("missing_type", "unparseable_frontmatter", "index_frontmatter", "misplaced_okf_version")
        if report.get(key, {}).get("count")
    }
    out += [
        f"- **okf_validate:** {report['conformant_notes']}/{report['total_notes']} conformant, "
        f"declared `{report['declared_version']}`, wikilink files "
        f"{report['wikilink_files']['count']}, unknown status {report['unknown_status']['count']}",
        f"- **broken links:** {len(broken)}",
    ]
    out += [f"  - `{b['source_path']}` → `{b.get('raw_target')}`" for b in broken]
    if failures:
        out.append(f"- **conformance failures:** `{failures}`")
    print("\n".join(out))
    return 1 if failures or broken else 0


sys.exit(asyncio.run(main()))
