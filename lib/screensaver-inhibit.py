#!/usr/bin/env python3
"""Hold a screensaver/lock inhibit for as long as this process lives.

Uses org.freedesktop.ScreenSaver, the interface every major desktop exposes
(kwin serves it here, mutter elsewhere), so nothing about this is KDE
specific. The inhibit is bound to the D-Bus connection, which is why it needs
a process to sit on it rather than a one-shot call -- a `busctl call` would
release it the moment the command exited.

Prints the cookie so the journal shows the inhibit was actually granted.
"""
import signal
import sys

import gi
from gi.repository import Gio, GLib

try:                                  # GLib.unix_signal_add is deprecated
    from gi.repository import GLibUnix
    add_signal_handler = GLibUnix.signal_add
except ImportError:                   # older gobject-introspection
    add_signal_handler = GLib.unix_signal_add

BUS_NAME = "org.freedesktop.ScreenSaver"
OBJ_PATH = "/org/freedesktop/ScreenSaver"


def main():
    try:
        proxy = Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, None,
            BUS_NAME, OBJ_PATH, BUS_NAME, None)
        cookie = proxy.call_sync(
            "Inhibit",
            GLib.Variant("(ss)", ("vibecontrol", "lock suppressed by request")),
            Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
    except GLib.Error as exc:
        print("inhibit failed: %s" % exc.message, file=sys.stderr)
        return 1

    print("screensaver inhibit held, cookie=%s" % cookie, flush=True)
    loop = GLib.MainLoop()

    def release(*_):
        try:
            proxy.call_sync("UnInhibit", GLib.Variant("(u)", (cookie,)),
                            Gio.DBusCallFlags.NONE, -1, None)
        except GLib.Error:
            pass
        loop.quit()
        return GLib.SOURCE_REMOVE

    add_signal_handler(GLib.PRIORITY_DEFAULT, signal.SIGTERM, release)
    add_signal_handler(GLib.PRIORITY_DEFAULT, signal.SIGINT, release)
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
