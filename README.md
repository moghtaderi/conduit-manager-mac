<h1 align="center">
  <img src="https://img.shields.io/badge/🛡️-Security_Hardened-green?style=for-the-badge" alt="Security Hardened">
</h1>

<h1 align="center">Psiphon Conduit Manager</h1>
<p align="center"><strong>macOS Edition • v2.1.1</strong></p>

<p align="center">
  <b>Help people in censored regions access the free internet.</b><br>
  Run a <a href="https://conduit.psiphon.ca/">Psiphon Conduit</a> proxy node safely on your Mac.
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> •
  <a href="#security">Security</a> •
  <a href="#features">Features</a> •
  <a href="#فارسی">فارسی</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-blue?style=flat-square" alt="macOS">
  <img src="https://img.shields.io/badge/requires-Docker-2496ED?style=flat-square&logo=docker&logoColor=white" alt="Docker">
  <img src="https://img.shields.io/github/v/release/moghtaderi/conduit-manager-mac?style=flat-square&color=green" alt="Release">
  <img src="https://img.shields.io/badge/containers-up_to_5-orange?style=flat-square" alt="Multi-container">
</p>

---

<h2 align="center">📊 Dashboard</h2>

<p align="center">
  <img src="assets/dashboard.png" alt="Conduit Dashboard" width="420">
</p>

<p align="center">
  <em>Real-time stats, per-container controls, Node IDs, QR codes for rewards</em>
</p>

---

## ⚡ Quick Start

### 1. Install Docker Desktop
Download from **[docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/)**

### 2. Install Conduit Manager
```bash
curl -fsSL https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/install.sh | bash
```

### 3. Run & Configure
```bash
~/conduit-manager/conduit-mac.sh
```
Press `7` → Set limits • Press `6` → Install • Press `m` → Open Menu Bar App

**Done!** Your node is now helping people access the free internet.

---

## 🛡️ Security

<table>
<tr>
<td width="50%">

### Your Mac is Fully Protected

Running Conduit in Docker provides **complete isolation** from your system:

| Protection | What it means |
|:----------:|---------------|
| 🔒 **Read-only filesystem** | Container cannot write to your disk |
| 🌐 **Isolated network** | No access to your local network or other apps |
| ⬇️ **Dropped capabilities** | Minimal Linux privileges (CAP_DROP=ALL) |
| 📊 **Resource limits** | CPU & RAM are capped to your settings |
| 🛑 **Seccomp filtering** | Dangerous system calls are blocked |
| 🚫 **No privilege escalation** | Cannot gain root access |

</td>
<td width="50%">

### v2.1.1 Security Updates

- ✅ **AppleScript injection** protection
- ✅ **Path traversal** prevention in backup/restore
- ✅ **Private keys** cleared from memory after use
- ✅ **Update verification** with content validation
- ✅ **Image digest** verification (supply chain security)

### Why Docker?

Docker containers run in a **sandbox** - even if the Conduit software were compromised, it cannot:
- Access your files
- See your network traffic
- Install anything on your Mac
- Persist after container removal

</td>
</tr>
</table>

---

## 🖥️ Native macOS Apps

<table>
<tr>
<td width="50%" align="center">

### Menu Bar App
<img src="assets/menu-bar-app.png" alt="Menu Bar" width="280">

*Quick status at a glance*

</td>
<td width="50%" align="center">

### Terminal CLI
<img src="assets/cli-dashboard.png" alt="CLI" width="280">

*Full control & configuration*

</td>
</tr>
</table>

---

## ✨ Features

| Feature | Description |
|:-------:|-------------|
| **Multi-Container** | Run up to 5 Conduit nodes simultaneously |
| **Dashboard Window** | Full stats with Node IDs and QR codes |
| **Menu Bar App** | Native macOS - see status instantly |
| **Live Stats** | Connected clients & traffic in real-time |
| **QR Codes** | Scan to claim rewards in Ryve app |
| **Backup & Restore** | Never lose your Node ID |
| **Auto-Updates** | One-click updates with verification |
| **Start at Login** | Runs automatically in background |

---

## 🔧 Menu Bar Icons

| Icon | Meaning |
|:----:|---------|
| 📡 (green) | Conduit is **running** |
| 📡 (slashed) | Conduit is **stopped** |
| ⚠️ (warning) | Docker is **not running** |

### Start at Login
System Settings → General → Login Items → Add `Conduit-Mac.app`

---

## 📦 Multi-Container Setup

Run multiple nodes for increased contribution:

```
Container Manager (option 9 in CLI)
═══════════════════════════════════
  Current: 3/5 containers

  NAME              STATUS     CLIENTS
  conduit-mac       Running    33
  conduit-mac-2     Running    13
  conduit-mac-3     Running    9
```

Each container has its own Node ID, settings, and rewards tracking.

---

## ❓ FAQ

**Will updating lose my Node ID?**
> No. Updates only replace the app. Your Node ID is stored in a Docker volume which is preserved.

**How do I backup my Node ID?**
> Press `b` in the CLI menu. Backups go to `~/.conduit-backups/`

**Is this safe to run?**
> Yes. Docker provides complete isolation. See [Security](#️-security) section.

---

## 🗑️ Uninstall

Press `x` in the CLI menu, or manually:
```bash
docker stop conduit-mac && docker rm conduit-mac
docker volume rm conduit-data && docker network rm conduit-network
rm -rf ~/conduit-manager ~/.conduit-*
```

---

## Credits

- [Psiphon](https://psiphon.ca/) - Psiphon Conduit project
- [SamNet-dev/conduit-manager](https://github.com/SamNet-dev/conduit-manager) - Original Linux script

---

<a id="فارسی"></a>

<div dir="rtl">

## 🇮🇷 نصب برای کاربران ایرانی

### این برنامه کاملاً امن است

برنامه Conduit داخل Docker اجرا می‌شود که یک **محیط ایزوله** است:
- ❌ به فایل‌های شما دسترسی ندارد
- ❌ به شبکه محلی شما دسترسی ندارد
- ❌ نمی‌تواند چیزی روی مک نصب کند
- ✅ فقط به اینترنت برای کمک به دیگران متصل می‌شود

### نصب سریع

**مرحله ۱:** Docker Desktop را از [docker.com](https://www.docker.com/products/docker-desktop/) نصب کنید

**مرحله ۲:** این دستور را در Terminal اجرا کنید:

</div>

```bash
curl -fsSL https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/install.sh | bash
```

<div dir="rtl">

**مرحله ۳:** برنامه را اجرا کنید:

</div>

```bash
~/conduit-manager/conduit-mac.sh
```

<div dir="rtl">

**مرحله ۴:** کلید `7` برای تنظیمات، سپس `6` برای نصب، و `m` برای باز کردن برنامه Menu Bar

</div>

---

<p align="center">
  <img src="assets/iran.png" alt="Conduit Network Map" width="700">
</p>

<h3 align="center">#FreeIran 🕊️</h3>

<p align="center"><em>Every node helps someone access the free internet</em></p>

---

<p align="center">MIT License</p>
