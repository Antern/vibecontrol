#!/usr/bin/env python3
"""MCP stdio server giving a model web search and page fetching.

Written against the standard library rather than pulling in one of the packaged
MCP servers, because every one of those needs a runtime this machine does not
have -- node, uv or pipx -- and the protocol is small enough that a dependency
is a worse trade than a hundred lines.

Search is backed by a local SearXNG (see toggles/71-search.toggle): no API key,
no account, and the query leaves the machine only as an ordinary search.

  web_search(query, count=5)  -> titles, urls and snippets
  web_fetch(url, max_chars)   -> readable text of a page

Two transports:

  stdio (default)  JSON-RPC 2.0, one object per line, on stdin/stdout. Anything
                   printed to stdout that is not a response corrupts the
                   stream, so all diagnostics go to stderr.
  --http PORT      the same JSON-RPC over HTTP POST, which is what a browser
                   based client needs -- llama-server's web UI reaches MCP
                   servers through its own CORS proxy, and that proxy speaks
                   HTTP, not pipes.
"""
import html
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

SEARX = os.environ.get("SEARXNG_URL", "http://127.0.0.1:8888")
UA = "vibecontrol-mcp-search/1.0"
TIMEOUT = 25

TOOLS = [
    {
        "name": "web_search",
        "description": (
            "Search the web and return titles, URLs and snippets. Use this "
            "whenever a question depends on current information rather than "
            "recall, then fetch the promising URLs with web_fetch."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "search terms"},
                "count": {"type": "integer", "description": "results, default 5"},
            },
            "required": ["query"],
        },
    },
    {
        "name": "web_fetch",
        "description": "Fetch a URL and return its readable text content.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string"},
                "max_chars": {"type": "integer",
                              "description": "truncate at this many characters, default 20000"},
            },
            "required": ["url"],
        },
    },
]


def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        charset = r.headers.get_content_charset() or "utf-8"
        return r.read().decode(charset, "replace")


def web_search(query, count=5):
    qs = urllib.parse.urlencode({"q": query, "format": "json"})
    try:
        doc = json.loads(_get(f"{SEARX}/search?{qs}"))
    except urllib.error.URLError as e:
        return (f"search backend unreachable at {SEARX}: {e}. "
                "Is the search toggle on?")
    results = doc.get("results", [])[: max(1, int(count))]
    if not results:
        return f"no results for {query!r}"
    out = []
    for i, r in enumerate(results, 1):
        out.append(f"{i}. {r.get('title','').strip()}\n   {r.get('url','')}\n"
                   f"   {(r.get('content') or '').strip()[:300]}")
    return "\n".join(out)


def web_fetch(url, max_chars=20000):
    if not re.match(r"^https?://", url):
        return "url must be http or https"
    try:
        doc = _get(url)
    except (urllib.error.URLError, urllib.error.HTTPError) as e:
        return f"could not fetch {url}: {e}"
    # Crude but dependency-free: drop the parts that never contain prose, then
    # strip the remaining tags. Good enough to feed a model; not a parser.
    doc = re.sub(r"(?is)<(script|style|noscript|svg|head)\b.*?</\1>", " ", doc)
    doc = re.sub(r"(?s)<!--.*?-->", " ", doc)
    doc = re.sub(r"(?i)<(br|/p|/div|/li|/h[1-6])\s*>", "\n", doc)
    text = html.unescape(re.sub(r"(?s)<[^>]+>", " ", doc))
    text = re.sub(r"[ \t\r\f\v]+", " ", text)
    text = re.sub(r"\n\s*\n\s*", "\n\n", text).strip()
    n = max(500, int(max_chars))
    return text[:n] + ("\n\n[truncated]" if len(text) > n else "")


def call_tool(name, args):
    if name == "web_search":
        return web_search(args.get("query", ""), args.get("count", 5))
    if name == "web_fetch":
        return web_fetch(args.get("url", ""), args.get("max_chars", 20000))
    raise KeyError(name)


def handle(msg):
    """One JSON-RPC message in, one response out, or None for a notification.

    Shared by both transports so they cannot drift apart.
    """
    method, mid = msg.get("method"), msg.get("id")
    if mid is None:                     # notification: must not be answered
        return None
    if method == "initialize":
        params = msg.get("params") or {}
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": params.get("protocolVersion", "2024-11-05"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "vibecontrol-search", "version": "1.0"}}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        params = msg.get("params") or {}
        try:
            text = call_tool(params.get("name"), params.get("arguments") or {})
            result = {"content": [{"type": "text", "text": text}]}
        except KeyError as e:
            result = {"content": [{"type": "text", "text": f"no such tool: {e}"}],
                      "isError": True}
        except Exception as e:                          # noqa: BLE001
            result = {"content": [{"type": "text", "text": f"tool failed: {e}"}],
                      "isError": True}
        return {"jsonrpc": "2.0", "id": mid, "result": result}
    return {"jsonrpc": "2.0", "id": mid,
            "error": {"code": -32601, "message": "method not found"}}


def serve_http(port):
    """JSON-RPC over POST, with the CORS headers a browser client needs."""
    import http.server

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _cors(self):
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "*")
            self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")

        def do_OPTIONS(self):           # noqa: N802
            self.send_response(204); self._cors(); self.end_headers()

        def do_POST(self):              # noqa: N802
            n = int(self.headers.get("Content-Length") or 0)
            try:
                msg = json.loads(self.rfile.read(n) or b"{}")
            except json.JSONDecodeError:
                self.send_response(400); self._cors(); self.end_headers(); return
            reply = handle(msg)
            body = b"" if reply is None else json.dumps(reply).encode()
            # A notification gets 202 and no body; anything else gets its answer.
            self.send_response(202 if reply is None else 200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self._cors(); self.end_headers()
            if body:
                self.wfile.write(body)

        def log_message(self, *a):      # keep stdout clean
            pass

    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


def main():
    if "--http" in sys.argv:
        return serve_http(int(sys.argv[sys.argv.index("--http") + 1]))
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        reply = handle(msg)
        if reply is not None:
            print(json.dumps(reply), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
