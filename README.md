# vibecontrol

Switch a Linux workstation between machine modes -- desktop, headless server,
remote play, local LLM -- from one terminal panel, without remembering which
`systemctl`, `nmcli` and `kscreen-doctor` incantation each one needs.

Features are one file each in `toggles/`; adding one needs no change to the
daemon or the client.

    bin/vibecontrold            daemon; owns all feature state, serialises
                                tasks, writes the JSON clients render
    bin/vibecontrol             client (python); renders and sends commands,
                                runs no feature work itself
    lib/state2json.py           flat key=value -> the JSON document
    lib/screensaver-inhibit.py  holds a freedesktop ScreenSaver inhibit
    toggles/*.toggle          one file per toggle
    toggles/*.md               per-toggle host prerequisites

## API

Client to daemon, one line per command on `$XDG_RUNTIME_DIR/vibecontrol/cmd`:

    hello <pid>            register; daemon answers with a full state write
    bye   <pid>            unregister
    set   <feature> on|off|toggle
    cfg   <key> 0|1        change a behaviour setting
    preset <name>          apply a preset
    reload                 re-scan toggle definitions and re-read statuses
    refresh                re-read statuses only

The daemon pushes a new document whenever anything changes, so a client has
no reason to poll or to offer a manual refresh. `reload` exists for a client
that has just written a toggle file and wants it picked up without a restart.

Daemon to clients: `state.json`, replaced atomically, plus a wake byte on
`clients/<pid>.fifo`. The document carries the feature descriptors, the lock
topology and the config, so a client learns at init which entries block each
other instead of hardcoding it. The daemon enforces the same lock itself, so a
stale client cannot cause concurrent work.

## Adding a feature

Drop a file in `toggles/`. Neither daemon nor client needs editing.

    label="Hotspot"
    group="hotspot"      # features sharing a group never run at once
    category="common"    # common | wm
    defer_off=1          # optional: this feature hosts the others (see below)
    defer_on=1           # optional: this feature consumes what others release
    timeout=45           # optional: seconds before the daemon stops waiting (30)
    on_timeout=force     # optional: force | rollback                (rollback)
    parent="..."         # optional: nest under a composite feature
    key="h"              # optional fixed shortcut; usually omitted

    t_status() { ...; echo on|off; }
    t_on()     { ...; }
    t_off()    { ...; }
    t_force()  { ...; }   # optional: the harder way, run after a timeout

A feature may call `vc_progress "what it is doing now"` at any point. The text
reaches clients while the task is still running, which is what makes a long
teardown legible rather than a yellow cell and no explanation.

Every task has a deadline. Past it the daemon kills the task and whatever it
spawned -- tasks are process group leaders for exactly this reason -- and then
either runs `t_force` (`on_timeout=force`) or puts things back the way they
were (`on_timeout=rollback`, the default). If the escalation overruns as well,
the daemon gives up, re-reads the real status and says so. A client shows the
elapsed time once a task passes two seconds, and what is about to happen once
it nears its timeout.

Waiting for something to happen is done with `lib/unit-watch.py`, which
subscribes to the systemd manager and returns the moment a unit changes state.
Sleep loops are not used: they burn a wakeup a second for something systemd
will announce, and they round the answer up to the next whole second.

Display order comes from the filename prefix, and clients number rows
themselves, so a new feature never renumbers the others. Each call re-sources
the file in a subshell, so private variables cannot collide between features.

Features are grouped in the menu by `section`, a heading they declare
themselves, shown in the order the sections first appear -- which is filename
order, so rearranging the menu is a rename rather than a code change. A section
whose features are all unavailable says so once, in its heading, instead of on
every row.

`category` is a separate thing and is about capability, not layout. `common`
features work on a bare server with no desktop at all; `wm` features need a
graphical session,
are reported unavailable without one, and commands against them are refused.
Detection uses `graphical-session.target`, the generic systemd signal every
desktop sets, so nothing here is tied to KDE or any other desktop. Set
`VIBECONTROL_ASSUME_HEADLESS=1` to exercise the headless path.

Detection is re-run on every status refresh, not once at startup, so a desktop
that goes away mid-run is noticed without restarting the daemon.

`defer_off=1` marks a feature that *is* the environment the `wm` features run
in -- currently only `50-desktop.toggle`. In a preset it is switched off last,
after everything else has finished quitting, and switching it on triggers a
second pass over the preset once the session exists. Such a feature must be
`category="common"`: a `wm` one would report itself unavailable the moment it
succeeded, leaving no way to bring the desktop back from an SSH session.

A feature nested under another with `parent=` is switched off when its parent
is, because it exists to serve it -- a search backend running for a model that
has gone is not a useful state. A `restart` deliberately does not cascade: the
parent is coming straight back.

`defer_on=1` is the mirror, for a feature that consumes what the others give
back -- currently `70-llm.toggle`. `headless-ai` switches the desktop off and
the LLM on, and the model wants the memory the desktop is still holding, so it
has to start after that has happened rather than beside it.

## Model profiles

`70-llm.toggle` reads every setting through the active profile first and the
plain `llm.*` key second, so shared things are written once:

    llm.host=<hotspot-ip>                 # shared by all profiles
    llm.profile=gemma                  # the active one

    llm.profile.gemma.model=/path/to.gguf
    llm.profile.gemma.ctx=65536
    llm.profile.gemma.alias=gemma-4-26b

Adding a profile is a config edit; nothing in the code knows what a model is.
The daemon publishes the list, `m` in the client opens a picker, and choosing
one writes `llm.profile` and restarts the feature -- deliberately on Enter
rather than on cursor movement, because each switch reloads weights and takes
the better part of a minute.

`restart` joined `on`/`off`/`force-*` as a target for this: it is the right verb
when a feature's configuration changed rather than its desired state.

## Presets

A preset names toggles and the state they should be in. It lives in the same
flat config, so there is no second file format:

    preset.remote-play.steam       = on
    preset.remote-play.screenlock  = off
    preset.remote-play.awake       = on
    preset.remote-play.wow         = on

    preset.desktop.screenlock      = on
    preset.desktop.awake           = off
    preset.desktop.wow             = off

A toggle the preset does not mention is left alone -- that is the third state,
and it is the default, so presets stay short. Applying one compares each named
toggle against its current state and **only acts on what differs**, so nothing
already in the wanted state is restarted. Group locks still apply; a toggle
whose group is busy is skipped rather than queued.

Clients render presets as a matrix beside the menu: one column per preset,
each cell on the same line as the toggle it refers to. Reading across a row
shows what every preset would do to that toggle; reading down a column shows
the whole preset. A cell is dim when the toggle already matches, highlighted
when applying would change it, and a dash when the preset does not mention it.
Applying asks for confirmation first, naming what would change.

Column order follows the order the keys appear in the config file.

Leave a toggle out unless the preset really needs to change it. `desktop`
deliberately says nothing about Steam: the `-pipewire` flag costs nothing when
no stream is running (Steam drops the capture session and only restarts it for
a stream), so turning the toggle off would buy nothing and would quit Steam --
closing whatever game was running.

    preset <name>          apply it
    reload                 re-scan the toggle directory

`preset.<name>.hidden=1` keeps a preset out of a client's matrix without
disabling it. That is for the ones the daemon applies itself -- `on_boot` and
`on_resume` -- which work whether or not anyone can press a key for them. The
config screen lists what runs automatically instead. The applier ignores the
line, because it only matches entries whose value is `on` or `off`.

## Presets and the display

A toggle may change the display mode as well as its own state -- `wow` does,
because black bars in a stream are an aspect mismatch and the fix is to give
the host the client's aspect. `kscreen-doctor` can add custom modes, including
ones larger than the physical panel: the GPU accepts them and downscales
locally, so the local view softens while the stream stays exact.

Note `kscreen-doctor` cannot parse `WxH@refresh` when the refresh has a
decimal, so modes are addressed by index and looked up each time, since
indices are not stable.

## Boot and resume

Two settings name a preset to apply, or are empty to do nothing:

    on_boot=startup
    on_resume=startup

`on_boot` runs when the daemon starts, so a reboot or login brings the named
preset's toggles up. `on_resume` runs when the machine wakes: a small watcher
subscribes to logind's `PrepareForSleep` and writes `preset <name>` into the
same fifo the daemon already reads, so waking needs no second service. It is
started as a daemon child and stopped with it.

Re-applying is safe by construction -- a preset only acts on toggles whose
state differs -- so the same preset can serve both.

## Host prerequisites

Some features need things installed on the machine itself. A feature with
setup requirements documents them in a `.md` file beside it, so a new machine
can be prepared before anything is toggled.

- **`13-sshd.toggle`** needs a polkit rule at
  `/etc/polkit-1/rules.d/49-vibecontrol-sshd.rules` allowing this user to
  start and stop `sshd.service` without authentication. Without it the feature
  falls back to prompting, which needs a polkit agent and therefore a desktop,
  contradicting `category="common"`. Scope the rule to that one unit and to
  the start/stop/restart verbs only, so whether sshd comes up at boot still
  requires admin authentication.
- **`50-desktop.toggle`** needs `install/desktop-privileges.sh`, run once as
  root. It installs the equivalent polkit rule for the login manager and
  enables linger for the user. Linger is not optional: without it the user
  manager -- and the daemon with it -- is killed the moment the graphical
  session this feature switches off goes away. The rule covers two units, not
  one: when the session ends the login manager puts up a greeter, and logind
  starts a separate user manager for it which is not in the login manager's
  control group. That greeter is a full Wayland compositor and holds most of
  the VRAM this feature exists to reclaim, so it is stopped explicitly.
  Boot behaviour is unchanged;
  autologin still happens as before. Switching the desktop off reuses Plasma's
  own logout flow (`org.kde.Shutdown.logout`, what the "Log Out" menu entry
  calls) so applications are asked to save and close, and only then is the
  login manager stopped -- a logout alone would leave the greeter running, and
  the greeter is a compositor holding VRAM too.
- **`40-steam.toggle`** — see [`toggles/40-steam.md`](toggles/40-steam.md).
  Remote Play needs rather more than the flag this feature toggles.

## Install

    mkdir -p ~/.local/bin ~/.config/vibecontrol ~/.config/systemd/user \
             ~/.local/share/applications
    ln -s "$PWD/bin/vibecontrol"  ~/.local/bin/vibecontrol
    ln -s "$PWD/bin/vibecontrold" ~/.local/bin/vibecontrold
    ln -s "$PWD/toggles"         ~/.config/vibecontrol/toggles
    ln -s "$PWD/systemd/vibecontrol-daemon.service" ~/.config/systemd/user/
    ln -s "$PWD/desktop/vibecontrol.desktop" ~/.local/share/applications/
    systemctl --user daemon-reload
    systemctl --user enable --now vibecontrol-daemon

Run `vibecontrol` in a terminal, or launch it from the desktop entry.
