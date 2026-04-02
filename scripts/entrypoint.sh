#!/usr/bin/env bash
# =============================================================
# entrypoint.sh — setup runtime state, then drop privileges and
# hand off to supervisord.
# =============================================================

set -euo pipefail

LMUSER_HOME="/home/lmuser"
SUPERVISOR_CONF_DIR="/etc/supervisor/conf.d"
SUPERVISOR_OPTIONAL_DIR="/etc/supervisor/optional.d"

log()  { echo "[entrypoint] $*"; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

log "=============================================="
log "Starting LM Studio container setup..."
log "=============================================="

[[ -z "${VNC_PASSWORD:-}" ]] && die "VNC_PASSWORD environment variable is not set."
[[ ${#VNC_PASSWORD} -lt 6 || ${#VNC_PASSWORD} -gt 8 ]] && die "VNC_PASSWORD must be 6-8 characters (VNC protocol limit)."

mkdir -p \
    "${LMUSER_HOME}" \
    "${LMUSER_HOME}/.cache/lm-studio" \
    "${LMUSER_HOME}/.config/autostart" \
    "${LMUSER_HOME}/.config/sshd" \
    "${LMUSER_HOME}/.lmstudio/bin" \
    "${LMUSER_HOME}/.ssh" \
    "${LMUSER_HOME}/.supervisor" \
    "${LMUSER_HOME}/.vnc"
chmod 700 "${LMUSER_HOME}/.ssh"
chown -R lmuser:lmuser \
    "${LMUSER_HOME}" \
    "${LMUSER_HOME}/.cache" \
    "${LMUSER_HOME}/.config" \
    "${LMUSER_HOME}/.lmstudio" \
    "${LMUSER_HOME}/.ssh" \
    "${LMUSER_HOME}/.supervisor" \
    "${LMUSER_HOME}/.vnc"

SSH_ENABLED=false
if [[ -n "${SSH_PUBLIC_KEY_PATH:-}" ]] && [[ -f "/tmp/ssh_public_key" ]]; then
    log "Configuring SSH key-based authentication..."
    ssh-keygen -l -f /tmp/ssh_public_key >/dev/null 2>&1 || die "SSH_PUBLIC_KEY_PATH does not point to a valid public key."

    cat /tmp/ssh_public_key > "${LMUSER_HOME}/.ssh/authorized_keys"
    chmod 600 "${LMUSER_HOME}/.ssh/authorized_keys"

    if [[ ! -f "${LMUSER_HOME}/.config/sshd/ssh_host_ed25519_key" ]]; then
        log "Generating SSH host keys..."
        ssh-keygen -t rsa -f "${LMUSER_HOME}/.config/sshd/ssh_host_rsa_key" -N ''
        ssh-keygen -t ecdsa -f "${LMUSER_HOME}/.config/sshd/ssh_host_ecdsa_key" -N ''
        ssh-keygen -t ed25519 -f "${LMUSER_HOME}/.config/sshd/ssh_host_ed25519_key" -N ''
        chmod 600 "${LMUSER_HOME}/.config/sshd/ssh_host_"*
    fi

    cp "${SUPERVISOR_OPTIONAL_DIR}/sshd.conf" "${SUPERVISOR_CONF_DIR}/sshd.conf"
    log "✓ SSH public key configured."
    log "  → Connect via: ssh -i <private-key> -p 2222 lmuser@<tailscale-hostname>"
    SSH_ENABLED=true
else
    rm -f "${SUPERVISOR_CONF_DIR}/sshd.conf" "${LMUSER_HOME}/.ssh/authorized_keys"
    log "SSH_PUBLIC_KEY_PATH not set or key file not found."
    log "SSH access is disabled. To enable:"
    log "  1. Set SSH_PUBLIC_KEY_PATH=/path/to/your/id_ed25519.pub in .env"
    log "  2. Restart the container"
fi

log "Configuring VNC password..."
VNC_PASSWD_BIN="$(command -v vncpasswd || command -v tigervncpasswd || true)"
[[ -n "${VNC_PASSWD_BIN}" ]] || die "Neither vncpasswd nor tigervncpasswd is installed."
echo "${VNC_PASSWORD}" | "${VNC_PASSWD_BIN}" -f > "${LMUSER_HOME}/.vnc/passwd"
chmod 600 "${LMUSER_HOME}/.vnc/passwd"
log "✓ VNC password configured."

log "Setting up XFCE desktop session..."
cp /usr/local/bin/lmstudio/xstartup "${LMUSER_HOME}/.vnc/xstartup"
chmod +x "${LMUSER_HOME}/.vnc/xstartup"
log "✓ xstartup configured."

cat > "${LMUSER_HOME}/.config/autostart/lmstudio.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=LM Studio
Exec=/usr/local/bin/lmstudio/lmstudio-launcher
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
DESKTOP
log "✓ LM Studio autostart configured."

ln -sf /usr/local/bin/lmstudio/lms-wrapper "${LMUSER_HOME}/.lmstudio/bin/lms"
chown -h lmuser:lmuser "${LMUSER_HOME}/.lmstudio/bin/lms"
log "✓ lms wrapper configured."

if [[ -d /usr/share/applications ]]; then
    while IFS= read -r desktop_file; do
        sed -i 's#^Exec=.*#Exec=/usr/local/bin/lmstudio/lmstudio-launcher %U#' "${desktop_file}" || true
    done < <(find /usr/share/applications -maxdepth 1 -type f \( -iname '*lmstudio*.desktop' -o -iname '*lm-studio*.desktop' \))
fi

VNC_LOCK="/tmp/.X1-lock"
if [[ -f "${VNC_LOCK}" ]]; then
    log "Removing stale VNC lock files..."
    rm -f "${VNC_LOCK}" /tmp/.X11-unix/X1 2>/dev/null || true
fi

chown -R lmuser:lmuser \
    "${LMUSER_HOME}/.config" \
    "${LMUSER_HOME}/.ssh" \
    "${LMUSER_HOME}/.supervisor" \
    "${LMUSER_HOME}/.vnc"

log "=============================================="
if [[ "${SSH_ENABLED}" == "true" ]]; then
    log "Setup complete! Starting supervisord as lmuser with SSH enabled..."
else
    log "Setup complete! Starting supervisord as lmuser..."
fi
log "=============================================="

exec gosu lmuser /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
