# ============================================================
# Dockerized LM Studio
#
# Multi-stage: download LM Studio separately, then install it
# into a hardened NVIDIA CUDA runtime with XFCE, noVNC, and SSH.
# ============================================================

ARG CUDA_BASE_IMAGE=nvidia/cuda:13.2.0-cudnn-devel-ubuntu24.04

FROM ubuntu:22.04 AS lmstudio-downloader

ARG DEBIAN_FRONTEND=noninteractive
ARG LMS_VERSION=latest
ARG LMS_DEB_URL=https://lmstudio.ai/download/latest/linux/x64?format=deb
ARG LMS_DEB_SHA512=""
ARG LMS_REFRESH_TOKEN=""

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN echo "Downloading LM Studio ${LMS_VERSION} from: ${LMS_DEB_URL}" \
    && if [ -n "${LMS_REFRESH_TOKEN}" ]; then echo "LM Studio refresh token: ${LMS_REFRESH_TOKEN}"; fi \
    && curl -fsSL --retry 5 --retry-delay 2 --location "${LMS_DEB_URL}" -o /tmp/lmstudio.deb \
    && actual_sha512="$(sha512sum /tmp/lmstudio.deb | awk '{print $1}')" \
    && echo "LM Studio .deb SHA-512: ${actual_sha512}" \
    && if [ -n "${LMS_DEB_SHA512}" ]; then test "${actual_sha512}" = "${LMS_DEB_SHA512}"; else echo "LMS_DEB_SHA512 is empty; skipping checksum enforcement."; fi

FROM ${CUDA_BASE_IMAGE}

LABEL maintainer="dockerized-lmstudio"
LABEL description="LM Studio (GPU) in an XFCE desktop, accessible via noVNC over Tailscale"

ARG DEBIAN_FRONTEND=noninteractive
ARG LMS_VERSION=latest
ARG LMS_DEB_SHA512=""
ARG LMS_DEB_URL=https://lmstudio.ai/download/latest/linux/x64?format=deb
ARG LMS_REFRESH_TOKEN=""

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    VNC_RESOLUTION=1920x1080 \
    VNC_COL_DEPTH=24 \
    VNC_PASSWORD="" \
    LMS_VERSION=${LMS_VERSION} \
    PATH="/home/lmuser/.lmstudio/bin:${PATH}" \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all

RUN if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        grep -q '^Components:.*universe' /etc/apt/sources.list.d/ubuntu.sources || sed -i '/^Components:/ s/$/ universe/' /etc/apt/sources.list.d/ubuntu.sources; \
        grep -q '^Components:.*multiverse' /etc/apt/sources.list.d/ubuntu.sources || sed -i '/^Components:/ s/$/ multiverse/' /etc/apt/sources.list.d/ubuntu.sources; \
    fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    xfce4 \
    xfce4-terminal \
    xfce4-goodies \
    tigervnc-standalone-server \
    tigervnc-common \
    tigervnc-tools \
    novnc \
    websockify \
    libgl1 \
    libgl1-mesa-dri \
    libegl1 \
    libgles2 \
    libgbm1 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libdbus-glib-1-2 \
    libgtk-3-0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libxss1 \
    libxtst6 \
    libxshmfence1 \
    libnss3 \
    libasound2t64 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libxkbcommon0 \
    libxcb-dri3-0 \
    curl \
    ca-certificates \
    dbus-x11 \
    xdg-utils \
    fonts-liberation \
    fonts-noto \
    gosu \
    iproute2 \
    openssh-server \
    python3 \
    supervisor \
    && rm -rf /var/lib/apt/lists/*

COPY --from=lmstudio-downloader /tmp/lmstudio.deb /tmp/lmstudio.deb

RUN echo "Installing LM Studio ${LMS_VERSION} from: ${LMS_DEB_URL}" \
    && apt-get update \
    && apt-get install -y /tmp/lmstudio.deb \
    && rm -f /tmp/lmstudio.deb \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -f render \
    && useradd -m -s /bin/bash lmuser \
    && usermod -aG video,render lmuser

RUN mkdir -p /etc/supervisor/conf.d /etc/supervisor/optional.d \
    /home/lmuser/.cache/lm-studio /home/lmuser/.config/autostart \
    /home/lmuser/.config/sshd /home/lmuser/.lmstudio/bin \
    /home/lmuser/.ssh /home/lmuser/.supervisor /usr/local/bin/lmstudio \
    && chmod 700 /home/lmuser/.ssh \
    && chown -R lmuser:lmuser /home/lmuser

RUN cat > /etc/supervisor/supervisord.conf <<'EOF_SUPERVISOR'
[unix_http_server]
file=/home/lmuser/.supervisor/supervisor.sock
chmod=0700

[supervisord]
nodaemon=true
logfile=/home/lmuser/.supervisor/supervisord.log
pidfile=/home/lmuser/.supervisor/supervisord.pid
childlogdir=/home/lmuser/.supervisor
loglevel=info
logfile_maxbytes=50MB
logfile_backups=10

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///home/lmuser/.supervisor/supervisor.sock

[include]
files = /etc/supervisor/conf.d/*.conf
EOF_SUPERVISOR

RUN mkdir -p /usr/share/applications \
    && cat > /usr/share/applications/lmstudio.desktop <<'EOF_DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=LM Studio
Comment=Run LLMs locally
Exec=/usr/local/bin/lmstudio/lmstudio-launcher %U
Icon=lmstudio
Terminal=false
Categories=Development;AI;
EOF_DESKTOP

RUN mkdir -p /home/lmuser/.lmstudio/bin \
    && echo 'export PATH="/home/lmuser/.lmstudio/bin:$PATH"' >> /home/lmuser/.profile \
    && echo 'export PATH="/home/lmuser/.lmstudio/bin:$PATH"' >> /home/lmuser/.bashrc \
    && chown -R lmuser:lmuser /home/lmuser/.lmstudio /home/lmuser/.profile /home/lmuser/.bashrc

RUN cat > /home/lmuser/.config/sshd/sshd_config <<'EOF_SSHD'
Port 2222
ListenAddress 0.0.0.0
HostKey /home/lmuser/.config/sshd/ssh_host_rsa_key
HostKey /home/lmuser/.config/sshd/ssh_host_ecdsa_key
HostKey /home/lmuser/.config/sshd/ssh_host_ed25519_key
AuthorizedKeysFile /home/lmuser/.ssh/authorized_keys
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
PermitUserEnvironment no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
PidFile /home/lmuser/.config/sshd/sshd.pid
EOF_SSHD

RUN chown -R lmuser:lmuser /home/lmuser/.config/sshd

RUN cat > /etc/supervisor/optional.d/sshd.conf <<'EOF_SSHD_SUP'
[program:sshd]
command=/usr/sbin/sshd -D -f /home/lmuser/.config/sshd/sshd_config -e
autostart=true
autorestart=true
stdout_logfile=/home/lmuser/.supervisor/sshd-stdout.log
stderr_logfile=/home/lmuser/.supervisor/sshd-stderr.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
priority=10
EOF_SSHD_SUP

RUN cat > /etc/supervisor/conf.d/vnc.conf <<'EOF_VNC'
[program:vnc]
command=/usr/bin/vncserver :1 -fg -geometry %(ENV_VNC_RESOLUTION)s -depth %(ENV_VNC_COL_DEPTH)s -SecurityTypes VncAuth -PasswordFile /home/lmuser/.vnc/passwd -localhost no
autostart=true
autorestart=true
user=lmuser
environment=HOME="/home/lmuser",USER="lmuser",DISPLAY=":1",PATH="/home/lmuser/.lmstudio/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
stdout_logfile=/home/lmuser/.supervisor/vnc-stdout.log
stderr_logfile=/home/lmuser/.supervisor/vnc-stderr.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
priority=20
startsecs=5
stopwaitsecs=10
EOF_VNC

RUN cat > /etc/supervisor/conf.d/novnc.conf <<'EOF_NOVNC'
[program:novnc]
command=/usr/bin/websockify --web /usr/share/novnc --heartbeat 30 0.0.0.0:%(ENV_NOVNC_PORT)s localhost:5901
autostart=true
autorestart=true
user=lmuser
stdout_logfile=/home/lmuser/.supervisor/novnc-stdout.log
stderr_logfile=/home/lmuser/.supervisor/novnc-stderr.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
priority=30
startsecs=3
EOF_NOVNC

COPY --chown=root:root scripts/ /usr/local/bin/lmstudio/
RUN chmod 755 /usr/local/bin/lmstudio \
    && chmod +x /usr/local/bin/lmstudio/*

EXPOSE 5901 6080 2222

WORKDIR /home/lmuser

USER root

ENTRYPOINT ["/bin/bash", "/usr/local/bin/lmstudio/entrypoint.sh"]
