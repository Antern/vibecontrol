#!/usr/bin/env bash
#
# vibecontrol remover. The mirror of install.sh, in reverse order.
#
#   ./uninstall.sh                 remove vibecontrol, keep config and models
#   ./uninstall.sh --toggles=a,b   remove just these features, leave the rest
#   ./uninstall.sh --purge         also delete ~/.config/vibecontrol
#   sudo ./uninstall.sh --root     the privileged steps, after the above
#
# What is never touched, on purpose: model files (tens of gigabytes, and not
# ours), and your config unless --purge is given, because presets and profiles
# are real work. Linger is left alone too -- other things may depend on it.
set -uo pipefail

VC_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ ${1:-} == --root ]]; then
    TARGET_USER="${SUDO_USER:-}"
    [[ -n $TARGET_USER ]] || { echo "run this with sudo, not as root directly" >&2; exit 2; }
    HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    export HOME
fi

# shellcheck source=lib/setup-common.sh
source "$VC_ROOT/lib/setup-common.sh"

MODE=uninstall PURGE=0 SELECT="" ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --root)      MODE=root ;;
        --purge)     PURGE=1 ;;
        --toggles=*) SELECT="${arg#--toggles=}" ;;
        -y|--yes)    ASSUME_YES=1 ;;
        -h|--help)   sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           die "unknown argument: $arg" ;;
    esac
done

# The manifest is the record of what was installed, but a hand-made install has
# none. Falling back to "every toggle currently linked" means uninstall still
# works on a machine that predates the installer.
installed_ids() {
    local any=0 id f
    while read -r id; do [[ -n $id ]] && { printf '%s\n' "$id"; any=1; }; done < <(manifest_read)
    (( any )) && return 0
    for f in "$VC_TOGGLE_DIR"/*.toggle; do
        [[ -e $f ]] || continue
        toggle_id "$f"
    done
}

confirm() {   # prompt
    (( ASSUME_YES )) && return 0
    [[ -t 0 ]] || return 1
    printf '  %s [y/N] ' "$1"; read -r r
    [[ $r == y || $r == Y ]]
}

# Transient units the features create. systemd keeps a failed transient unit in
# its state until reset-failed, so removing the files is not enough to leave a
# clean machine.
TRANSIENT=(vibecontrol-stay-awake vibecontrol-steam vibecontrol-sm2-anchor vibecontrol-llm)

remove_toggles() {   # ids...
    local id f
    say "${C_B}features${C_0}"
    for id in "$@"; do
        run_phase "$id" uninstall || warn "$id: uninstall step failed"
        f="$VC_TOGGLE_DIR/$(basename "$(toggle_file "$id" 2>/dev/null)" 2>/dev/null)"
        [[ -e $f || -L $f ]] && unlink_ours "$f"
        manifest_del "$id"
        step "$id: removed"
    done
}

stop_daemon() {
    say "${C_B}daemon${C_0}"
    if systemctl --user is-active vibecontrol-daemon.service >/dev/null 2>&1; then
        systemctl --user disable --now vibecontrol-daemon.service 2>/dev/null \
            && step "stopped and disabled vibecontrol-daemon"
    else
        skip "daemon not running"
    fi
    local u
    for u in "${TRANSIENT[@]}"; do
        systemctl --user stop "$u" >/dev/null 2>&1
        # Clears the unit from systemd's state; without it a failed transient
        # lingers in `systemctl --user list-units --failed` forever.
        systemctl --user reset-failed "$u" >/dev/null 2>&1 && step "cleared $u"
    done
}

remove_core() {
    say "${C_B}core${C_0}"
    unlink_ours "$VC_BIN/vibecontrol"
    unlink_ours "$VC_BIN/vibecontrold"
    unlink_ours "$VC_USER_UNITS/vibecontrol-daemon.service"
    unlink_ours "$VC_DESKTOP/vibecontrol.desktop"
    systemctl --user daemon-reload 2>/dev/null
    local run="${XDG_RUNTIME_DIR:-/tmp}/vibecontrol"
    [[ -d $run ]] && { rm -rf "$run"; step "removed $run"; }
    # An empty toggles dir is ours; a non-empty one has something we did not put
    # there, and removing it would take that with it.
    if rmdir "$VC_TOGGLE_DIR" 2>/dev/null; then step "removed ~/.config/vibecontrol/toggles"
    elif [[ -d $VC_TOGGLE_DIR ]]; then
        warn "left $VC_TOGGLE_DIR: it holds files vibecontrol did not install"
    fi
    # An emptied manifest is litter; a non-empty one means something was left.
    [[ -f $VC_MANIFEST && ! -s $VC_MANIFEST ]] && { rm -f "$VC_MANIFEST"; step "removed manifest"; }
}

purge_config() {
    say "${C_B}config${C_0}"
    if confirm "delete $VC_CFG_DIR (presets, model profiles, keys)?"; then
        rm -rf "$VC_CFG_DIR"; step "removed $VC_CFG_DIR"
    else
        skip "kept $VC_CFG_DIR"
    fi
}

run_root_phase() {
    local id any=0
    say "${C_B}privileged steps${C_0}"
    for id in $(ls "$VC_AVAILABLE"/*.toggle 2>/dev/null | while read -r f; do toggle_id "$f"; done); do
        has_phase "$id" root-uninstall || continue
        any=1
        printf '  %s%s%s\n' "$C_B" "$id" "$C_0"
        VC_TARGET_USER="${SUDO_USER:-$VC_USER}" run_phase "$id" root-uninstall \
            || warn "$id: root step failed"
    done
    (( any )) || skip "nothing to do"
}

# ------------------------------------------------------------------- main --
if [[ $MODE == root ]]; then run_root_phase; exit 0; fi

mapfile -t IDS_ALL < <(installed_ids)
if [[ -n $SELECT ]]; then
    IFS=',' read -ra CHOSEN <<<"$SELECT"
else
    CHOSEN=("${IDS_ALL[@]}")
fi

say ""
say "${C_B}vibecontrol uninstall${C_0}"
say ""
say "  features to remove: ${CHOSEN[*]:-none}"
(( PURGE )) && say "  ${C_Y}--purge: config will be deleted too${C_0}"
say "  models are never touched"
say ""
confirm "proceed?" || die "aborted"
say ""

(( ${#CHOSEN[@]} )) && remove_toggles "${CHOSEN[@]}"

# A partial removal leaves the daemon and core in place; only a full one takes
# them down.
if [[ -z $SELECT ]]; then
    say ""; stop_daemon
    say ""; remove_core
    (( PURGE )) && { say ""; purge_config; }
fi

NEED_ROOT=()
for id in "${CHOSEN[@]:-}"; do has_phase "$id" root-uninstall && NEED_ROOT+=("$id"); done
say ""
if (( ${#NEED_ROOT[@]} )); then
    say "${C_Y}privileged leftovers remain${C_0} for: ${NEED_ROOT[*]}"
    say "  polkit rules, drop-ins and helpers installed as root"
    say "  run: ${C_B}sudo $VC_ROOT/uninstall.sh --root${C_0}"
else
    say "${C_G}done${C_0}"
fi
