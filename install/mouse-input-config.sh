#!/usr/bin/env bash
# Stamp KDE input settings onto EVERY identity one mouse presents.
#
# The problem is not specific to any model. A wireless mouse with a charging
# cable shows up as two different devices:
#
#   046d:407f "Logitech G502"                          - via its receiver
#   046d:c08d "Logitech G502 LIGHTSPEED Wireless ..."  - cable plugged in
#
# KDE keys per-device input settings to vendor/product/name and has no global
# fallback -- verified in kcminputrc and in the KWin binary -- so an identity
# with no config block silently falls back to libinput defaults: adaptive
# acceleration, and natural scroll off. That is why pointer speed and wheel
# direction change the moment the charger goes in, and why configuring the
# mouse once in System Settings does not stick.
#
# Idempotent, no sudo, no daemon. Run it once per identity, or just run it on
# both and let each pass handle whichever is present.
#
#   ./mouse-input-config.sh                 # the author's mouse
#   ./mouse-input-config.sh '*MX Master*'   # some other one
#   MOUSE_NATURAL_SCROLL=false ./mouse-input-config.sh
#   ./mouse-input-config.sh --dry-run
set -euo pipefail

DRY=0
[[ ${1:-} == --dry-run ]] && { DRY=1; shift; }

# A glob against the evdev device name. Defaulted rather than required so the
# command above works unchanged on the machine this came from.
MATCH="${1:-${MOUSE_MATCH:-*G502*}}"

# PointerAccelerationProfile: 1 = flat (no acceleration), 0 = adaptive.
NATURAL_SCROLL="${MOUSE_NATURAL_SCROLL:-true}"
ACCEL_PROFILE="${MOUSE_ACCEL_PROFILE:-1}"

declare -A WANT=(
    [NaturalScroll]="$NATURAL_SCROLL"
    [PointerAccelerationProfile]="$ACCEL_PROFILE"
)

found=0
for dev in /sys/class/input/event*/device; do
    [[ -r $dev/name ]] || continue
    name=$(<"$dev/name")
    # shellcheck disable=SC2254  # MATCH is deliberately a glob
    case "$name" in $MATCH) ;; *) continue ;; esac

    # Pointers only: bit 0 (REL_X) of the rel capability bitmask. Without this
    # the same mouse's keyboard-ish endpoints match too and get pointer keys.
    rel=$(<"$dev/capabilities/rel") || continue
    (( 0x$rel & 1 )) || continue

    vid=$((0x$(<"$dev/id/vendor"))); pid=$((0x$(<"$dev/id/product")))
    found=1
    sys=$(basename "$(dirname "$dev")")

    if (( DRY )); then
        printf 'would configure  %s/%s  %s  (%s)\n' "$vid" "$pid" "$name" "$sys"
        for key in "${!WANT[@]}"; do printf '    %s = %s\n' "$key" "${WANT[$key]}"; done
        continue
    fi

    for key in "${!WANT[@]}"; do
        kwriteconfig6 --file kcminputrc \
            --group Libinput --group "$vid" --group "$pid" --group "$name" \
            --key "$key" "${WANT[$key]}"
    done

    # kcminputrc is only read when a device is ADDED, and KWin's reconfigure()
    # does not cover per-device input config -- so the file edit sits inert
    # until the next replug or logout unless the live device is poked too.
    # Values come from WANT rather than being hardcoded true, so overriding
    # one of the variables above changes the live push as well as the file.
    live_scroll=$([[ ${WANT[NaturalScroll]} == true ]] && echo true || echo false)
    live_flat=$([[ ${WANT[PointerAccelerationProfile]} == 1 ]] && echo true || echo false)
    for pair in "naturalScroll:$live_scroll" "pointerAccelerationProfileFlat:$live_flat"; do
        gdbus call --session --dest org.kde.KWin \
            --object-path "/org/kde/KWin/InputDevice/$sys" \
            --method org.freedesktop.DBus.Properties.Set \
            org.kde.KWin.InputDevice "${pair%%:*}" "<${pair#*:}>" >/dev/null 2>&1 || true
    done
    printf 'configured  %s/%s  %s  (%s)\n' "$vid" "$pid" "$name" "$sys"
done

(( found )) || { echo "no pointer matching '$MATCH' is present - plug it in and re-run" >&2; exit 1; }
(( DRY )) || echo "applied live; config persists for future replugs"
