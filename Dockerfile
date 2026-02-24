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
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

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

# ---- Ports (documentation — Tailscale exposes these) -------
# 5901 — VNC
# 6080 — noVNC HTTP
EXPOSE 5901 6080

USER lmuser
WORKDIR /home/lmuser

ENTRYPOINT ["/home/lmuser/scripts/entrypoint.sh"]
