#!/usr/bin/env bash
# =============================================================
# entrypoint.sh — Container startup for dockerized-lmstudio
# Responsibilities:
#   1. Configure VNC password
#   2. Set up XFCE xstartup
#   3. Start TigerVNC server
#   4. Start noVNC websocket proxy
#   5. Keep the container alive (tail logs)
# =============================================================

set -euo pipefail

# ---- helpers ------------------------------------------------
log()  { echo "[entrypoint] $*"; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }


# ---- sanity checks ------------------------------------------
[[ -z "${VNC_PASSWORD:-}" ]] && die "VNC_PASSWORD environment variable is not set."
[[ ${#VNC_PASSWORD} -lt 6 ]] && die "VNC_PASSWORD must be at least 6 characters (VNC limit)."

# ---- DBUS (required by some XFCE components) ----------------
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    eval "$(dbus-launch --sh-syntax)" || true
fi

# ---- SSH server setup (non-privileged port 2222) ------------
if [[ -n "${SSH_PUBLIC_KEY_PATH:-}" ]] && [[ -f "/tmp/ssh_public_key" ]]; then
    log "Configuring SSH key-based authentication..."
    
    # Ensure .ssh directory exists with correct permissions
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    
    # Copy the public key to authorized_keys
    cat /tmp/ssh_public_key > "${HOME}/.ssh/authorized_keys"
    chmod 600 "${HOME}/.ssh/authorized_keys"
    
    log "SSH public key configured."
    log "Starting SSH server on port 2222..."
    
    # Start sshd as non-root user on port 2222
    /usr/sbin/sshd -f "${HOME}/sshd/sshd_config" -E "${HOME}/sshd/sshd.log"
    
    # Check if sshd is listening
    sleep 1
    if ss -lnt | grep -q ":2222"; then
        log "SSH server is listening on port 2222."
        log "→ Connect via: ssh -i <your-private-key> -p 2222 lmuser@<tailscale-hostname>"
        log "→ Example: ssh -i ~/.ssh/id_ed25519 -p 2222 lmuser@lmstudio"
    else
        log "WARNING: SSH server may not have started. Check ${HOME}/sshd/sshd.log"
        cat "${HOME}/sshd/sshd.log" 2>/dev/null || true
    fi
else
    log "SSH_PUBLIC_KEY_PATH not set or key file not found."
    log "SSH access is disabled. To enable:"
    log "  1. Set SSH_PUBLIC_KEY_PATH=/path/to/your/id_rsa.pub in .env"
    log "  2. Rebuild and restart the container"
fi

# ---- VNC password -------------------------------------------
mkdir -p "${HOME}/.vnc"
# Use vncpasswd from tightvncserver package
echo "${VNC_PASSWORD}" | vncpasswd -f > "${HOME}/.vnc/passwd"
chmod 600 "${HOME}/.vnc/passwd"
log "VNC password configured."

# ---- xstartup (desktop session launched by VNC) -------------
mkdir -p "${HOME}/.vnc"
cp /home/lmuser/scripts/xstartup "${HOME}/.vnc/xstartup"
chmod +x "${HOME}/.vnc/xstartup"

# ---- XFCE autostart — launch LM Studio on login ------------
mkdir -p "${HOME}/.config/autostart"
cat > "${HOME}/.config/autostart/lmstudio.desktop" << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=LM Studio
Exec="/opt/LM Studio/lm-studio" --no-sandbox
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
DESKTOP
log "LM Studio autostart configured."

# ---- Kill any stale VNC lock --------------------------------
VNC_LOCK="/tmp/.X1-lock"
if [[ -f "${VNC_LOCK}" ]]; then
    log "Removing stale VNC lock ${VNC_LOCK}."
    rm -f "${VNC_LOCK}" /tmp/.X11-unix/X1 2>/dev/null || true
fi

# ---- Start TigerVNC server ----------------------------------
VNC_RESOLUTION="${VNC_RESOLUTION:-1920x1080}"
VNC_COL_DEPTH="${VNC_COL_DEPTH:-24}"

log "Starting TigerVNC on :1 (${VNC_RESOLUTION} @ ${VNC_COL_DEPTH}bpp)…"
vncserver :1 \
    -geometry "${VNC_RESOLUTION}" \
    -depth "${VNC_COL_DEPTH}" \
    -SecurityTypes VncAuth \
    -PasswordFile "${HOME}/.vnc/passwd" \
    -localhost no \
    -fg &
VNC_PID=$!

# Wait until VNC is accepting connections (max 20 s)
for i in $(seq 1 20); do
    if ss -lnt | grep -q ":${VNC_PORT:-5901}"; then
        log "VNC server is up (attempt ${i})."
        break
    fi
    sleep 1
done

# ---- Start noVNC websocket proxy ----------------------------
NOVNC_PORT="${NOVNC_PORT:-6080}"
NOVNC_WEB="/usr/share/novnc"

log "Starting noVNC on port ${NOVNC_PORT} → VNC :${VNC_PORT:-5901}…"
websockify \
    --web "${NOVNC_WEB}" \
    --heartbeat 30 \
    "0.0.0.0:${NOVNC_PORT}" \
    "localhost:${VNC_PORT:-5901}" &
NOVNC_PID=$!

log "======================================================"
log " LM Studio is starting up."
log " → Open: http://<tailscale-hostname>:${NOVNC_PORT}/vnc.html"
log " → VNC password required."
log "======================================================"

# ---- Keep container alive; exit if a key process dies -------
# Trap SIGTERM/SIGINT for clean shutdown
cleanup() {
    log "Shutting down…"
    kill "${NOVNC_PID}" "${VNC_PID}" 2>/dev/null || true
    vncserver -kill :1 2>/dev/null || true
    pkill -u lmuser sshd 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# Monitor VNC and noVNC processes - if either dies, exit
while kill -0 "${VNC_PID}" 2>/dev/null && kill -0 "${NOVNC_PID}" 2>/dev/null; do
    sleep 5
done

# If we get here, one of the processes died
if ! kill -0 "${VNC_PID}" 2>/dev/null; then
    die "VNC server (PID ${VNC_PID}) exited unexpectedly."
fi
if ! kill -0 "${NOVNC_PID}" 2>/dev/null; then
    die "noVNC (PID ${NOVNC_PID}) exited unexpectedly."
fi
