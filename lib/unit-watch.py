#!/usr/bin/env python3
"""Block until a systemd unit reaches a state, driven by signals.

Toggles that tear something down need to know when it is really gone. Polling
`systemctl is-active` in a sleep loop answers that, but it burns a wakeup a
second for something systemd will happily announce, and it rounds the answer up
to the next whole second. This subscribes to the manager instead and returns
the moment the state actually changes.

The unit is resolved once; if it is not loaded at all that already counts as
inactive, and a unit that disappears while we watch counts the same way.

Usage: unit-watch.py [--system] [--timeout N] <unit> <active|inactive>
Exit:  0 the unit reached the state, 1 timed out, 2 bad usage.
"""
import sys

import gi
from gi.repository import Gio, GLib

MANAGER = "org.freedesktop.systemd1"
MANAGER_PATH = "/org/freedesktop/systemd1"
MANAGER_IFACE = "org.freedesktop.systemd1.Manager"
UNIT_IFACE = "org.freedesktop.systemd1.Unit"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    timeout = 0
    for f in flags:
        if f.startswith("--timeout"):
            timeout = int(f.split("=", 1)[1]) if "=" in f else 0
    if "--timeout" in sys.argv:                 # space-separated form
        i = sys.argv.index("--timeout")
        timeout = int(sys.argv[i + 1])
        args = [a for a in args if a != sys.argv[i + 1]]
    if len(args) != 2 or args[1] not in ("active", "inactive"):
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    unit, want = args
    bus_type = Gio.BusType.SYSTEM if "--system" in flags else Gio.BusType.SESSION
    bus = Gio.bus_get_sync(bus_type, None)
    loop = GLib.MainLoop()
    result = {"rc": 1}

    def is_active():
        """None when the unit is not loaded, which counts as inactive."""
        try:
            path = bus.call_sync(
                MANAGER, MANAGER_PATH, MANAGER_IFACE, "GetUnit",
                GLib.Variant("(s)", (unit,)), GLib.VariantType("(o)"),
                Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
        except GLib.Error:
            return False
        try:
            state = bus.call_sync(
                MANAGER, path, "org.freedesktop.DBus.Properties", "Get",
                GLib.Variant("(ss)", (UNIT_IFACE, "ActiveState")),
                GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, -1,
                None).unpack()[0]
        except GLib.Error:
            return False
        return state in ("active", "activating", "reloading")

    def settled(*_):
        if (want == "active") == is_active():
            result["rc"] = 0
            loop.quit()

    # Without Subscribe() the manager only emits signals to clients that asked
    # for them, so the PropertiesChanged below would never arrive.
    try:
        bus.call_sync(MANAGER, MANAGER_PATH, MANAGER_IFACE, "Subscribe",
                      None, None, Gio.DBusCallFlags.NONE, -1, None)
    except GLib.Error:
        pass

    bus.signal_subscribe(
        MANAGER, "org.freedesktop.DBus.Properties", "PropertiesChanged",
        None, UNIT_IFACE, Gio.DBusSignalFlags.NONE, settled)
    for sig in ("UnitRemoved", "UnitNew", "JobRemoved"):
        bus.signal_subscribe(MANAGER, MANAGER_IFACE, sig, MANAGER_PATH, None,
                             Gio.DBusSignalFlags.NONE, settled)

    # Checked after subscribing, not before: the state can change in between,
    # and this way that change is either seen here or delivered as a signal.
    settled()
    if result["rc"] == 0:
        return 0
    if timeout:
        GLib.timeout_add_seconds(timeout, lambda: (loop.quit(), False)[1])
    loop.run()
    return result["rc"]


if __name__ == "__main__":
    sys.exit(main())
