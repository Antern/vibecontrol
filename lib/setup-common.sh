# Shared by install.sh and uninstall.sh. Sourced, never executed.
#
# The split that shapes all of this: everything here runs unprivileged, and
# anything needing root is *collected* rather than done, so the caller can show
# it and let the user run one reviewable command. A setup script that silently
# calls sudo gives several prompts and no way to read them first.

VC_CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vibecontrol"
VC_MANIFEST="$VC_CFG_DIR/installed"
VC_TOGGLE_DIR="$VC_CFG_DIR/toggles"
VC_AVAILABLE="$VC_ROOT/toggles/available"
VC_BIN="$HOME/.local/bin"
VC_USER_UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
VC_DESKTOP="$HOME/.local/share/applications"
# $USER is not guaranteed: su -c, cron and some service contexts leave it
# unset, and `set -u` aborts on it. id -un always answers.
VC_USER="${USER:-$(id -un)}"

if [[ -t 1 ]]; then
    C_B=$'\033[1m'; C_D=$'\033[2m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
    C_R=$'\033[31m'; C_0=$'\033[0m'
else
    C_B=""; C_D=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '  %s%s%s\n' "$C_G" "$*" "$C_0"; }
skip() { printf '  %s%s%s\n' "$C_D" "$*" "$C_0"; }
warn() { printf '  %s%s%s\n' "$C_Y" "$*" "$C_0" >&2; }
die()  { printf '%s%s%s\n' "$C_R" "$*" "$C_0" >&2; exit 1; }

# --------------------------------------------------------------- toggles --
# A toggle is addressed by its short id (the part after the numeric prefix),
# because that is what the daemon, the config file and the manifest all use.
# The numeric prefix is display order and may change; the id must not.
toggle_files()  { ls "$VC_AVAILABLE"/*.toggle 2>/dev/null; }
toggle_id()     { local b; b=$(basename "$1" .toggle); echo "${b#*-}"; }
toggle_file()   { ls "$VC_AVAILABLE"/*-"$1".toggle 2>/dev/null | head -1; }
toggle_setup()  { local f; f=$(toggle_file "$1") || return 1
                  [[ -n $f ]] && echo "${f%.toggle}.setup"; }

# Metadata is read in a subshell so a toggle's variables cannot leak here --
# the same reason the daemon does it that way.
toggle_label()  {
    local f; f=$(toggle_file "$1"); [[ -n $f ]] || return 1
    ( set +u; source "$f" 2>/dev/null; printf '%s' "${label:-$1}" )
}

# Does this toggle have a setup script, and does it implement this phase?
# Phases are optional: a toggle needing nothing has no script at all, and one
# needing only user setup has no root-install.
has_phase() {
    local s; s=$(toggle_setup "$1") || return 1
    [[ -x $s ]] || return 1
    "$s" phases 2>/dev/null | grep -qx "$2"
}

run_phase() {
    local id="$1" phase="$2" s
    s=$(toggle_setup "$id") || return 0
    [[ -x $s ]] || return 0
    "$s" phases 2>/dev/null | grep -qx "$phase" || return 0
    VC_ROOT="$VC_ROOT" VC_CFG_DIR="$VC_CFG_DIR" "$s" "$phase"
}

# -------------------------------------------------------------- manifest --
# What uninstall reads to know what to undo. Without it uninstall would have to
# guess, and guessing about removal is how things get deleted that should not.
manifest_read()  { [[ -f $VC_MANIFEST ]] && grep -vE '^\s*(#|$)' "$VC_MANIFEST" || true; }
manifest_has()   { manifest_read | grep -qx "$1"; }
manifest_add()   {
    manifest_has "$1" && return 0
    mkdir -p "$VC_CFG_DIR"; printf '%s\n' "$1" >>"$VC_MANIFEST"
}
manifest_del()   {
    [[ -f $VC_MANIFEST ]] || return 0
    grep -vx "$1" "$VC_MANIFEST" >"$VC_MANIFEST.tmp" 2>/dev/null || true
    mv -f "$VC_MANIFEST.tmp" "$VC_MANIFEST"
}

# --------------------------------------------------------------- linking --
link_into() {   # src dstdir
    local src="$1" dst="$2/$(basename "$1")"
    mkdir -p "$2"
    if [[ -L $dst && $(readlink -f "$dst") == "$(readlink -f "$src")" ]]; then
        skip "already linked: ${dst/#$HOME/\~}"
    else
        ln -sfn "$src" "$dst"; step "linked ${dst/#$HOME/\~}"
    fi
}

unlink_ours() { # path -- only removes a symlink that points into this repo
    local p="$1" t
    [[ -L $p ]] || { [[ -e $p ]] && warn "not a symlink, left alone: ${p/#$HOME/\~}"; return 0; }
    t=$(readlink -f "$p" 2>/dev/null)
    if [[ $t == "$VC_ROOT"/* ]]; then rm -f "$p"; step "removed ${p/#$HOME/\~}"
    else warn "points outside the repo, left alone: ${p/#$HOME/\~}"; fi
}
