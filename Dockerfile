# ============================================================
# Dockerized LM Studio
#
# Single-stage: nvidia/cuda base + XFCE desktop + VNC + noVNC
# LM Studio installed via official .deb package
# lms CLI wired onto PATH
# ============================================================

ARG CUDA_VERSION=12.3.1
ARG UBUNTU_VERSION=22.04
FROM nvidia/cuda:${CUDA_VERSION}-base-ubuntu${UBUNTU_VERSION}

LABEL maintainer="dockerized-lmstudio"
LABEL description="LM Studio (GPU) in an XFCE desktop, accessible via noVNC over Tailscale"

# ---- Build-time: LM Studio version / download URL ----------
# The /latest/ redirect always resolves to the current stable release.
# Pin to a specific version by overriding LMS_DEB_URL in your .env / compose args.
ARG LMS_VERSION=latest
ARG LMS_DEB_URL=https://lmstudio.ai/download/latest/linux/x64?format=deb

# ---- Runtime environment defaults --------------------------
ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    VNC_RESOLUTION=1920x1080 \
    VNC_COL_DEPTH=24 \
    VNC_PASSWORD="" \
    LMS_VERSION=${LMS_VERSION} \
    # lms CLI is installed by the .deb into ~/.lmstudio/bin — expose it on PATH
    PATH="/home/lmuser/.lmstudio/bin:${PATH}" \
    # NVIDIA runtime
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all

# ---- System packages ----------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # -- Lightweight desktop --
    xfce4 \
    xfce4-terminal \
    xfce4-goodies \
    # -- VNC server --
    tigervnc-standalone-server \
    tigervnc-common \
    tightvncserver \
    # -- noVNC + websocket proxy --
    novnc \
    websockify \
    # -- OpenGL / Mesa stubs (NVIDIA runtime supplies the real drivers) --
    libgl1-mesa-glx \
    libgl1-mesa-dri \
    libegl1-mesa \
    libgles2-mesa \
    libgbm1 \
    # -- Electron/Node runtime deps (LM Studio is Electron-based) --
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libdbus-glib-1-2 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libxss1 \
    libxtst6 \
    libnss3 \
    libasound2 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libxkbcommon0 \
    # -- General utilities --
    curl \
    wget \
    ca-certificates \
    dbus-x11 \
    xdg-utils \
    fonts-liberation \
    fonts-noto \
    iproute2 \
    python3 \
    # -- SSH server --
    openssh-server \
    # -- Process supervisor --
    supervisor \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ---- Supervisord directories -----------------------------------
# /var/log/supervisor — where each service's stdout/stderr logs go
# /etc/supervisor/conf.d — where we put individual service configs
RUN mkdir -p /var/log/supervisor /etc/supervisor/conf.d

# ---- Supervisord main configuration -------------------------
# This is the "brain" - tells supervisord how to operate
# Key setting: nodaemon=true (run in foreground for Docker)
RUN cat > /etc/supervisor/supervisord.conf << 'EOF'
; Supervisord main configuration file
; This configures the daemon itself, not the services

[unix_http_server]
file=/var/run/supervisor.sock   ; Socket for supervisorctl to communicate
chmod=0700                       ; Only root can access (security)

[supervisord]
nodaemon=true                    ; CRITICAL: Stay in foreground (Docker requirement)
user=root                        ; Supervisord runs as root (services can run as other users)
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=/var/log/supervisor  ; Where service logs go
loglevel=info                    ; info/debug/warn/error
logfile_maxbytes=50MB            ; Rotate logs at 50MB
logfile_backups=10               ; Keep 10 old logs

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock ; Connect via socket

[include]
files = /etc/supervisor/conf.d/*.conf     ; Load all service definitions
EOF

# ---- Non-root user (minimum privileges) --------------------
# - No sudo, no elevated capabilities at runtime
# - render group may not exist in the CUDA base image — create it first
# - video/render membership is required for GPU device access (/dev/dri)
# - Let the system pick the UID to avoid collisions with base-image UIDs
RUN groupadd -f render \
    && useradd -m -s /bin/bash lmuser \
    && usermod -aG video,render lmuser

# ---- Download + install LM Studio .deb ---------------------
# Installing as root; the .deb places app files under /opt/LM\ Studio or similar
# and the lms CLI under the bundle path.
RUN echo "Installing LM Studio ${LMS_VERSION} from: ${LMS_DEB_URL}" \
    && wget -q --show-progress --progress=bar:force:noscroll \
       "${LMS_DEB_URL}" -O /tmp/lmstudio.deb \
    && apt-get update \
    && dpkg -i /tmp/lmstudio.deb || apt-get install -f -y \
    && rm /tmp/lmstudio.deb \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---- Wire lms CLI onto PATH for lmuser ---------------------
# The .deb bundles lms inside the application directory.
# We create the expected PATH location and symlink it in.
RUN mkdir -p /home/lmuser/.lmstudio/bin \
    && ln -sf "/opt/LM Studio/resources/app/.webpack/lms" /home/lmuser/.lmstudio/bin/lms \
    && chown -R lmuser:lmuser /home/lmuser/.lmstudio

# ---- Add lms CLI to PATH for interactive shells ------------
# SSH login shells source .profile, interactive terminals source .bashrc
# Non-interactive sessions must use full path for security
RUN echo 'export PATH="/home/lmuser/.lmstudio/bin:$PATH"' >> /home/lmuser/.profile \
    && echo 'export PATH="/home/lmuser/.lmstudio/bin:$PATH"' >> /home/lmuser/.bashrc \
    && chown lmuser:lmuser /home/lmuser/.profile /home/lmuser/.bashrc

# ---- Desktop launcher for LM Studio ------------------------
RUN mkdir -p /usr/share/applications \
    && cat > /usr/share/applications/lmstudio.desktop << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=LM Studio
Comment=Run LLMs locally
Exec="/opt/LM Studio/lm-studio" --no-sandbox %U
Icon=lmstudio
Terminal=false
Categories=Development;AI;
EOF

# ---- Startup scripts (owned by lmuser) ---------------------
COPY --chown=lmuser:lmuser scripts/ /home/lmuser/scripts/
RUN chmod +x /home/lmuser/scripts/*.sh /home/lmuser/scripts/xstartup

# Pre-create config directories to prevent Docker volume mounts from creating them as root
RUN mkdir -p /home/lmuser/.config/autostart /home/lmuser/.cache/lm-studio \
    && chown -R lmuser:lmuser /home/lmuser/.config /home/lmuser/.cache

# ---- SSH server configuration (non-privileged) --------------
# Run sshd on port 2222 as lmuser - no root needed
RUN mkdir -p /home/lmuser/.ssh /home/lmuser/sshd \
    && chmod 700 /home/lmuser/.ssh \
    # Create user-level sshd_config for port 2222
    && mkdir -p /home/lmuser/.config/ssh \
    && chown -R lmuser:lmuser /home/lmuser/.ssh /home/lmuser/.config /home/lmuser/sshd

# Generate SSH host keys in user directory (as lmuser)
USER lmuser
RUN ssh-keygen -t rsa -f /home/lmuser/sshd/ssh_host_rsa_key -N '' \
    && ssh-keygen -t ecdsa -f /home/lmuser/sshd/ssh_host_ecdsa_key -N '' \
    && ssh-keygen -t ed25519 -f /home/lmuser/sshd/ssh_host_ed25519_key -N '' \
    && chmod 600 /home/lmuser/sshd/ssh_host_*

# Create custom sshd_config for non-root operation
USER root
RUN cat > /home/lmuser/sshd/sshd_config << 'EOF'
Port 2222
HostKey /home/lmuser/sshd/ssh_host_rsa_key
HostKey /home/lmuser/sshd/ssh_host_ecdsa_key
HostKey /home/lmuser/sshd/ssh_host_ed25519_key
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
PidFile /home/lmuser/sshd/sshd.pid
EOF

RUN chown lmuser:lmuser /home/lmuser/sshd/sshd_config

# ---- Supervisord service configurations ---------------------
# Each service gets its own config file in /etc/supervisor/conf.d/
# Format: [program:name] with command, restart policy, logging, etc.

# Service 1: SSH Server
# Runs on port 2222 as lmuser (non-privileged)
RUN cat > /etc/supervisor/conf.d/sshd.conf << 'EOF'
[program:sshd]
command=/usr/sbin/sshd -D -f /home/lmuser/sshd/sshd_config -e
  ; -D = Don't daemonize (stay in foreground - supervisord requirement)
  ; -f = Use our custom config file
  ; -e = Log to stderr (so supervisord captures it)

autostart=false
  ; Don't start automatically - only if SSH key is configured
  ; entrypoint.sh will enable this via supervisorctl if needed

autorestart=true
  ; If sshd crashes, restart it automatically
  ; Restart policy: always (even if exits cleanly)

user=lmuser
  ; Run as lmuser, not root (security!)

stdout_logfile=/var/log/supervisor/sshd-stdout.log
stderr_logfile=/var/log/supervisor/sshd-stderr.log
  ; Separate logs for stdout and stderr

stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
  ; Rotate logs at 10MB

priority=10
  ; Start order (lower numbers start first)
  ; SSH should start before others access it
EOF

# Service 2: VNC Server
# TigerVNC on display :1 with XFCE desktop
RUN cat > /etc/supervisor/conf.d/vnc.conf << 'EOF'
[program:vnc]
command=/usr/bin/vncserver :1 -fg -geometry %(ENV_VNC_RESOLUTION)s -depth %(ENV_VNC_COL_DEPTH)s -SecurityTypes VncAuth -PasswordFile /home/lmuser/.vnc/passwd -localhost no
  ; -fg = Foreground mode (critical for supervisord)
  ; -geometry = Desktop resolution (from environment variable)
  ; -SecurityTypes VncAuth = Use VNC password authentication
  ; -localhost no = Allow connections from network (Tailscale)
  ; %(ENV_VNC_RESOLUTION)s = Supervisord substitutes environment variable

autostart=true
  ; Always start VNC (core service)

autorestart=true
  ; Restart if it crashes

user=lmuser
  ; Run as lmuser (owns the desktop session)

environment=HOME="/home/lmuser",USER="lmuser",DISPLAY=":1"
  ; Set environment variables for the VNC process

stdout_logfile=/var/log/supervisor/vnc-stdout.log
stderr_logfile=/var/log/supervisor/vnc-stderr.log

stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB

priority=20
  ; Start after SSH (priority 10)

startsecs=5
  ; Consider it "started" if it stays up for 5 seconds
  ; Prevents restart loops if it crashes immediately

stopwaitsecs=10
  ; Wait 10 seconds for graceful shutdown before killing
EOF

# Service 3: noVNC WebSocket Proxy
# Bridges browser (WebSocket) to VNC (TCP)
RUN cat > /etc/supervisor/conf.d/novnc.conf << 'EOF'
[program:novnc]
command=/usr/bin/websockify --web /usr/share/novnc --heartbeat 30 0.0.0.0:%(ENV_NOVNC_PORT)s localhost:5901
  ; --web = Serve noVNC web client files from this directory
  ; --heartbeat 30 = Send keepalive every 30 seconds
  ; 0.0.0.0:6080 = Listen on all interfaces (Tailscale will access it)
  ; localhost:5901 = Connect to VNC server
  ; %(ENV_NOVNC_PORT)s = Substitutes NOVNC_PORT environment variable

autostart=true
  ; Always start (core service for browser access)

autorestart=true
  ; Restart on crash

user=lmuser
  ; Run as lmuser (can connect to lmuser's VNC)

stdout_logfile=/var/log/supervisor/novnc-stdout.log
stderr_logfile=/var/log/supervisor/novnc-stderr.log

stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB

priority=30
  ; Start after VNC (priority 20) since it connects to VNC

startsecs=3
  ; Consider started after 3 seconds

depends_on=vnc
  ; Optional: ensures VNC starts before noVNC
  ; Note: This requires supervisor >= 4.0 (Ubuntu 22.04 has 4.2)
EOF

# ---- Ports (documentation — Tailscale exposes these) -------
# 5901 — VNC
# 6080 — noVNC HTTP
# 2222 — SSH (non-privileged port)
EXPOSE 5901 6080 2222

# ---- Container entrypoint -----------------------------------
# NOTE: We stay as root for supervisord (it manages user switching)
# Individual services (SSH, VNC, noVNC) run as lmuser via supervisord configs
WORKDIR /home/lmuser

ENTRYPOINT ["/home/lmuser/scripts/entrypoint.sh"]
