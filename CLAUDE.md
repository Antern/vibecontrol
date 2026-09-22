# Working on vibecontrol

Read this before changing anything. Most of it is failure modes that already
cost real debugging time in this repo.

## Shape of the thing

Two processes. `bin/vibecontrold` (bash) owns every piece of state and is the
only thing that runs feature work. `bin/vibecontrol` (python) renders and sends
commands, and must never call `nmcli`, `wpctl`, `systemctl` or `pkexec` itself.
Other clients are expected -- a web front end over the same fifo is a valid
client -- so anything a client needs has to arrive in the state document rather
than being inferred or hardcoded.

    bin/vibecontrold              daemon
    bin/vibecontrol               terminal client
    lib/state2json.py             flat key=value -> the JSON clients read
    features/NN-<id>.toggle      one file per toggle
    systemd/…service  desktop/…desktop

Runtime lives in `$XDG_RUNTIME_DIR/vibecontrol/`: `cmd` (fifo, clients ->
daemon), `state.json` (daemon -> clients, replaced atomically), `clients/<pid>.fifo`
(wake byte), `tasks/` (task results). Config is `~/.config/vibecontrol/config`.

## Adding a feature

Drop a file in `toggles/`. Nothing else needs editing.

    category="common"        # common | wm
    label="Wake on LAN"
    group="wol"              # features sharing a group never run at once

    t_status() { ...; echo on|off; }
    t_on()     { ...; }      # 0 on success
    t_off()    { ...; }

The filename prefix sets display order (`11-hotspot`, `20-airpods`). The id is
the filename with the prefix stripped. Do **not** add a `key=`: clients number
rows by position, so declaring keys reintroduces the clash-and-renumber problem
that was deliberately removed.

`category="common"` means it works on a machine with no desktop. Be honest
here: if the code path needs a polkit agent, a display, or a session audio
server, it is `wm`. The daemon refuses commands against `wm` features when
`graphical-session.target` is inactive, and does not even probe their status.

A toggle may report the *thing it controls* rather than its own machinery --
`screenlock` is on when the screen locks normally and off when an inhibit
suppresses it, which is the inverse of its transient unit being active. That
reads better in the menu; just keep `t_status` describing the thing, not the
unit.

Nothing is turned off when the daemon stops. A toggle's effect is owned by a
NetworkManager connection, a systemd unit or a D-Bus inhibit that outlives the
daemon, and clients attach and detach freely, so state must not depend on who
happens to be watching.

`parent="<id>"` nests a feature under a composite. Supported but currently
unused; the composite that existed was removed because the common/wm split
already groups things.

## The API

Client to daemon, one line per command on `cmd`:

    hello <pid> / bye <pid> / set <feature> on|off|toggle / cfg <key> 0|1 / refresh

Daemon to clients: `state.json` plus a wake byte. It carries the feature
descriptors, `groups` (the lock topology), `config`, and `session.graphical`.
A client derives "this row is locked" purely from `groups[g].busy` and each
feature's `group`. Keep it that way; the daemon enforces the lock too, so a
stale client cannot cause concurrent work.

## Traps in this codebase

**`local` assigns after declaring.** `local id="$1" g="${A[$id]}"` does not see
`id`. Under `set -u` it errors; worse, if a global `id` happens to exist it
silently uses *that* value. This produced a lock applied to the wrong group.
Always split the statement.

**A bash trap does not interrupt a blocking `read`.** A `trap ... USR1` handler
runs, but `read` keeps blocking until its own timeout, so signalling a blocked
bash process is useless. This is why a finished task wakes the daemon by
writing `done <id>` into the fifo it is already reading. `SIGTERM` is the
exception and does interrupt, which is why the shutdown trap works.

**`${#A[@]}` on a declared-but-never-assigned associative array trips `set -u`**
(bash 5.3), while `${!A[@]}` does not. Always `declare -A A=()`.

**Background subshells do not inherit the `EXIT` trap.** Verified; task
subshells will not run `shutdown`.

**`pkexec` forks and execs**, so `$!` is not the helper's pid, and after the
exec the process is root-owned and `kill -0` fails with EPERM even while alive.
Track such work through a systemd transient unit instead, as the sm2 feature
does: systemd owns the pid, it survives the terminal closing, and a later
client can still see and stop it.

**`pkexec` needs a polkit agent**, which is a desktop component. Anything
`common` must not use it. `sshd` is toggled with plain `systemctl` because
`/etc/polkit-1/rules.d/49-vibecontrol-sshd.rules` authorises this user for that
one unit and the start/stop/restart verbs only.

**Feature functions are re-sourced per call in a subshell.** That isolation is
load-bearing: two features both define `_unit`, and without it the second would
clobber the first.

**Python: never mix `select()` with `sys.stdin.read()`.** It buffers ahead, so
a keypress already in Python's buffer leaves `select()` reporting nothing. Use
`os.read(fd, 1)`.

## Testing

Drive the client through a pty; it needs a terminal. Frames are separated by
`\x1b[H\x1b[2J`, and the newest frame is the tail after the last separator --
splitting on it and taking `[-1]` of the completed frames silently shows you
the *previous* screen.

    VIBECONTROL_ASSUME_HEADLESS=1 vibecontrold    # exercise the no-desktop path

Real tasks finish in well under a second, so timing two commands close together
does **not** test the group lock and will look like the lock is broken. Add a
temporary feature whose `t_on` sleeps, in the group under test, and remove it
afterwards.

Do not use `pgrep -f`/`pkill -f` with a pattern that also appears in your own
command line; it matches the agent's wrapper shell and kills the session. Match
on exact names, or read the daemon pid from `state.json`.

Check real state against the subsystems (`nmcli`, `systemctl`), not only against
what the daemon reports -- a composite once reported `off` while its parts were
genuinely on.

## House style

Keep the daemon and feature files small and obvious; they are meant to be
edited by an LLM with little context. Comments explain *why*, especially where
a workaround exists, because every trap above looks like pointless indirection
until it bites again.
