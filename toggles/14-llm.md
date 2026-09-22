# Local LLM host prerequisites

`70-llm.toggle` runs `llama-server` on the discrete GPU and exposes an
OpenAI-compatible API. The point is to serve an editor on another machine over
the hotspot, so the toggle is `category="common"`: it has to work with no
desktop running, which is also when the GPU has its memory back.

## What the pieces are

Only the bottom four live on this machine. The agent loop does not.

    editor / client      Cursor on the laptop
    harness              the agent loop: system prompt, tool definitions,
                         parsing tool calls, executing them, looping
    ---------------------------------------------------------------
    server / API         llama-server, OpenAI-compatible HTTP
    chat template        model-specific prompt format, Jinja, inside the GGUF
    inference engine     llama.cpp + ROCm on the 9070 XT
    weights              the .gguf file

The harness decides whose filesystem the agent edits, because that is where
tool calls execute. Harness on the laptop means the laptop's code; this machine
only ever sees text and returns tokens, holding no repo and no state between
requests.

## The architecture name is not the model name

A GGUF declares `general.architecture`, and that is what llama.cpp looks up.
For Qwen3.8-27B it is **`qwen35`**, not `qwen38`:

    general.name           Qwen3.8-27B
    general.architecture   qwen35

Upstream has no `qwen38`; Qwen3.8 reuses the Qwen3.5 architecture. A build that
does not implement `qwen35` fails with `unknown model architecture: 'qwen35'`
no matter which quant is used.

## Fedora's llama-cpp cannot load it

`llama-cpp-b6153-3.fc44` is the only version in the repos and predates the
architecture. It supports `qwen`, `qwen2`, `qwen2moe`, `qwen2vl`, `qwen3` and
`qwen3moe` — so Qwen3 and DeepSeek models run on the stock package, and
Qwen3.8 does not.

Rebuilding Fedora's own source RPM at a newer upstream keeps everything
dnf-managed rather than scattering a `make install` through `/usr/local`:

    sudo dnf builddep ~/rpmbuild/SPECS/llama-cpp.spec
    dnf download --source llama-cpp
    rpmdev-setuptree && rpm -i llama-cpp-*.src.rpm
    # edit the spec, see below
    spectool -g -R ~/rpmbuild/SPECS/llama-cpp.spec
    rpmbuild -ba ~/rpmbuild/SPECS/llama-cpp.spec
    sudo dnf install ~/rpmbuild/RPMS/x86_64/llama-cpp-*.rpm

Four spec changes, each for a reason that bites otherwise:

- **`Epoch: 1`.** Upstream moved from `bNNNN` build tags to semver. RPM compares
  alphanumerically, so `b6153` sorts *above* `0.4.1`: without an epoch Fedora's
  package looks newer and dnf silently downgrades back to the build that cannot
  load the model.
- **`Source0: .../archive/v%{version}.tar.gz`** — tags are v-prefixed now.
- **`-DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON`** — the precompiled header is built
  for the host target and then reused in the `amdgcn` device pass, which fails
  with *"AST file was compiled for the target x86_64-redhat-linux-gnu but the
  current translation unit is being compiled for target amdgcn-amd-amdhsa"*.
  llama.cpp has no project-level switch for this; CMake's global one works.
- **`-DAMDGPU_TARGETS=gfx1201`** — Fedora builds every supported GPU, which is
  most of the compile time and package size. Narrowing gives a much shorter
  build that only runs on this card.

Also bump `%global pypi_version` to match `gguf-py/pyproject.toml` in the new
tree, or the gguf subpackage is built with a wrong version.

## Server flags that are not optional

- **`--jinja`** makes the server use the chat template embedded in the GGUF.
  Without it the model never emits tool calls a harness can parse, which is the
  whole difference between an agent and a chatbot. Qwen3.8's template is ~10k
  characters and covers `tools`, `tool_call` and `thinking`.
- **`-fa on`** is required whenever the KV cache is quantised. `-ctk q8_0
  -ctv q8_0` without it fails at startup with *"V cache quantization requires
  flash_attn"*. Flash attention works on gfx1201. Note the value: up to b6153
  `-fa` was a bare switch, in 0.4.1 it takes `on|off|auto`, so a bare `-fa`
  now eats the following argument and dies with *"unknown value for
  --flash-attn"*. `llama-cli` changed too -- it enters conversation mode by
  default when the model has a chat template, so a scripted `-p ... -n 1`
  hangs on stdin unless `-no-cnv` is passed.
- **`--parallel N` divides the context between slots.** `-c 16384 --parallel 2`
  gives each client 8192, not 16384. One editor wants `--parallel 1`.

## Memory is the real constraint

The card has 15.9 GB free once the desktop is off (`headless-ai`). Weights and
KV cache share it, and agentic coding is context-hungry -- whole files plus
history on every request.

Measured, not calculated -- the KV cost per token follows the model's layer and
head geometry, so the only honest test is loading it. All on the 9070 XT with
ROCm, every layer on the GPU, `-ctk q8_0 -ctv q8_0 --parallel 1`, largest
context that actually loads:

    quant       size       max ctx   vram used   pp512      tg128
    Q3_K_XL     12.23 GiB    98304   15.63 GB    1260 t/s   28.7 t/s
    IQ4_XS      13.26 GiB    65536   15.44 GB    1321 t/s   30.0 t/s
    Q4_K_S      14.29 GiB    49152   15.78 GB    1320 t/s   29.9 t/s

Two things worth reading off that table. **A smaller quant is not faster** --
generation sits at 29-30 t/s regardless, and Q3_K_XL is the slowest of the
three, so dropping quality buys only context. And **quantised KV is cheap**:
even the largest quant reaches 48k, so none of these are context-starved.
IQ4_XS is the pick: 64k context, the fastest of the three, and 4.25 bpw is
close to Q4_K_S on quality.

For comparison, DeepSeek-Coder-V2-Lite Q5_K_M on the same card:

    pp512   1292 t/s        tg128   105 t/s

3.5x the generation rate, because it is a 16B MoE with a small active set
against a dense 27B. Qwen3.8 is the stronger model, DeepSeek the snappier one.

## Reasoning models emit nothing to a naive client

Qwen3.6 thinks before answering. The thinking goes to `reasoning_content` and
`content` stays **empty** until it finishes, so a small task burns hundreds of
tokens first and any client reading only `content` shows an empty reply. Asked
for a bash one-liner with `max_tokens: 600` it never reached an answer at all --
`finish_reason: length`, content empty, 600 tokens of deliberation.

The chat template honours `enable_thinking`, so the toggle passes
`--chat-template-kwargs '{"enable_thinking":false}'` unless `llm.think=1`. The
same request then answers in 32 tokens. Turn thinking on for hard questions,
leave it off for a daily driver.

## What the models actually measured

All on the 9070 XT, ROCm, every layer on GPU, `-ctk q8_0 -ctv q8_0 --parallel 1`.
Max context is the largest `-c` that loads; tools is whether the model emits an
OpenAI-format tool call, which is pass/fail for agent use.

    model                      size    pp512   tg128   max ctx   tools
    Qwen3.6-35B-A3B Q3_K_S    14.3G     3186    82.8     98304   yes
    Qwen3.6-35B-A3B IQ3_S     12.7G     2453    86.2    131072   yes
    Qwen3.8-27B     IQ4_XS    13.3G     1321    30.0     65536   yes
    Qwen3.8-27B     Q3_K_XL   12.2G     1260    28.7     98304   yes
    Qwen3.6-27B     IQ4_XS    14.4G     1323    31.5     32768   yes
    DeepSeek-Lite   Q5_K_M    11.0G     1292   105.0     32768   NO

The MoE wins by a wide margin -- 35B total but 3B active, so it generates 2.7x
faster than any dense model here while holding more context. Q3_K_S is chosen
over IQ3_S despite less context: generation differs by 4%, but prompt
processing is 30% faster (3186 vs 2453), and prompt processing is what a
context-heavy request waits on. I-quants pack more quality per bit and cost
more to dequantise; here the K-quant wins both speed axes.

DeepSeek-Coder-V2-Lite is excluded despite being the fastest: it answers tool
requests in prose instead of calling the tool. It managed one correctly on an
earlier prompt, so it is unreliable rather than incapable -- which for an agent
backend is the same thing.

## Ordering inside a preset

`headless-ai` switches the desktop off *and* the LLM on. Those cannot run at
once: the model wants the memory the desktop is still holding. The toggle is
marked `defer_on=1`, which makes the daemon start it after everything else has
finished -- the mirror of `defer_off=1` on the desktop toggle, which makes that
one stop last.

## Network

The server binds to the hotspot address only, and the firewall opens the port
in the hotspot zone alone, so nothing is exposed on any other network:

    sudo firewall-cmd --zone=nm-shared --add-port=8080/tcp        # add --permanent to keep

An API key is worth setting, since the hotspot carries other devices. Generate
one yourself and point the config at it:

    umask 077; openssl rand -hex 32 > ~/.config/vibecontrol/llm.key

## Config keys

All in `~/.config/vibecontrol/config`, read at toggle time, nothing hardcoded:

    llm.model   = ~/models/Qwen3.8-27B-UD-Q3_K_XL.gguf
    llm.host    = <hotspot-ip>
    llm.port    = 8080
    llm.ctx     = 16384
    llm.keyfile = ~/.config/vibecontrol/llm.key

## Client

Anything that speaks the OpenAI API and allows a custom base URL:

    base URL   http://<hotspot-ip>:8080/v1
    api key    whatever llm.keyfile contains
    model      any name; the server serves the one model it loaded

Verify the path before configuring an editor:

    curl http://<hotspot-ip>:8080/v1/models

Cursor specifically is the unproven part: it may route requests through its own
servers, which cannot reach a private hotspot address, and its tab-completion
and agent features may not use a custom endpoint at all. Test with `curl` from
the client machine first.

## Not built yet: routing subagents to the local model

The goal is a cloud director that spawns subagents normally, some of which run
on this machine without the director knowing. It is possible, and the protocol
side is already proven: `llama-server` implements the Anthropic Messages API at
`/v1/messages`, including tool calling --

    "content": [{"type":"tool_use","name":"Read","input":{"file_path":"..."}}]
    "stop_reason": "tool_use"

and `claude -p` against this server returns normally, so Claude Code needs no
translation shim. Private addresses are fine because Claude Code connects from
the local process; Cursor's own model integration does not, and refuses with
*"Access to private networks is forbidden"* because it proxies through its
servers. That is a Cursor policy, not a configuration problem, and it is why
the editor choice does not matter here -- the harness is what connects.

What is missing is a router, because `ANTHROPIC_BASE_URL` is process-wide:
every subagent reaches the same endpoint as the director. A ~100 line proxy on
the client machine would dispatch on the `model` field, sending one name to
`<hotspot-ip>:8080` and everything else to `api.anthropic.com`, holding the real
key so the harness never sees it. Subagent frontmatter only accepts
sonnet/opus/haiku/inherit, so the pragmatic routing key is `haiku` -- which
also captures Claude Code's background traffic (summarisation, auto-compact),
worth money but risky: a weak auto-compact summary becomes an invisible wrong
premise for the director, so background should be routable separately. There
may be a cleaner key: an unknown-model warning from Claude Code mentioned
`modelPicker` rows with `behavesAs`, and `modelOverrides`, which suggests a
model id can be taught properly. Not investigated.

The real unknown is not plumbing but whether a 35B at Q3 sustains a multi-turn
tool loop under a large system prompt. Format is proven; competence is not.

Note one hard limit when planning this: a single GPU is a single worker.
`--parallel N` divides the context rather than adding throughput -- measured,
`-c 16384 --parallel 2` gives each slot 8192 -- so concurrency costs context
and the ~83 t/s generation is shared. For research-shaped work the number that
matters is prompt processing at 3186 t/s: roughly 30 seconds to ingest 100k
tokens, which is the actual saving against a cloud director re-reading the same
material every turn.

## The built-in web UI

`llama-server` serves a chat UI at the root path, enabled by default
(`--no-webui` disables it). It is gzip-only, so a bare `curl` gets
`415 Unsupported Media Type` and *"Error: gzip is not supported by this
browser"* -- that is the client, not a fault. Browsers are fine.
`--webui-mcp-proxy` lets that UI reach MCP servers.

## Switching the desktop back on

Two things went wrong the first time and neither was what I expected.

**Autologin is fine.** It fires for the first session of a freshly started login
manager, exactly as assumed -- `pam_unix(plasmalogin-autologin:session): session
opened for user` is in the journal. No `Relogin` drop-in is needed.

**Ordering was the real fault.** A preset that sets `desktop=on` and `llm=off`
starts both at once, so Plasma tried to come up against a card still holding
14 GB and the Wayland session opened and closed in the same second -- kwin could
not get the GPU. The desktop toggle is now `defer_on=1` as well as
`defer_off=1`: last to take memory, last to give the others their environment
back.

**A stale session can hold the seat.** Stopping the login manager while a
greeter session is mid-spawn leaves a logind session whose leader is gone but
which still owns `seat0`, kept alive by an orphaned `startplasma-login-wayland`.
Nothing can claim the seat afterwards; the login manager fails, systemd retries,
and the restart limiter latches with *"Start request repeated too quickly"*,
which reads like a broken login manager rather than an occupied seat.

Clearing one needs root, so `t_on` refuses up front and names the fix instead of
letting systemd thrash:

    sudo loginctl terminate-session <id>
    sudo systemctl stop user@<greeter-uid>.service
    sudo kill <orphaned startplasma pid>
    sudo systemctl reset-failed plasmalogin.service

The `reset-failed` matters: without it the limiter stays latched even once the
seat is free.
