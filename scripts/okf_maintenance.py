"""OKF upkeep for the vault: the `okf-maintenance` service in docker-compose.yml.

It talks to the MCP server over the compose network with the bearer token, so
every change goes through the server: indexed, and with git committed and
pushed, like any agent's write. Nothing here touches the vault's files, and
it works the same in every storage mode.

Two ways to run it:

    python okf_maintenance.py --schedule   what the service does: wait for
                                           OKF_MAINTENANCE_AT, run, repeat
    python okf_maintenance.py              one run now; prints the report

Environment:
    MARKDOWN_VAULT_MCP_BEARER_TOKEN   the server's bearer token (required)
    OKF_MCP_URL                       the server's MCP endpoint
                                      (default http://127.0.0.1:8000/mcp)
    OKF_MAINTENANCE_AT                daily run time, HH:MM in the container's
                                      time zone (UTC unless TZ is set);
                                      `off` = never. Default 02:30
    MARKDOWN_VAULT_MCP_OKF_MODE       `off` = the service idles
    OKF_MAINTENANCE_RETRY_S           wait before a retry when the server
                                      cannot be reached (default 600)

Steps of a run:
1. `okf_convert_links`: wikilinks (the wiki's editor still inserts them)
   become root-relative markdown links.
2. Markdown links without `.md`: SilverBullet rewrites links that way when a
   page is renamed or moved in the browser, and the server treats them as
   broken. Each one whose `<target>.md` exists gets `.md` added; spaces become
   `%20` and `<...>` brackets are dropped.
3. `okf_generate_index` for the root and every folder. A call on the root only
   creates missing indexes, it never refreshes an existing one, so each folder
   gets its own call. Unchanged indexes are not rewritten.
4. `okf_validate` and `get_broken_links`: the report, printed as markdown.

Exit code of a run: 0 clean; 1 the audit found something (a note lacks `type`,
frontmatter does not parse, an index carries frontmatter, or a link is
broken); 2 the run itself failed (server unreachable, no token).
"""

import asyncio
import json
import os
import subprocess
import sys
import time

URL = os.environ.get("OKF_MCP_URL", "http://127.0.0.1:8000/mcp")
ATTEMPTS = 3


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
    # Imported here so the scheduler, which only sleeps, stays a small process.
    from fastmcp import Client
    from fastmcp.client.transports import StreamableHttpTransport

    token = os.environ.get("MARKDOWN_VAULT_MCP_BEARER_TOKEN", "")
    if not token:
        raise RuntimeError("MARKDOWN_VAULT_MCP_BEARER_TOKEN is not set")
    transport = StreamableHttpTransport(URL, headers={"Authorization": f"Bearer {token}"})
    out = ["## OKF maintenance", ""]

    async with Client(transport) as client:

        async def call(tool, **args):
            return _payload(await client.call_tool(tool, args))

        if "okf_validate" not in {tool.name for tool in await client.list_tools()}:
            print("The server offers no OKF tools (is MARKDOWN_VAULT_MCP_OKF_MODE off?); nothing to do.")
            return 0

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


def run_once() -> int:
    try:
        return asyncio.run(main())
    except Exception as error:  # the server is down, the token is wrong, ...
        print(f"OKF maintenance could not run: {type(error).__name__}: {error}", file=sys.stderr)
        return 2


# --- The service: one run a day at OKF_MAINTENANCE_AT ---


def _log(message: str) -> None:
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} okf-maintenance: {message}", flush=True)


def _idle(reason: str) -> None:
    _log(f"{reason}; idle")
    while True:
        time.sleep(3600)


def _parse_at(value: str):
    """`02:30` -> (2, 30); anything else -> None."""
    hour, sep, minute = value.partition(":")
    if not (sep and hour.isdigit() and minute.isdigit()):
        return None
    hour, minute = int(hour), int(minute)
    return (hour, minute) if hour < 24 and minute < 60 else None


def _next_run(hour: int, minute: int, now: float) -> float:
    """The next HH:MM, local time, strictly after `now`."""
    day = time.localtime(now)
    for offset in (0, 1):  # mktime normalises a day past the end of the month
        target = time.mktime((day.tm_year, day.tm_mon, day.tm_mday + offset, hour, minute, 0, 0, 0, -1))
        if target > now:
            return target
    return target


def schedule() -> None:
    if os.environ.get("MARKDOWN_VAULT_MCP_OKF_MODE", "").strip().lower() == "off":
        _idle("MARKDOWN_VAULT_MCP_OKF_MODE is off")
    if not os.environ.get("MARKDOWN_VAULT_MCP_BEARER_TOKEN"):
        _idle("MARKDOWN_VAULT_MCP_BEARER_TOKEN is not set, so the server cannot be reached")
    at = os.environ.get("OKF_MAINTENANCE_AT", "").strip() or "02:30"
    if at.lower() == "off":
        _idle("OKF_MAINTENANCE_AT is off")
    parsed = _parse_at(at)
    if parsed is None:
        _idle(f"OKF_MAINTENANCE_AT='{at}' is not HH:MM")
    retry_raw = os.environ.get("OKF_MAINTENANCE_RETRY_S", "").strip() or "600"
    if not retry_raw.isdigit():
        _log(f"OKF_MAINTENANCE_RETRY_S='{retry_raw}' is not a number of seconds; using 600")
        retry_raw = "600"
    retry = int(retry_raw)

    while True:
        target = _next_run(*parsed, time.time())
        _log(f"next run at {time.strftime('%Y-%m-%d %H:%M %Z', time.localtime(target))}")
        # Short naps, so a clock that jumps (NTP, a suspended host) is noticed.
        while (left := target - time.time()) > 0:
            time.sleep(min(left, 300))
        for attempt in range(1, ATTEMPTS + 1):
            # A child process: the report goes to this container's log, and the
            # MCP client's memory is given back between runs.
            code = subprocess.run([sys.executable, os.path.abspath(__file__)]).returncode
            if code != 2:
                break
            if attempt < ATTEMPTS:
                _log(f"run failed (a deploy in progress?); retrying in {retry}s")
                time.sleep(retry)
        result = {0: "clean", 1: "the audit found problems, see the report above"}.get(code, "failed")
        _log(f"run finished: {result}")


if __name__ == "__main__":
    if "--schedule" in sys.argv[1:]:
        schedule()
    else:
        sys.exit(run_once())
