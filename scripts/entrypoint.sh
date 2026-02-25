#!/usr/bin/env bash
# =============================================================
# entrypoint.sh — Container startup for dockerized-lmstudio
# 
# NEW WITH SUPERVISORD:
# This script now ONLY does setup tasks, then hands control
# to supervisord for process management.
#
# Responsibilities:
#   1. Configure SSH (if key provided)
#   2. Configure VNC password
#   3. Set up XFCE desktop environment
#   4. Enable SSH in supervisord (if configured)
#   5. exec supervisord (takes over as PID 1)
# =============================================================

set -euo pipefail

# ---- Configuration ------------------------------------------
LMUSER_HOME="/home/lmuser"

# ---- helpers ------------------------------------------------
log()  { echo "[entrypoint] $*"; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

log "=============================================="
log "Starting LM Studio container setup..."
log "=============================================="

# ---- sanity checks ------------------------------------------
[[ -z "${VNC_PASSWORD:-}" ]] && die "VNC_PASSWORD environment variable is not set."
[[ ${#VNC_PASSWORD} -lt 6 ]] && die "VNC_PASSWORD must be at least 6 characters (VNC limit)."

# ---- SSH server setup ---------------------------------------
SSH_ENABLED=false
if [[ -n "${SSH_PUBLIC_KEY_PATH:-}" ]] && [[ -f "/tmp/ssh_public_key" ]]; then
    log "Configuring SSH key-based authentication..."
    
    # Ensure .ssh directory exists with correct permissions
    mkdir -p "${LMUSER_HOME}/.ssh"
    chmod 700 "${LMUSER_HOME}/.ssh"
    
    # Copy the public key to authorized_keys
    cat /tmp/ssh_public_key > "${LMUSER_HOME}/.ssh/authorized_keys"
    chmod 600 "${LMUSER_HOME}/.ssh/authorized_keys"
    chown -R lmuser:lmuser "${LMUSER_HOME}/.ssh"
    
    log "✓ SSH public key configured."
    log "  → Connect via: ssh -i <private-key> -p 2222 lmuser@<tailscale-hostname>"
    SSH_ENABLED=true
else
    log "SSH_PUBLIC_KEY_PATH not set or key file not found."
    log "SSH access is disabled. To enable:"
    log "  1. Set SSH_PUBLIC_KEY_PATH=/path/to/your/id_rsa.pub in .env"
    log "  2. Rebuild and restart the container"
fi

# ---- VNC password -------------------------------------------
log "Configuring VNC password..."
mkdir -p "${LMUSER_HOME}/.vnc"
echo "${VNC_PASSWORD}" | vncpasswd -f > "${LMUSER_HOME}/.vnc/passwd"
chmod 600 "${LMUSER_HOME}/.vnc/passwd"
chown -R lmuser:lmuser "${LMUSER_HOME}/.vnc"
log "✓ VNC password configured."

# ---- xstartup (desktop session launched by VNC) -------------
log "Setting up XFCE desktop session..."
mkdir -p "${LMUSER_HOME}/.vnc"
cp /home/lmuser/scripts/xstartup "${LMUSER_HOME}/.vnc/xstartup"
chmod +x "${LMUSER_HOME}/.vnc/xstartup"
chown lmuser:lmuser "${LMUSER_HOME}/.vnc/xstartup"
log "✓ xstartup configured."

# ---- XFCE autostart — launch LM Studio on login ------------
mkdir -p "${LMUSER_HOME}/.config/autostart"
cat > "${LMUSER_HOME}/.config/autostart/lmstudio.desktop" << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=LM Studio
Exec="/opt/LM Studio/lm-studio" --no-sandbox
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
DESKTOP
chown lmuser:lmuser "${LMUSER_HOME}/.config/autostart/lmstudio.desktop"
log "✓ LM Studio autostart configured."

# ---- Clean up any stale VNC locks ---------------------------
VNC_LOCK="/tmp/.X1-lock"
if [[ -f "${VNC_LOCK}" ]]; then
    log "Removing stale VNC lock files..."
    rm -f "${VNC_LOCK}" /tmp/.X11-unix/X1 2>/dev/null || true
fi

log "=============================================="
log "Setup complete! Starting supervisord..."
log "=============================================="

# ---- Enable SSH in supervisord if configured ----------------
if [[ "${SSH_ENABLED}" == "true" ]]; then
    # Modify supervisord config to autostart SSH
    # This is done by passing a command after supervisord starts
    # We'll use a wrapper approach: start supervisord in background,
    # enable SSH, then bring it to foreground
    
    log "Enabling SSH service in supervisord..."
    # Start supervisord in background briefly
    /usr/bin/supervisord -c /etc/supervisor/supervisord.conf &
    SUPERVISOR_PID=$!
    
    # Wait for supervisord to be ready (socket available)
    for i in {1..10}; do
        if [[ -S /var/run/supervisor.sock ]]; then
            break
        fi
        sleep 0.5
    done
    
    # Enable and start SSH
    /usr/bin/supervisorctl start sshd
    log "✓ SSH service started."
    
    # Now wait for supervisord (it's in foreground via nodaemon=true)
    wait ${SUPERVISOR_PID}
else
    # No SSH, just start supervisord normally
    log "Starting all services (VNC, noVNC)..."
    exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
fi

# If we reach here, supervisord exited
log "Supervisord exited."
