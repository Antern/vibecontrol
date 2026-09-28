#!/usr/bin/env bash
# Remap Caps Lock to Left Ctrl at the kernel level, for one keyboard.
#
# Run once as root:  sudo install/caps-to-ctrl.sh      (--undo to remove)
#
# KDE's caps:ctrl_modifier is an XKB option, which maps keycodes to *symbols*.
# Wine translates X11 keycodes into DirectInput scancodes through a fixed table
# and never consults the symbol map, so a game reading scancodes still sees
# DIK_CAPITAL. That is why the desktop remap works everywhere except games.
#
# hwdb rewrites the scancode in the kernel, before evdev, so everything above it
# -- XKB, Wayland, XWayland, Wine, the text console -- sees Left Ctrl and there
# is nothing left to disagree about.
#
# Scancodes for USB keyboards are HID usages, as libinput's own entries show
# (KEYBOARD_KEY_700e0=leftctrl is usage page 0x07, usage 0xE0). Caps Lock is
# usage 0x39, hence 70039.
set -euo pipefail

VENDOR="${VENDOR:-3434}"      # Keychron
PRODUCT="${PRODUCT:-0E30}"    # K3 HE
F=/etc/udev/hwdb.d/70-vibecontrol-caps-ctrl.hwdb

[[ $(id -u) == 0 ]] || { echo "run with sudo" >&2; exit 2; }

if [[ ${1:-} == --undo ]]; then
    rm -f "$F" && echo "removed $F"
    systemd-hwdb update && udevadm trigger --subsystem-match=input --action=change
    echo "replug the keyboard, or reboot, to be certain"
    exit 0
fi

install -d -m 0755 /etc/udev/hwdb.d
cat >"$F" <<RULE
# Installed by vibecontrol (install/caps-to-ctrl.sh).
# Caps Lock -> Left Ctrl in the kernel, so games that read scancodes see it too.
evdev:input:b0003v${VENDOR}p${PRODUCT}*
 KEYBOARD_KEY_70039=leftctrl
RULE
chmod 0644 "$F"
systemd-hwdb update
udevadm trigger --subsystem-match=input --action=change

echo "installed $F"
echo
echo "verify the property actually attached (no guessing):"
echo "  udevadm info /dev/input/event27 | grep KEYBOARD_KEY"
echo
echo "if it attached but Caps still types Caps, the scancode is wrong for this"
echo "keyboard -- find the real one with:"
echo "  sudo evtest /dev/input/event27   # press Caps, read the MSC_SCAN value"
echo
echo "once this works, drop Options=caps:ctrl_modifier from ~/.config/kxkbrc:"
echo "it is then remapping a key the kernel no longer reports."
