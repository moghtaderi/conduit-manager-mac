# Psiphon Conduit Manager for macOS

A **security-hardened** management tool for deploying [Psiphon Conduit](https://conduit.psiphon.ca/) proxy nodes on **macOS** using **Docker Desktop**.

Psiphon Conduit allows you to donate your bandwidth to help people in censored regions access the free and open internet.

---

## Features

- **macOS-Optimized**: Clean terminal UI designed for macOS
- **Security-Hardened**: Container isolation, privilege dropping, seccomp filtering, resource limits
- **Smart Management**: Auto-detects service state and resource limit changes
- **Live Dashboard**: Real-time CPU, RAM, traffic, and connection stats
- **Health Check**: Comprehensive 12-point system diagnostics
- **Backup/Restore**: Preserve your node identity across reinstalls
- **Auto-Update**: One-click updates from the repository
- **Resource Control**: User-configurable CPU and RAM limits
- **Docker Auto-Start**: Automatically starts Docker Desktop if not running
- **Seccomp Filtering**: Custom syscall restrictions for enhanced security
- **Menu Bar App**: Optional SwiftUI menu bar companion (beta)

---

## Prerequisites

### Docker Desktop for macOS

1. Download from: https://www.docker.com/products/docker-desktop/
2. Install and open Docker Desktop
3. Wait for Docker to fully start (whale icon stops animating)

> **Note**: This tool runs Psiphon Conduit inside a Docker container, so Docker Desktop is required. The script will automatically detect if Docker Desktop is not installed and guide you through installation. If Docker Desktop is installed but not running, the script will attempt to start it automatically.

---

## Quick Install

### One-Line Installer (Recommended)

```bash
curl -sL https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/install.sh | bash
```

This will:
- Check for Docker Desktop (guide through installation if missing)
- Download the script to `~/conduit-manager/`
- Create a `conduit` command alias (if possible)
- Create the seccomp security profile
- Offer to launch immediately

### Manual Install

```bash
# Download the script
curl -L -o conduit-mac.sh https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/conduit-mac.sh

# Make executable
chmod +x conduit-mac.sh

# Run
./conduit-mac.sh
```

### Homebrew (Coming Soon)

```bash
brew tap moghtaderi/conduit-manager-mac
brew install conduit-mac
```

---

## Testing from Scratch

To test a completely fresh installation:

### 1. Complete Removal (if previously installed)

```bash
# Stop and remove the container
docker stop conduit-mac 2>/dev/null
docker rm conduit-mac 2>/dev/null

# Remove Docker resources
docker volume rm conduit-data 2>/dev/null
docker network rm conduit-network 2>/dev/null
docker rmi psiphon/conduit 2>/dev/null

# Remove configuration files
rm -f ~/.conduit-config
rm -f ~/.conduit-manager.log
rm -f ~/.conduit-seccomp.json

# Remove installation directory
rm -rf ~/conduit-manager

# Remove symlink (if created)
rm -f /usr/local/bin/conduit 2>/dev/null
rm -f ~/bin/conduit 2>/dev/null

# Optional: Remove backups (only if you don't need them)
# rm -rf ~/.conduit-backups
```

### 2. Verify Clean State

```bash
# Check nothing remains
docker ps -a | grep conduit    # Should show nothing
docker volume ls | grep conduit # Should show nothing
ls ~/.conduit-*                 # Should show "No such file"
ls ~/conduit-manager            # Should show "No such file"
```

### 3. Fresh Install

```bash
# Run the one-line installer
curl -sL https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/install.sh | bash
```

### 4. Verify Installation

1. Select option **1** (Start/Restart) from the menu
2. Wait for the container to start
3. Select option **5** (Health Check) to verify all systems
4. Select option **3** (Live Dashboard) to see stats

All health check items should show green checkmarks (✓).

---

## Complete Removal

### Using the Script (Recommended)

1. Run the script: `./conduit-mac.sh` or `conduit`
2. Select option **x** (Uninstall)
3. Confirm the uninstallation
4. Choose whether to keep backup keys

### Manual Removal

If the script is unavailable or you want complete manual control:

```bash
# 1. Stop and remove the Docker container
docker stop conduit-mac
docker rm conduit-mac

# 2. Remove Docker volume (contains node identity)
docker volume rm conduit-data

# 3. Remove Docker network
docker network rm conduit-network

# 4. Remove Docker image
docker rmi psiphon/conduit

# 5. Remove configuration files
rm -f ~/.conduit-config
rm -f ~/.conduit-manager.log
rm -f ~/.conduit-seccomp.json

# 6. Remove installation directory
rm -rf ~/conduit-manager

# 7. Remove command alias/symlink
rm -f /usr/local/bin/conduit 2>/dev/null
rm -f ~/bin/conduit 2>/dev/null

# 8. (Optional) Remove backup keys
# WARNING: This permanently deletes your node identity backups!
rm -rf ~/.conduit-backups
```

### What Gets Removed

| Item | Location | Purpose |
|------|----------|---------|
| Container | `conduit-mac` | The running Conduit service |
| Volume | `conduit-data` | Node identity (`conduit_key.json`) |
| Network | `conduit-network` | Isolated bridge network |
| Image | `psiphon/conduit` | The Conduit Docker image |
| Config | `~/.conduit-config` | User settings (CPU/RAM limits) |
| Log | `~/.conduit-manager.log` | Operation log |
| Seccomp | `~/.conduit-seccomp.json` | Syscall filter profile |
| Script | `~/conduit-manager/` | Installation directory |
| Alias | `/usr/local/bin/conduit` | Command shortcut |
| Backups | `~/.conduit-backups/` | Node identity backups (optional) |

---

## Security Model

This script implements comprehensive container security hardening. The goal is to ensure the Docker container **cannot affect your Mac** except for explicitly allowed network traffic.

### Container Isolation Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                         YOUR MAC (HOST)                         │
├─────────────────────────────────────────────────────────────────┤
│  Filesystem: PROTECTED - Container has NO access                │
│  Network:    PROTECTED - Container uses isolated bridge         │
│  Memory:     PROTECTED - Container capped at configured limit   │
│  CPU:        PROTECTED - Container capped at configured cores   │
│  Syscalls:   PROTECTED - Seccomp profile restricts operations   │
└─────────────────────────────────────────────────────────────────┘
         │
         │ Only allowed communication:
         │   - Outbound internet (for proxy function)
         │   - Docker volume for node identity storage
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    DOCKER CONTAINER (ISOLATED)                  │
├─────────────────────────────────────────────────────────────────┤
│  Read-only filesystem (cannot write except /tmp)                │
│  All capabilities dropped (minimal privileges)                  │
│  Cannot escalate to root                                        │
│  Process count limited (prevents fork bombs)                    │
│  Syscalls filtered via seccomp profile                          │
└─────────────────────────────────────────────────────────────────┘
```

### What the Container CAN Access

| Access | Description | Reason |
|--------|-------------|--------|
| **Outbound Internet** | Container can reach external servers | Required for proxy relay function |
| **Docker Volume** | Persistent storage for node identity | Stores `conduit_key.json` (your node ID) |
| **Tmpfs /tmp** | 100MB temporary in-memory storage | Runtime scratch space, cleared on stop |

### What the Container CANNOT Access

| Blocked | How It's Blocked |
|---------|------------------|
| **Host Filesystem** | No volume mounts to host paths |
| **Host Network** | Uses isolated bridge network, not `--network host` |
| **Other Containers** | Isolated in its own network namespace |
| **Privilege Escalation** | `--security-opt no-new-privileges:true` |
| **Linux Capabilities** | `--cap-drop ALL` (only NET_BIND_SERVICE allowed) |
| **Container Writes** | `--read-only` filesystem |
| **Unlimited Resources** | Memory, CPU, and PID limits enforced |
| **Host Processes** | Cannot see or interact with Mac processes |
| **Dangerous Syscalls** | Seccomp profile restricts system calls |

### Security Flags Used

The container is started with these security hardening flags:

```bash
docker run \
    --read-only \                              # Filesystem is read-only
    --tmpfs /tmp:rw,noexec,nosuid,size=100m \  # Limited writable /tmp
    --security-opt no-new-privileges:true \    # Cannot escalate privileges
    --security-opt seccomp=~/.conduit-seccomp.json \  # Syscall filtering
    --cap-drop ALL \                           # Drop all Linux capabilities
    --cap-add NET_BIND_SERVICE \               # Allow binding low ports only
    --memory 2g \                              # RAM limit (configurable)
    --cpus 2 \                                 # CPU limit (configurable)
    --memory-swap 2g \                         # Prevent swap abuse
    --pids-limit 100 \                         # Prevent fork bombs
    --network conduit-network \                # Isolated bridge network
    ...
```

### Seccomp Profile

A custom seccomp (secure computing) profile is automatically created at `~/.conduit-seccomp.json`. This profile:

- Uses a whitelist approach (only allows specific syscalls)
- Permits ~90 syscalls required for network proxy operations
- Blocks all other syscalls by default
- Prevents container escape techniques
- Restricts kernel interactions

The profile is created on first run and used for all container starts.

### Image Verification

The script verifies the Docker image using SHA256 digest comparison before running:

```
Expected: sha256:a7c3acdc9ff4b5a2077a983765f0ac905ad11571321c61715181b1cf616379ca
```

If the digest doesn't match (indicating a potentially compromised or updated image), you'll be warned and asked to confirm before proceeding.

---

## Menu Options

| Option | Function |
|--------|----------|
| **1. Start/Restart** | Smart install (if new), start (if stopped), restart, or apply new resource limits |
| **2. Stop Service** | Gracefully stop the container |
| **3. Live Dashboard** | Real-time stats with auto-refresh |
| **4. View Logs** | Stream container logs |
| **5. Health Check** | Comprehensive 12-point system diagnostics |
| **6. Reconfigure** | Reinstall with new settings (offers backup restore) |
| **7. Resource Limits** | Configure CPU and RAM limits |
| **8. Security Settings** | View security configuration details |
| **9. Node Identity** | View your unique node ID |
| **b. Backup Key** | Save node identity to file |
| **r. Restore Key** | Restore identity from backup |
| **u. Check Updates** | Auto-update from GitHub |
| **x. Uninstall** | Remove all Conduit data and containers |

---

## Health Check

The health check (option 5) performs comprehensive 12-point diagnostics:

| Check | Description |
|-------|-------------|
| Docker daemon | Is Docker running? |
| Container exists | Has the container been created? |
| Container running | Is the container currently active? |
| Restart count | Has the container crashed repeatedly? |
| Network isolation | Is the container using isolated bridge networking? |
| Security hardening | Are security options (no-new-privileges, read-only) applied? |
| Seccomp profile | Is syscall filtering enabled? |
| Psiphon connection | Is the proxy connected to Psiphon network? |
| Stats output | Is verbose logging enabled? |
| Data volume | Does the persistent volume exist? |
| Node identity | Has the node key been generated? |
| Resource limits | Are CPU/RAM limits configured and applied? |

### Health Check Output

```
╔═══════════════════════════════════════════════════════════════╗
║                        HEALTH CHECK                           ║
╚═══════════════════════════════════════════════════════════════╝

 ✓ Docker daemon running
 ✓ Container exists
 ✓ Container is running
 ✓ Restart count: 0 (healthy)
 ✓ Network isolation: bridge network
 ✓ Security hardening: enabled
 ✓ Seccomp profile: active
 ✓ Psiphon connection: established
 ✓ Stats output: enabled
 ✓ Data volume: exists
 ✓ Node identity: present
 ✓ Resource limits: 2 CPU / 2 GB RAM

═══════════════════════════════════════════════════════════════
Overall: 12/12 checks passed
```

---

## Configuration

### Initial Setup

When first installing, you'll be prompted for:

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| **Max Clients** | Based on CPU | 1-2000 | Maximum concurrent proxy connections |
| **Bandwidth** | 5 Mbps | 1-1000 or -1 | Per-connection speed limit (-1 = unlimited) |

### Resource Limits

Access via menu option **7** to configure:

| Setting | Default | Description |
|---------|---------|-------------|
| **Memory** | 2 GB | Maximum RAM the container can use |
| **CPU** | 2 cores | Maximum CPU cores available to container |

These limits are saved to `~/.conduit-config` and persist across restarts.

**Note**: When you change resource limits, the container must be recreated (not just restarted) for changes to take effect. The script handles this automatically.

---

## Hardware Recommendations

| Mac Type | Recommended Max Clients |
|----------|------------------------|
| **Apple Silicon (M1/M2/M3/M4)** | 400-800+ clients |
| **Intel Mac** | 200-400 clients |

The script automatically calculates a recommended value based on your CPU cores.

---

## Node Identity & Backup

Your node has a unique identity stored in `conduit_key.json`. This key:

- Identifies your node on the Psiphon network
- Should be backed up before uninstalling
- Can be restored to resume your node identity

### Backup Location

Backups are saved to: `~/.conduit-backups/`

### Backup Commands

- **Backup**: Menu option `b`
- **Restore**: Menu option `r`

### Backup File Format

```
conduit-backup-2024-01-15_143022.json
```

---

## File Locations

| File | Purpose |
|------|---------|
| `~/conduit-manager/conduit-mac.sh` | Main script (one-line installer location) |
| `~/.conduit-config` | User configuration (resource limits) |
| `~/.conduit-manager.log` | Operation log file |
| `~/.conduit-backups/` | Node identity backups |
| `~/.conduit-seccomp.json` | Seccomp syscall filter profile |
| Docker volume `conduit-data` | Container's persistent data |

---

## Menu Bar App (Beta)

An optional SwiftUI menu bar companion app is available for quick access to Conduit controls.

### Features

- Status indicator (running/stopped)
- Quick start/stop controls
- Node ID display and copy
- Connected clients count
- Open terminal dashboard

### Building

```bash
cd ConduitMenuBar
swift build -c release
```

### Note

The menu bar app requires the main `conduit-mac.sh` script to be installed. It provides a convenient GUI overlay but uses the same Docker container.

---

## Troubleshooting

### "Docker is not running"

The script will attempt to start Docker Desktop automatically. If it fails:

1. Open Docker Desktop from Applications manually
2. Wait for the whale icon to stop animating
3. Run the script again

### "Docker Desktop not installed"

The script will detect this and offer to open the download page:

1. Visit https://www.docker.com/products/docker-desktop/
2. Download and install Docker Desktop
3. Run the script again

### Container won't start

Check the log file: `~/.conduit-manager.log`

Common issues:
- Docker Desktop needs more memory allocated
- Previous container didn't clean up (try Uninstall then reinstall)
- Port conflicts with other services

### Node ID not showing

The node ID is generated on first start. If it's missing:
1. Make sure the container has run at least once
2. Check that the `conduit-data` volume exists: `docker volume ls`

### Health check shows failures

Run the health check (option 5) and address each failed item:

| Failure | Solution |
|---------|----------|
| Docker daemon not running | Start Docker Desktop |
| Container not running | Use option 1 to start |
| High restart count | Check logs for crash reason |
| No network isolation | Recreate container (option 6) |
| Security not enabled | Recreate container (option 6) |
| No Psiphon connection | Check internet, wait for connection |

### Resource limits not applying

If you change resource limits but they don't apply:
1. The script should automatically recreate the container
2. If not, use option 6 (Reconfigure) to force recreation
3. Verify with option 5 (Health Check)

---

## Updating

### Automatic Update

1. Select option `u` from the main menu
2. If a new version is available, confirm the update
3. Script will download, verify, and restart automatically

### Manual Update

```bash
curl -L -o conduit-mac.sh https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/conduit-mac.sh
chmod +x conduit-mac.sh
```

---

## License

MIT License

---

## Credits

- [Psiphon](https://psiphon.ca/) - The Psiphon Conduit project
- Original script: [polamgh/conduit-manager-mac](https://github.com/polamgh/conduit-manager-mac)
- Security hardening: This fork

---

## Contributing

Issues and pull requests welcome at: https://github.com/moghtaderi/conduit-manager-mac

---

<div dir="rtl">

# مدیریت کاندوییت سایفون (نسخه macOS)

یک ابزار **امن و حرفه‌ای** برای راه‌اندازی نودهای [Psiphon Conduit](https://conduit.psiphon.ca/) روی **macOS** با استفاده از **Docker Desktop**.

سایفون کاندوییت به شما امکان می‌دهد پهنای باند خود را برای کمک به افرادی که در مناطق سانسور شده هستند، اهدا کنید.

---

## پیش‌نیازها

### Docker Desktop برای macOS

1. دانلود از: https://www.docker.com/products/docker-desktop/
2. نصب و اجرای Docker Desktop
3. صبر کنید تا Docker کاملاً راه‌اندازی شود

---

## نصب سریع

### نصب تک‌خطی (پیشنهادی)

```bash
curl -sL https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/install.sh | bash
```

### نصب دستی

در **Terminal** اجرا کنید:

```bash
# دانلود اسکریپت
curl -L -o conduit-mac.sh https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/conduit-mac.sh

# دادن دسترسی اجرا
chmod +x conduit-mac.sh

# اجرا
./conduit-mac.sh
```

---

## ویژگی‌های امنیتی

این اسکریپت شامل تنظیمات امنیتی جامع است:

- **شبکه ایزوله**: کانتینر به شبکه میزبان دسترسی ندارد
- **فایل‌سیستم فقط خواندنی**: کانتینر نمی‌تواند فایل بنویسد
- **محدودیت منابع**: CPU و RAM محدود شده
- **بدون افزایش امتیاز**: کانتینر نمی‌تواند root شود
- **تأیید هویت تصویر**: بررسی SHA256 قبل از اجرا
- **فیلتر Seccomp**: محدودیت فراخوانی‌های سیستمی

---

## حذف کامل

برای حذف کامل:

```bash
# توقف و حذف کانتینر
docker stop conduit-mac
docker rm conduit-mac

# حذف volume
docker volume rm conduit-data

# حذف شبکه
docker network rm conduit-network

# حذف image
docker rmi psiphon/conduit

# حذف فایل‌های تنظیمات
rm -f ~/.conduit-config
rm -f ~/.conduit-manager.log
rm -f ~/.conduit-seccomp.json
rm -rf ~/conduit-manager

# اختیاری: حذف پشتیبان‌ها
# rm -rf ~/.conduit-backups
```

---

## تنظیمات پیش‌فرض

| تنظیم | مقدار پیش‌فرض |
|------|---------------|
| حداکثر کاربران | بر اساس CPU |
| پهنای باند | 5 Mbps |
| حافظه | 2 GB |
| CPU | 2 هسته |

---

## پشتیبان‌گیری

کلید هویت نود شما در `~/.conduit-backups/` ذخیره می‌شود.

قبل از حذف نصب، حتماً از کلید خود پشتیبان بگیرید!

</div>
