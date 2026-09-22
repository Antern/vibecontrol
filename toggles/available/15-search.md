# Web search for local models

A local model without search answers from memory, and for anything current that
means answering confidently and wrongly. Asked for the latest llama.cpp release
tag with no tools, Qwen3.6 produced *"the v1.0.0 release (late 2024 / early 2025
era)"* -- fluent, plausible, invented. With the tools below it returned `b11103`,
published that morning.

## Shape

    harness (Claude Code)
      -> lib/mcp-search.py        stdio MCP server, stdlib only
         -> SearXNG               rootless podman container, 127.0.0.1:8888
            -> real search engines

Two tools are exposed: `web_search(query, count)` and `web_fetch(url, max_chars)`.

## Why not a packaged MCP server

Every widely used one needs a runtime this machine does not have -- node, uv or
pipx. The protocol is JSON-RPC over stdin and stdout, one object per line; a
hundred lines of standard library is a better trade than a new runtime and a
dependency tree. `lib/mcp-search.py` has no imports outside the stdlib.

## Why podman rather than docker

It was already installed, and it fits better: rootless by default, no daemon, so
a container is an ordinary systemd *user* unit like everything else here, kept
alive by the same linger that keeps the daemon running with no desktop. Quadlet
(`~/.config/containers/systemd/searxng.container`) generates the unit at
`systemctl --user daemon-reload`. Docker would work; nothing here depends on it.

## Setup notes worth keeping

- **SearXNG's `bind_address` is inside the container.** Setting it to
  `127.0.0.1` makes the service unreachable even from the host. Bind `0.0.0.0`
  there and let podman publish to `127.0.0.1:8888` on the host -- that is where
  the isolation belongs.
- **The json format is off by default.** `search.formats` must list `json` or
  every programmatic query returns HTML.
- **`limiter: false`**, since the only client is our own MCP server and the bot
  detection otherwise rejects it.
- The port is published to loopback only. SearXNG has no authentication and the
  hotspot carries other devices; a client on another machine should reach it
  over ssh rather than by opening the port.

## Registering with Claude Code

    claude mcp add --scope user websearch /path/to/lib/mcp-search.py

**Do not put a hyphen in the server name.** `vibe-search` registers and reports
healthy, but the tools never reach the model -- it reports `WebSearch` and
`WebFetch` denied and never sees the MCP ones. `websearch` yields
`mcp__websearch__web_search`, which works.

Claude Code's own `WebFetch` works against a local model, because the fetch
happens in the harness. Its `WebSearch` does not: that one is executed by
Anthropic's API, which a local endpoint bypasses entirely. That asymmetry is
the reason this server exists.

## A client on another machine

MCP stdio servers run wherever the harness runs, and this one needs SearXNG on
loopback. A harness on the laptop therefore cannot use it directly. The clean
answer is stdio over ssh -- register the command as
`ssh <user>@<hotspot-ip> /path/to/lib/mcp-search.py` -- which keeps the port closed
and needs no extra service. Not yet tested.

## Giving the model tools

`llama-server` spawns MCP servers itself. From the upstream docs:

> Only the stdio transport is supported: such a server is a child process
> reading JSON-RPC messages on its stdin and writing replies on its stdout, so
> nothing has to be started or maintained outside `llama-server`.

So the config is a Cursor-compatible file naming a command, not a URL:

    {"mcpServers": {"search": {"command": ".../lib/mcp-search.py", "args": []}}}

    llama-server ... --mcp-servers-config ~/.config/vibecontrol/mcp.json

pointed at by `llm.mcp_config`. Each server is spawned once at startup to list
its tools, stopped, then respawned on demand when a tool is called. The tools
appear as `<server>_<tool>` -- here `search_web_search` and `search_web_fetch`
-- in the web UI's tools panel and in `GET /tools`. Accepted keys per entry are
`command`, `args`, `env`, `cwd` and `timeout_ms`.

**`--cors-origins` must be set alongside it.** Declaring MCP servers makes the
server restrict CORS to `localhost`, which locks out a browser on any other
machine. `llm.cors_origins` names the real origin.

Two things that cost time here, both avoidable by reading
`tools/server/README.md` first:

- **`--ui-mcp-proxy` is unrelated.** The docs say so explicitly: it only lets
  the web UI reach *remote* MCP servers from the browser. It is not how
  server-side tools are provided, and an HTTP transport, a CORS proxy hop and a
  browser-side `mcpServers` setting were all built against that wrong guess
  before the docs were read.
- **`/tools` is internal to the web UI.** A plain `/v1/chat/completions` call
  does not get server tools injected and the model will correctly say it has no
  web access. That is not a fault; the UI runs the tool loop.

`lib/mcp-search.py` keeps its `--http` transport, unused by this path but
harmless, for any client that wants to reach it over HTTP directly.
