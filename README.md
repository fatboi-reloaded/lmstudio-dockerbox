# Dockerized LM Studio

Run [LM Studio](https://lmstudio.ai) in a GPU-enabled Docker container with an XFCE desktop, noVNC browser access, and optional SSH, all reachable only through a Tailscale sidecar.

```text
Browser / SSH client on your tailnet
        |
        +--> http://<hostname>:6080/vnc.html
        |
        +--> ssh -p 2222 lmuser@<hostname>
                    |
                    v
  +-----------------------------------------------+
  | Tailscale sidecar (shared network namespace)  |
  |   noVNC :6080 -> VNC :5901                    |
  |   SSH   :2222                                 |
  +---------------------------+-------------------+
                              |
                              v
  +-----------------------------------------------+
  | LM Studio container                           |
  |   supervisord (as lmuser)                     |
  |   XFCE desktop                                |
  |   LM Studio (.deb install, --no-sandbox)      |
  |   NVIDIA GPU passthrough                      |
  +-----------------------------------------------+
```

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker 24+ with Compose v2 | `docker compose version` |
| NVIDIA Container Toolkit | <https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html> |
| Tailscale account and auth key | <https://login.tailscale.com/admin/settings/keys> |

Verify GPU access before using this repo:

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker run --rm --gpus all nvidia/cuda:13.2.0-cudnn-devel-ubuntu24.04 nvidia-smi
```

## Quick Start

```bash
git clone <this-repo> dockerized-lmstudio
cd dockerized-lmstudio
cp .env.example .env
```

Edit `.env` and set at minimum:

- `TS_AUTHKEY`
- `VNC_PASSWORD`

Then build and start:

```bash
docker compose build lmstudio
docker compose up -d
```

Open LM Studio in a browser on your tailnet:

```bash
http://<TS_HOSTNAME>:6080/vnc.html
```

## Build Model

The image is built in two stages:

1. A downloader stage fetches the LM Studio `.deb`.
2. The runtime stage installs that `.deb` into the CUDA/XFCE environment.

`LMS_DEB_SHA512` is optional. If you set it, the build verifies the downloaded package checksum. If you leave it empty, the build prints the SHA-512 and continues.

### Checksum flow

1. Leave `LMS_DEB_SHA512=` empty in `.env`.
2. Run `docker compose build lmstudio`.
3. Note the printed downloaded `.deb` SHA-512.
4. Set `LMS_DEB_SHA512` if you want future builds to enforce that exact artifact.

### Tracking `latest`

By default, the build uses:

- `LMS_VERSION=latest`
- `LMS_DEB_URL=https://lmstudio.ai/download/latest/linux/x64?format=deb`

If the upstream `latest` redirect changes but Docker wants to reuse cache, set a new value for `LMS_REFRESH_TOKEN` and rebuild. Any non-empty changed value is fine.

To pin a release, set both:

- `LMS_VERSION=<version>`
- `LMS_DEB_URL=<versioned .deb URL>`

Then optionally update `LMS_DEB_SHA512` for that exact package.

## Configuration

All settings live in `.env`.

| Variable | Default | Description |
|---|---|---|
| `TS_AUTHKEY` | required | Tailscale auth key |
| `TS_HOSTNAME` | `lmstudio` | Tailscale hostname |
| `TS_EXTRA_ARGS` | `--accept-routes` | Extra `tailscaled` flags |
| `VNC_PASSWORD` | required | VNC password, 6-8 characters |
| `VNC_RESOLUTION` | `1920x1080` | VNC desktop resolution |
| `NOVNC_PORT` | `6080` | noVNC HTTP port inside the shared netns |
| `LMS_VERSION` | `latest` | Label for the LM Studio version you intend to install |
| `LMS_DEB_URL` | latest stable redirect | Download URL for the LM Studio `.deb` |
| `LMS_DEB_SHA512` | empty | Optional SHA-512 for the downloaded `.deb`; enforced only when set |
| `LMS_REFRESH_TOKEN` | empty | Optional cache-busting token for `latest` builds |
| `CUDA_BASE_IMAGE` | `nvidia/cuda:13.2.0-cudnn-devel-ubuntu24.04` | Full NVIDIA CUDA base image reference |
| `SHM_SIZE` | `4gb` | Shared memory for GPU workloads |
| `SSH_PUBLIC_KEY_PATH` | empty | Optional mounted public key for SSH access |

## Access

### Browser

Use noVNC from any device on your tailnet:

```bash
http://<TS_HOSTNAME>:6080/vnc.html
```

### SSH

If `SSH_PUBLIC_KEY_PATH` points to a valid public key, the container enables SSH on port `2222`.

Recommended key type:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/lmstudio_key
```

Set:

```bash
SSH_PUBLIC_KEY_PATH=/home/user/.ssh/lmstudio_key.pub
```

Then rebuild or restart the service:

```bash
docker compose up -d --build
```

Connect with:

```bash
ssh -i ~/.ssh/lmstudio_key -p 2222 lmuser@<TS_HOSTNAME>
```

Notes:

- SSH is key-only. Password auth is disabled.
- Root login is disabled.
- SSH host keys are generated on first start and persisted in the `lmstudio-config` volume under `/home/lmuser/.config/sshd`.

### CLI

The container exposes `lms` on `PATH` for `lmuser` through a wrapper that discovers the installed LM Studio CLI at runtime:

```bash
docker compose exec lmstudio bash -lc 'which lms && lms --help'
```

## Persistent Data

| Volume | Container path | Contents |
|---|---|---|
| `tailscale-state` | `/var/lib/tailscale` | Tailscale identity and state |
| `lmstudio-models` | `/home/lmuser/.cache/lm-studio` | Downloaded models |
| `lmstudio-config` | `/home/lmuser/.config` | LM Studio settings, autostart files, SSH host keys |

Remove everything, including models and persisted config:

```bash
docker compose down -v
```

## Operations

The container uses `supervisord`, but it now runs as `lmuser` and keeps its socket and logs under:

```text
/home/lmuser/.supervisor
```

Examples:

```bash
docker compose exec lmstudio supervisorctl status
docker compose exec lmstudio tail -f /home/lmuser/.supervisor/vnc-stdout.log
docker compose exec lmstudio tail -f /home/lmuser/.supervisor/novnc-stderr.log
docker compose exec lmstudio tail -f /home/lmuser/.supervisor/sshd-stderr.log
```

LM Studio itself is launched through a wrapper script that discovers the installed binary path at runtime and always applies the Electron sandbox-disabling flags required in this container.

## Security Notes

- The `tailscale` sidecar drops all capabilities and only adds back `NET_ADMIN`.
- The `tailscale` sidecar sets `no-new-privileges:true`.
- The `lmstudio` entrypoint starts as `root` to initialize mounted volumes, VNC state, and SSH host keys, then drops to `lmuser` via `gosu` for long-running services.
- `/tmp` in the LM Studio container is backed by `tmpfs`.
- No host ports are published; access is through the Tailscale sidecar's network namespace.
- LM Studio is launched with `--no-sandbox --disable-setuid-sandbox` because Electron sandboxing is not reliable in this containerized desktop setup.

## Troubleshooting

### Build fails asking for `LMS_DEB_SHA512`

Set `LMS_DEB_SHA512` only if you want checksum enforcement. If it is set and the build fails, update it to the SHA-512 printed for the downloaded package.

### noVNC is unreachable

```bash
docker compose logs tailscale
docker compose exec lmstudio supervisorctl status
docker compose exec lmstudio tail -f /home/lmuser/.supervisor/novnc-stdout.log
```

### SSH is unavailable

```bash
docker compose exec lmstudio supervisorctl status
docker compose exec lmstudio tail -f /home/lmuser/.supervisor/sshd-stderr.log
docker compose exec lmstudio ls -l /home/lmuser/.ssh/authorized_keys
```

Confirm `SSH_PUBLIC_KEY_PATH` points to a valid mounted public key and that you are connecting as `lmuser`.

### Blank or broken desktop session

```bash
docker compose exec lmstudio supervisorctl status
docker compose exec lmstudio tail -f /home/lmuser/.supervisor/vnc-stderr.log
```

Try a smaller `VNC_RESOLUTION`, then restart the service:

```bash
docker compose restart lmstudio
```

If LM Studio itself does not launch, inspect the wrapper-discovered paths:

```bash
docker compose exec lmstudio bash -lc 'which lms && lms --help || true'
docker compose exec lmstudio bash -lc 'find /opt /usr -maxdepth 6 \( -name "lm-studio" -o -name "lmstudio" -o -name "lms" \) 2>/dev/null | sort'
```

### GPU not visible

```bash
docker compose exec lmstudio nvidia-smi
```

If that fails, re-check the NVIDIA Container Toolkit installation and Docker runtime configuration on the host.

## Rollback Scope

This hardening pass touched these files:

- `Dockerfile`
- `docker-compose.yml`
- `scripts/entrypoint.sh`
- `.env.example`
- `README.md`

If you need to revert the hardening work, those are the files to review or reset.
