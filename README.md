# Dockerized LM Studio

Run [LM Studio](https://lmstudio.ai) in a GPU-accelerated Docker container, accessible from anywhere on your private Tailscale network via a browser (noVNC).

```
Browser (any device on Tailnet)
        │
        ▼  http://<hostname>:6080/vnc.html
  ┌─────────────────────────────────┐
  │  Tailscale sidecar              │  ← auth via TS_AUTHKEY
  │  (shared network namespace)     │
  │         │                       │
  │  noVNC :6080  ──→  VNC :5901    │
  │  SSH   :2222 (key auth, no root)│
  │                       │         │
  │              XFCE desktop       │
  │                       │         │
  │              LM Studio          │
  │                (AppImage)       │
  │                       │         │
  │              NVIDIA GPU         │
  └─────────────────────────────────┘
```

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker ≥ 24 + Compose v2 | `docker compose version` |
| [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) | `nvidia-ctk --version` |
| Tailscale account + auth key | <https://login.tailscale.com/admin/settings/keys> |

### Verify NVIDIA runtime is configured

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker run --rm --gpus all nvidia/cuda:12.3.1-base-ubuntu22.04 nvidia-smi
```

## Quick start

```bash
# 1. Clone and enter the repo
git clone <this-repo> dockerized-lmstudio
cd dockerized-lmstudio

# 2. Create your .env
cp .env.example .env
# Edit .env — set TS_AUTHKEY and VNC_PASSWORD at minimum

# 3. Build and start
docker compose up -d --build

# 4. Open LM Studio in your browser
#    (replace 'lmstudio' with your TS_HOSTNAME)
open http://lmstudio:6080/vnc.html
```

## Configuration

All settings live in `.env` (never committed — see `.env.example`).

| Variable | Default | Description |
|---|---|---|
| `TS_AUTHKEY` | **required** | Tailscale auth key |
| `TS_HOSTNAME` | `lmstudio` | Node name on your tailnet |
| `VNC_PASSWORD` | **required** | Browser VNC password (6-8 chars) |
| `VNC_RESOLUTION` | `1920x1080` | Desktop resolution |
| `SSH_PUBLIC_KEY_PATH` | *(empty)* | Path to SSH public key for key-based auth |
| `LMS_VERSION` | `0.3.9` | LM Studio version to embed |
| `CUDA_VERSION` | `12.3.1` | NVIDIA CUDA base image version |

## SSH Access

You can connect to the container via SSH using key-based authentication:

1. **Generate an SSH key pair** (if you don't have one):
   ```bash
   ssh-keygen -t rsa -b 4096 -f ~/.ssh/lmstudio_key
   ```

2. **Set the public key path in `.env`**:
   ```bash
   SSH_PUBLIC_KEY_PATH=/home/user/.ssh/lmstudio_key.pub
   ```

3. **Rebuild and restart the container**:
   ```bash
   docker compose up -d --build
   ```

4. **Connect via SSH** (replace `lmstudio` with your `TS_HOSTNAME`):
   ```bash
   ssh -i ~/.ssh/lmstudio_key -p 2222 lmuser@lmstudio
   ```
   
   **Important:** 
   - You must connect as user `lmuser` (not your local username)
   - You must specify your private key with `-i`
   - Use port `2222` (not the default port 22)

**Security notes:**
- SSH runs on port **2222** (non-privileged) as user `lmuser` - no root access
- Only accessible through your Tailscale network
- Password authentication is disabled (key-based only)

## Updating LM Studio

Change `LMS_VERSION` in `.env` (and optionally `LMS_APPIMAGE_URL` if the download URL pattern changed), then rebuild:

```bash
docker compose build --no-cache lmstudio
docker compose up -d lmstudio
```

## Persistent data

| Volume | Container path | Contents |
|---|---|---|
| `lmstudio-models` | `/home/lmuser/.cache/lm-studio` | Downloaded models |
| `lmstudio-config` | `/home/lmuser/.config/LM Studio` | App settings |
| `tailscale-state` | `/var/lib/tailscale` | Tailscale node state |

Models survive `docker compose down`. To **also** remove them: `docker compose down -v`.

## Architecture notes

- **Tailscale sidecar** — the `lmstudio` container uses `network_mode: service:tailscale`, meaning it shares the Tailscale container's network namespace. Port 6080 (noVNC) is reachable *only* via your tailnet — it is never bound to a host port.
- **Multi-stage Dockerfile** — stage 1 downloads and extracts the LM Studio AppImage (avoiding FUSE at runtime); stage 2 is the lean CUDA + XFCE + VNC runtime.
- **noVNC** — browser-based VNC client served over HTTP on port 6080. VNC password is required.
- **GPU passthrough** — uses Docker Compose's `deploy.resources.reservations.devices` syntax. Requires `nvidia-container-toolkit`.

## Troubleshooting

**Container exits immediately:**
```bash
docker compose logs lmstudio
```

**VNC blank screen:**
- Check `VNC_RESOLUTION` is supported by your display.
- Try a smaller resolution, e.g. `1280x720`.

**GPU not visible inside container:**
```bash
docker compose exec lmstudio nvidia-smi
```
If this fails, verify `nvidia-container-toolkit` is installed and Docker daemon is using the NVIDIA runtime.

**Tailscale not connecting:**
```bash
docker compose logs tailscale
docker compose exec tailscale tailscale status
```
Ensure your `TS_AUTHKEY` is valid and not expired.

**LM Studio AppImage download fails during build:**
Check the `LMS_APPIMAGE_URL` in your `.env` / compose args. The URL pattern can change between releases. Find the correct URL at <https://lmstudio.ai/download>.
