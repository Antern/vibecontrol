#!/usr/bin/env bash
# Grants this user the privileges the "Desktop (Plasma)" toggle needs.
# Run once per machine, as root:   sudo install/desktop-privileges.sh
#
# Two things are installed:
#   1. a polkit rule letting the user start/stop the login manager, so the
#      machine can be dropped to a TTY (freeing ~1 GB of VRAM for local LLM
#      work) and brought back, both over SSH;
# Autologin needs no change: the desktop toggle stops and starts the login
# manager as a whole, and Autologin fires for the first session of a freshly
# started manager. Relogin=true is deliberately NOT set -- it would send the
# machine straight back into a new session after the toggle logs out, and it
# would also change what the user's own "Log Out" menu entry does.
set -euo pipefail

USER_NAME="${SUDO_USER:-${1:-}}"
[[ -n $USER_NAME ]] || { echo "usage: sudo $0 [username]" >&2; exit 2; }
id "$USER_NAME" >/dev/null || exit 1

DM_UNIT="plasmalogin.service"
GREETER_USER="plasmalogin"
GREETER_UID="$(id -u "$GREETER_USER" 2>/dev/null || true)"
systemctl cat "$DM_UNIT" >/dev/null 2>&1 \
    || { echo "no $DM_UNIT on this machine -- adjust DM_UNIT" >&2; exit 1; }

install -d -m 0755 /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-vibecontrol-desktop.rules <<RULE
// Let $USER_NAME stop and start the login manager without authenticating.
//
// pkexec is deliberately not used for this (nor for sshd): pkexec needs a
// polkit *agent*, which is a desktop component, so it would stop working at
// exactly the moment the desktop goes down. A rule keeps the toggle honest
// about being category="common".
//
// Scoped to one unit and three verbs -- this is not general unit control.
polkit.addRule(function (action, subject) {
    if (action.id !== "org.freedesktop.systemd1.manage-units") {
        return polkit.Result.NOT_HANDLED;
    }
    if (subject.user !== "$USER_NAME") {
        return polkit.Result.NOT_HANDLED;
    }
    // The greeter runs under its own logind-started user manager, which is not
    // in the login manager's control group and survives stopping it. Both have
    // to be stoppable or the greeter's compositor keeps holding the GPU.
    var unit = action.lookup("unit");
    if (unit !== "$DM_UNIT" && unit !== "user@$GREETER_UID.service") {
        return polkit.Result.NOT_HANDLED;
    }
    var verb = action.lookup("verb");
    if (verb === "start" || verb === "stop" || verb === "restart") {
        return polkit.Result.YES;
    }
    return polkit.Result.NOT_HANDLED;
});
RULE
chmod 0644 /etc/polkit-1/rules.d/50-vibecontrol-desktop.rules

# Remove the Relogin drop-in an earlier version of this script installed.
rm -f /etc/plasmalogin.conf.d/10-vibecontrol-relogin.conf

# The daemon must outlive the graphical session it is able to switch off.
loginctl enable-linger "$USER_NAME"

echo "installed:"
echo "  /etc/polkit-1/rules.d/50-vibecontrol-desktop.rules"
echo "      covering $DM_UNIT and user@$GREETER_UID.service"
echo "  linger for $USER_NAME: $(loginctl show-user "$USER_NAME" -p Linger --value)"
echo
echo "verify without touching the session:"
echo "  pkcheck --action-id org.freedesktop.systemd1.manage-units \\"
echo "      --process \$\$ --detail unit $DM_UNIT --detail verb stop"
