#!/usr/bin/env bash
#
# vibecontrol installer.
#
# Two phases, deliberately. Everything that can be done as you is done as you;
# anything needing root is collected and printed as a single command you can
# read before running. Nothing here calls sudo on your behalf.
#
#   ./install.sh                 pick toggles interactively, install them
#   ./install.sh --all           every toggle, no prompt
#   ./install.sh --toggles=a,b   just these
#   ./install.sh --list          show what is available and skip installing
#   sudo ./install.sh --root     the privileged steps, after the above
#
# Re-running is safe and is also the upgrade path: already-linked files are
# left alone, newly chosen toggles are added, existing ones are not disturbed.
set -uo pipefail

VC_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# --root runs as root, so the user's paths have to be resolved from SUDO_USER
# rather than from HOME, which sudo has already replaced.
if [[ ${1:-} == --root ]]; then
    TARGET_USER="${SUDO_USER:-}"
    [[ -n $TARGET_USER ]] || { echo "run this with sudo, not as root directly" >&2; exit 2; }
    HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    export HOME
fi

# shellcheck source=lib/setup-common.sh
source "$VC_ROOT/lib/setup-common.sh"

MODE=install SELECT="" WANT_ALL=0
for arg in "$@"; do
    case "$arg" in
        --root)       MODE=root ;;
        --all)        WANT_ALL=1 ;;
        --list)       MODE=list ;;
        --toggles=*)  SELECT="${arg#--toggles=}" ;;
        -h|--help)    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "unknown argument: $arg" ;;
    esac
done

# --------------------------------------------------------------- surveying --
# check is advisory: it reports whether a toggle's prerequisites are present so
# the default selection is sensible, and it never modifies anything.
toggle_state() {   # id -> "ok" | "missing: ..." | "-"
    local id="$1" s out
    s=$(toggle_setup "$id") || { echo "-"; return; }
    [[ -x $s ]] || { echo "-"; return; }
    "$s" phases 2>/dev/null | grep -qx check || { echo "-"; return; }
    if out=$("$s" check 2>&1); then echo "ok"; else echo "missing: ${out:-unknown}"; fi
}

declare -a IDS=() LABELS=() STATES=() ROOTY=()
survey() {
    local f id
    for f in $(toggle_files); do
        id=$(toggle_id "$f")
        IDS+=("$id")
        LABELS+=("$(toggle_label "$id")")
        STATES+=("$(toggle_state "$id")")
        has_phase "$id" root-install && ROOTY+=("yes") || ROOTY+=("")
    done
}

show_table() {
    local i mark
    printf '  %-3s %-12s %-22s %-8s %s\n' "" "ID" "FEATURE" "ROOT" "PREREQUISITES"
    for i in "${!IDS[@]}"; do
        mark=$( manifest_has "${IDS[$i]}" && echo "${C_G}*${C_0}" || echo " " )
        printf '  %s%-2s %-12s %-22s %-8s %s\n' "$mark" "$((i + 1))" \
            "${IDS[$i]}" "${LABELS[$i]}" \
            "$([[ -n ${ROOTY[$i]} ]] && echo yes || echo "-")" \
            "$(case "${STATES[$i]}" in
                 ok)       printf '%sok%s' "$C_D" "$C_0" ;;
                 -)        printf '%s-%s'  "$C_D" "$C_0" ;;
                 missing*) printf '%s%s%s' "$C_Y" "${STATES[$i]}" "$C_0" ;;
               esac)"
    done
    printf '  %s* = already installed%s\n' "$C_D" "$C_0"
}

# ------------------------------------------------------------------ choose --
# Default to everything whose prerequisites are satisfied, plus anything
# already installed. A toggle whose backend is missing is shown but not chosen:
# installing it would put a permanently unavailable row in the menu.
default_selection() {
    local i
    for i in "${!IDS[@]}"; do
        if manifest_has "${IDS[$i]}" || [[ ${STATES[$i]} == ok || ${STATES[$i]} == - ]]; then
            printf '%s\n' "${IDS[$i]}"
        fi
    done
}

parse_selection() {   # "1,3,5" | "all" | "none" | "a,b"
    local raw="$1" tok i
    case "$raw" in
        all|a)  printf '%s\n' "${IDS[@]}"; return ;;
        none|n) return ;;
        "")     default_selection; return ;;
    esac
    IFS=',' read -ra toks <<<"$raw"
    for tok in "${toks[@]}"; do
        tok="${tok// /}"
        [[ -z $tok ]] && continue
        if [[ $tok =~ ^[0-9]+$ ]]; then
            i=$((tok - 1))
            [[ -n ${IDS[$i]:-} ]] && printf '%s\n' "${IDS[$i]}" || warn "no such number: $tok"
        else
            [[ -n $(toggle_file "$tok") ]] && printf '%s\n' "$tok" || warn "no such toggle: $tok"
        fi
    done
}

# ------------------------------------------------------------------- core --
install_core() {
    say "${C_B}core${C_0}"
    mkdir -p "$VC_BIN" "$VC_CFG_DIR" "$VC_TOGGLE_DIR" "$VC_USER_UNITS" "$VC_DESKTOP"
    link_into "$VC_ROOT/bin/vibecontrol"  "$VC_BIN"
    link_into "$VC_ROOT/bin/vibecontrold" "$VC_BIN"
    link_into "$VC_ROOT/systemd/vibecontrol-daemon.service" "$VC_USER_UNITS"
    link_into "$VC_ROOT/desktop/vibecontrol.desktop" "$VC_DESKTOP"
    [[ -f $VC_CFG_DIR/config ]] || { : >"$VC_CFG_DIR/config"; step "created ~/.config/vibecontrol/config"; }
    case ":$PATH:" in *":$VC_BIN:"*) ;; *) warn "$VC_BIN is not on PATH" ;; esac
}

install_toggles() {   # ids...
    local id f
    say "${C_B}toggles${C_0}"
    for id in "$@"; do
        f=$(toggle_file "$id")
        [[ -n $f ]] || { warn "no such toggle: $id"; continue; }
        link_into "$f" "$VC_TOGGLE_DIR"
        if run_phase "$id" install; then manifest_add "$id"
        else warn "$id: install step failed, not recorded"; fi
    done
}

# Toggles linked in but no longer selected. Removing the link is enough to take
# them out of the menu; their own uninstall is left to uninstall.sh, because
# "I did not pick it this time" is not the same as "take it off my machine".
prune_toggles() {   # selected ids...
    local want=" $* " f id
    for f in "$VC_TOGGLE_DIR"/*.toggle; do
        [[ -e $f ]] || continue
        id=$(toggle_id "$f")
        [[ $want == *" $id "* ]] && continue
        unlink_ours "$f"
        skip "$id: unlinked (still installed; use uninstall.sh to remove it)"
    done
}

enable_daemon() {
    say "${C_B}daemon${C_0}"
    systemctl --user daemon-reload 2>/dev/null
    if systemctl --user is-enabled vibecontrol-daemon.service >/dev/null 2>&1; then
        systemctl --user restart vibecontrol-daemon.service 2>/dev/null \
            && step "restarted vibecontrol-daemon"
    else
        systemctl --user enable --now vibecontrol-daemon.service 2>/dev/null \
            && step "enabled and started vibecontrol-daemon"
    fi
    loginctl show-user "$VC_USER" -p Linger --value 2>/dev/null | grep -qx yes \
        || warn "linger is off: the daemon dies with your session (the desktop toggle needs it)"
}

# ------------------------------------------------------------------- root --
# Which features this user has installed. The manifest is authoritative, but
# it lives in their home and this phase runs as root -- if it cannot be read
# the honest answer is to say so, not to report success having done nothing.
# Falling back to what is actually linked keeps a hand-made install working.
root_targets() {
    local any=0 id f
    while read -r id; do [[ -n $id ]] && { printf '%s\n' "$id"; any=1; }; done < <(manifest_read)
    (( any )) && return 0
    for f in "$VC_TOGGLE_DIR"/*.toggle; do
        [[ -e $f ]] || continue
        toggle_id "$f"; any=1
    done
    (( any )) || return 1
}

run_root_phase() {
    local id any=0 found=0
    say "${C_B}privileged steps${C_0}"
    say "  ${C_D}for ${VC_CFG_DIR/#$HOME/\~} (user: ${SUDO_USER:-$VC_USER})${C_0}"
    while read -r id; do
        [[ -n $id ]] || continue
        found=1
        has_phase "$id" root-install || continue
        any=1
        printf '  %s%s%s\n' "$C_B" "$id" "$C_0"
        VC_TARGET_USER="${SUDO_USER:-$VC_USER}" run_phase "$id" root-install \
            || warn "$id: root step failed"
    done < <(root_targets)
    if (( ! found )); then
        die "no installed features found under $VC_CFG_DIR
  Nothing was done. Run ./install.sh as your own user first, or check that
  \$SUDO_USER is the account you installed as."
    fi
    (( any )) || skip "no feature needs privileged setup"
}

# ------------------------------------------------------------------- main --
survey
[[ ${#IDS[@]} -gt 0 ]] || die "no toggles found in $VC_AVAILABLE"

case $MODE in
list) show_table; exit 0 ;;
root) run_root_phase; exit 0 ;;
esac

say ""
say "${C_B}vibecontrol${C_0} ${C_D}$VC_ROOT${C_0}"
say ""
show_table
say ""

if (( WANT_ALL )); then
    mapfile -t CHOSEN < <(printf '%s\n' "${IDS[@]}")
elif [[ -n $SELECT ]]; then
    mapfile -t CHOSEN < <(parse_selection "$SELECT")
elif [[ -t 0 ]]; then
    printf '  which toggles? %s[Enter]=recommended, all, none, or 1,3,5%s\n  > ' "$C_D" "$C_0"
    read -r reply
    mapfile -t CHOSEN < <(parse_selection "$reply")
else
    mapfile -t CHOSEN < <(default_selection)
fi

say ""
[[ ${#CHOSEN[@]} -gt 0 ]] || { say "nothing selected"; }

install_core
say ""
(( ${#CHOSEN[@]} )) && install_toggles "${CHOSEN[@]}"
prune_toggles "${CHOSEN[@]:-}"
say ""
enable_daemon

# Root steps last, so the message is the final thing on screen rather than
# scrolled away by the rest of the install.
NEED_ROOT=()
for id in "${CHOSEN[@]:-}"; do has_phase "$id" root-install && NEED_ROOT+=("$id"); done
say ""
if (( ${#NEED_ROOT[@]} )); then
    say "${C_Y}privileged steps remain${C_0} for: ${NEED_ROOT[*]}"
    say "  read them first:  ${C_D}less $VC_ROOT/toggles/available/*.setup${C_0}"
    say "  then run:         ${C_B}sudo $VC_ROOT/install.sh --root${C_0}"
else
    say "${C_G}done${C_0} - run ${C_B}vibecontrol${C_0}"
fi
