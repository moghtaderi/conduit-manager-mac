<h1 align="center">Psiphon Conduit Manager</h1>
<p align="center"><strong>macOS Edition</strong></p>

<p align="center">
  Help people in censored regions access the free internet.<br>
  Run a <a href="https://conduit.psiphon.ca/">Psiphon Conduit</a> proxy node on your Mac.
</p>

<p align="center">
  <a href="#quick-start">English</a> · <a href="#farsi">فارسی</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-blue" alt="macOS">
  <img src="https://img.shields.io/badge/requires-Docker%20Desktop-blue" alt="Docker">
  <img src="https://img.shields.io/github/v/release/moghtaderi/conduit-manager-mac" alt="Release">
</p>

---

## Features

| Feature | Description |
|---------|-------------|
| **Menu Bar App** | Native macOS app - Start/Stop with one click |
| **Live Stats** | See connected clients & traffic in real-time |
| **Security Hardened** | Read-only filesystem, isolated network, seccomp |
| **Docker Status** | Auto-detects if Docker is running |
| **Dark Mode** | Works perfectly in light and dark mode |

---

## Quick Start

### Step 1: Install Docker Desktop

Download from **[docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/)**

### Step 2: Install Conduit Manager

```bash
curl -fsSL https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/install.sh | bash
```

### Step 3: Run Setup

```bash
~/conduit-manager/conduit-mac.sh
```

### Step 4: Configure

| Step | Press | What it does |
|:----:|:-----:|--------------|
| 1 | `7` | Set your CPU & RAM limits |
| 2 | `6` | Install the Conduit service |
| 3 | `m` | Open the Menu Bar App |

**Done!** Your node is now helping people access the free internet.

---

## Menu Bar App

Quick control without opening Terminal:

```
┌─────────────────────────────┐
│ ● Conduit: Running          │
│ Clients: 5 connected        │
│ Traffic: ↑ 1.2 GB  ↓ 3.4 GB │
│ Uptime: ~2h                 │
├─────────────────────────────┤
│ ↻ Restart              ⌘S   │
│ ■ Stop                 ⌘X   │
├─────────────────────────────┤
│ Open Terminal Manager...    │
├─────────────────────────────┤
│ Max Clients: 250            │
│ Bandwidth: 15 Mbps          │
├─────────────────────────────┤
│ Version 1.6.0               │
│ Quit                   ⌘Q   │
└─────────────────────────────┘
```

### Menu Bar Icons

| Icon | Meaning |
|:----:|---------|
| 📡 (green) | Conduit is **running** |
| 📡 (slashed) | Conduit is **stopped** |
| ⚠️ (warning) | Docker is **not running** |

### Start at Login

System Settings → General → Login Items → Add `Conduit-Mac.app`

---

## CLI Menu Options

```
╔═══════════════════════════════════════╗
║      PSIPHON CONDUIT MANAGER          ║
╚═══════════════════════════════════════╝

 Service
   1. ▶️  Start / Restart
   2. ⏹️  Stop Service
   3. 📊 Live Dashboard
   4. 📜 View Logs
   5. 🩺 Health Check

 Configuration
   6. 🛠️  Reconfigure
   7. 📈 Resource Limits
   8. 🔒 Security Settings
   9. 🆔 Node Identity

 Backup & Maintenance
   b. 💾 Backup Key
   r. 📥 Restore Key
   u. 🔄 Check for Updates
   x. 🗑  Uninstall

 Menu Bar App
   m. 🖥  Open Menu Bar App

   0. 🚪 Exit
```

---

## Security

Your Mac is fully protected:

| Protection | What it means |
|------------|---------------|
| Read-only filesystem | Container can't write to your disk |
| Isolated network | No access to your local network |
| Dropped capabilities | Minimal Linux privileges |
| Resource limits | CPU & RAM are capped |
| Seccomp filtering | Dangerous syscalls blocked |

---

## FAQ

### Will updating lose my Node ID?

**No.** Updates only replace the script and menu bar app. Your Node ID is stored in a Docker volume (`conduit-data`) which is preserved during updates.

### What does the Node ID represent?

Your Node ID is a unique cryptographic identifier for your volunteer node. Psiphon uses it to track your node's reputation and contribution history. If you lose it (by uninstalling), you start fresh with a new identity.

### How do I backup my Node ID?

Press `b` in the CLI menu to create a backup. Backups are saved to `~/.conduit-backups/` and can be restored later with `r`.

---

## Uninstall

**Easy way:** Press `x` in the CLI menu

**Manual way:**
```bash
docker stop conduit-mac && docker rm conduit-mac
docker volume rm conduit-data
docker network rm conduit-network
rm -rf ~/conduit-manager ~/.conduit-*
```

---

<div dir="rtl">

<a id="farsi"></a>

## نصب سریع

### مرحله ۱: نصب Docker Desktop

از **[docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/)** دانلود کنید

### مرحله ۲: نصب Conduit Manager

</div>

```bash
curl -fsSL https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/install.sh | bash
```

<div dir="rtl">

### مرحله ۳: اجرای برنامه

</div>

```bash
~/conduit-manager/conduit-mac.sh
```

<div dir="rtl">

### مرحله ۴: پیکربندی

| مرحله | کلید | توضیح |
|:-----:|:----:|-------|
| ۱ | `7` | تنظیم محدودیت CPU و RAM |
| ۲ | `6` | نصب سرویس Conduit |
| ۳ | `m` | باز کردن برنامه Menu Bar |

**تمام!** نود شما اکنون فعال است و به دیگران کمک می‌کند.

---

## برنامه Menu Bar

کنترل سریع بدون نیاز به Terminal:

</div>

```
┌─────────────────────────────┐
│ ● Conduit: Running          │
│ Clients: 5 connected        │
│ Traffic: ↑ 1.2 GB  ↓ 3.4 GB │
├─────────────────────────────┤
│ ↻ Restart                   │
│ ■ Stop                      │
├─────────────────────────────┤
│ Max Clients: 250            │
│ Bandwidth: 15 Mbps          │
└─────────────────────────────┘
```

<div dir="rtl">

### آیکون‌های Menu Bar

| آیکون | معنی |
|:-----:|------|
| 📡 (سبز) | Conduit **در حال اجراست** |
| 📡 (خط‌خورده) | Conduit **متوقف است** |
| ⚠️ (هشدار) | Docker **اجرا نیست** |

---

## امنیت

مک شما کاملاً محافظت شده است:

| محافظت | توضیح |
|--------|-------|
| فایل‌سیستم فقط‌خواندنی | کانتینر نمی‌تواند روی دیسک بنویسد |
| شبکه ایزوله | دسترسی به شبکه محلی ندارد |
| امتیازات محدود | حداقل دسترسی‌های لینوکس |
| محدودیت منابع | CPU و RAM محدود شده |

---

## حذف برنامه

**روش آسان:** در منوی CLI کلید `x` را بزنید

**روش دستی:**

</div>

```bash
docker stop conduit-mac && docker rm conduit-mac
docker volume rm conduit-data
docker network rm conduit-network
rm -rf ~/conduit-manager ~/.conduit-*
```

---

## Credits

- [Psiphon](https://psiphon.ca/) - Psiphon Conduit project
- [SamNet-dev/conduit-manager](https://github.com/SamNet-dev/conduit-manager) - Original Linux script

## License

MIT
