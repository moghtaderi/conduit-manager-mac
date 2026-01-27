# Psiphon Conduit Manager for macOS

Help people in censored regions access the free internet by running a [Psiphon Conduit](https://conduit.psiphon.ca/) proxy node on your Mac.

## Quick Start

### 1. Install Docker Desktop

Download and install from: https://www.docker.com/products/docker-desktop/

### 2. Install Conduit Manager

```bash
curl -fsSL https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/install.sh | bash
```

### 3. Run Initial Setup

```bash
~/conduit-manager/conduit-mac.sh
```

### 4. Recommended Setup Steps

When the menu appears:

1. **Option 7** → Set your CPU/RAM limits (recommended first)
2. **Option 6** → Configure and install the Conduit service
3. **Option m** → Open the Menu Bar App for easy control

That's it! Your Conduit node is now running.

---

## Menu Bar App

After setup, use the menu bar app for quick control:

```bash
open ~/conduit-manager/Conduit.app
```

Features:
- Start/Stop/Restart with one click
- See connected clients and traffic stats
- Works in light and dark mode

**Tip:** Add to Login Items (System Settings → General → Login Items) to start automatically.

---

## CLI Menu Options

| Option | Description |
|--------|-------------|
| **1** | Start / Restart service |
| **2** | Stop service |
| **3** | Live dashboard (real-time stats) |
| **4** | View logs |
| **5** | Health check |
| **6** | Reconfigure (re-install) |
| **7** | Set CPU/RAM limits |
| **8** | Security info |
| **9** | Node identity |
| **b** | Backup node key |
| **r** | Restore node key |
| **u** | Check for updates |
| **m** | Open Menu Bar App |
| **x** | Uninstall |

---

## Uninstall

From the CLI menu, select **x** (Uninstall) and follow the prompts.

Or manually:

```bash
docker stop conduit-mac && docker rm conduit-mac
docker volume rm conduit-data
docker network rm conduit-network
rm -rf ~/conduit-manager ~/.conduit-*
```

---

## Security

The container runs with:
- Read-only filesystem
- Isolated network (no host access)
- Dropped capabilities
- CPU/RAM limits
- Seccomp syscall filtering

Your Mac is protected. The container can only relay proxy traffic.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Docker not running | Open Docker Desktop, wait for it to start |
| Container won't start | Run option **5** (Health Check) to diagnose |
| Resource limits not applying | Use option **6** to recreate the container |

---

## Credits

- [Psiphon](https://psiphon.ca/) - Psiphon Conduit project
- [SamNet-dev/conduit-manager](https://github.com/SamNet-dev/conduit-manager) - Original Linux script

---

## License

MIT
