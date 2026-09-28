#!/usr/bin/env bash
# Disables high-resolution scrolling for one mouse.
#
# Run once as root:  sudo install/mouse-scroll-quirk.sh
#
# The G502's wheel reports both REL_WHEEL (one event per detent) and
# REL_WHEEL_HI_RES (120 units per detent). A Wayland desktop uses the hi-res
# axis for smooth scrolling, which is what you want -- but a Wine game gets its
# input through XWayland, which has to fold those deltas back into X11 button 4
# and 5 presses. Accumulated hi-res deltas crossing a detent boundary can be
# emitted with the wrong sign there, which is felt as a scroll that occasionally
# jumps the other way, and as oversensitivity because one physical click can
# produce several button events.
#
# macOS never has this problem because it consumes the hi-res axis directly and
# never converts to discrete clicks at all.
#
# The trade-off is real and system-wide: desktop scrolling becomes detent-based
# rather than smooth. Most people prefer that with a ratcheted wheel; it is not
# WoW-only, and there is no way to scope a libinput quirk to one application.
set -euo pipefail

VENDOR="${VENDOR:-0x046D}"
PRODUCT="${PRODUCT:-0x407F}"       # the mouse itself; 0xC539 is the receiver
NAME="${NAME:-Logitech G502}"
F=/etc/libinput/local-overrides.quirks

[[ $(id -u) == 0 ]] || { echo "run with sudo" >&2; exit 2; }

install -d -m 0755 /etc/libinput
if [[ -f $F ]] && grep -q "vibecontrol: $NAME" "$F"; then
    echo "already present in $F"; exit 0
fi

# Appended rather than written: this file is shared with any other local quirk.
cat >>"$F" <<QUIRK

# vibecontrol: $NAME -- no high-resolution scrolling
# XWayland mis-signs folded hi-res deltas, which Wine games feel as scrolling
# that occasionally goes the wrong way. Classic detents convert cleanly.
[vibecontrol $NAME no hi-res scroll]
MatchVendor=$VENDOR
MatchProduct=$PRODUCT
AttrEventCodeDisable=REL_WHEEL_HI_RES;REL_HWHEEL_HI_RES;
QUIRK

echo "appended to $F"
echo
echo "takes effect when the device is re-added:"
echo "  udevadm trigger --subsystem-match=input --action=add"
echo "or simply unplug and replug the mouse. Verify with:"
echo "  libinput list-devices | grep -A8 '$NAME'"
echo
echo "to undo, delete the [vibecontrol ...] block from $F"
