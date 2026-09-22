#!/usr/bin/env python3
"""Tell the daemon to re-apply a preset when the machine wakes up.

Subscribes to logind's PrepareForSleep signal, which carries True as the
machine goes down and False once it is back. Only the False edge matters.

Subscription is used rather than `busctl monitor`, which needs privileges to
become a bus monitor; watching one signal does not.

Usage: resume-watch.py <fifo> <command-to-send>
"""
import os
import sys

import gi
from gi.repository import Gio, GLib


# Seconds after resume at which to send. Idempotent, so over-sending is safe.
RETRY_SCHEDULE = (0, 5, 15, 30)


def send(fifo, line):
    """Non-blocking write: if the daemon is gone, drop it rather than hang."""
    try:
        fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    except OSError:
        return
    try:
        os.write(fd, (line + "\n").encode())
    except OSError:
        pass
    finally:
        os.close(fd)


def main():
    if len(sys.argv) < 3:
        print("usage: resume-watch.py <fifo> <command>", file=sys.stderr)
        return 2
    fifo, command = sys.argv[1], " ".join(sys.argv[2:])

    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

    def on_signal(_conn, _sender, _path, _iface, _signal, params):
        going_to_sleep = params.unpack()[0]
        if not going_to_sleep:              # False == resuming
            print("resumed, sending: %s" % command, flush=True)
            # Hardware is not ready the instant logind says we are back:
            # NetworkManager still has the wifi at unavailable while the
            # supplicant starts, so a hotspot activated now simply fails.
            # Presets only act on what differs, so sending the same command
            # several times is free -- once it succeeds the rest are no-ops.
            for delay in RETRY_SCHEDULE:
                if delay == 0:
                    send(fifo, command)
                else:
                    GLib.timeout_add_seconds(
                        delay, lambda: (send(fifo, command), False)[1])

    bus.signal_subscribe(
        "org.freedesktop.login1", "org.freedesktop.login1.Manager",
        "PrepareForSleep", "/org/freedesktop/login1", None,
        Gio.DBusSignalFlags.NONE, on_signal)

    print("watching for resume", flush=True)
    GLib.MainLoop().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
