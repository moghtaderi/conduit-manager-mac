# Implementation Plan: Feature Additions from conduit-manager (Linux) to conduit-manager-mac

## Overview

This plan adds 4 major features from the Linux version to macOS:
1. **Improved Health Check** - Enhanced diagnostics
2. **Info & Help Hub** - Multi-page built-in documentation
3. **Live Peers by Country** - Real-time GeoIP traffic monitoring
4. **Multi-Container Support** - Run multiple Conduit instances

Each phase is independent and will be verified before proceeding to the next.

---

## Phase 1: Improved Health Check

### Current State
The macOS version already has a fairly comprehensive `health_check()` function (lines 1667-1867) that checks:
- Docker daemon, container exists/running, restart count
- Network isolation, security hardening, Psiphon connection
- Stats output, data volume, node identity key
- Resource limits, seccomp profile

### Improvements to Add
From Linux version (lines 3836-3984):

1. **Connected Peers Count** - Parse `[STATS]` logs for `Connected:` and `Connecting:` counts
2. **Better Status Messages** - Show actual peer counts in connection status
3. **Uptime Display** - Show how long container has been running

### Implementation Steps

```bash
# Step 1.1: Add peer count extraction to health_check
# Parse: Connected: X, Connecting: Y from [STATS] lines

# Step 1.2: Update "Psiphon connection" check to show peer counts
# Before: "OK (Connected to Psiphon network)"
# After:  "OK (15 peers connected, 3 connecting)"

# Step 1.3: Add container uptime display
# Use: docker inspect --format='{{.State.StartedAt}}' and calculate duration
```

### Verification
```bash
# Run the script and select option 5 (Health Check)
# Verify:
# - Peer counts show correctly when connected
# - "CONNECTING" state shows connecting count
# - Uptime displays in human-readable format
# - All existing checks still work
```

### Files Modified
- `conduit-mac.sh`: Update `health_check()` function

---

## Phase 2: Info & Help Hub

### Current State
Option 8 (Security Settings) shows security info and file locations.
No dedicated help/info section exists.

### Features to Add
From Linux version (lines 3623-3800):

1. **Info Menu** - New sub-menu accessible from main menu
2. **Pages**:
   - How Conduit Works (proxy explanation)
   - Understanding Stats (what the numbers mean)
   - Security & Privacy (what data is shared)
   - About Psiphon (mission and links)

### Implementation Steps

```bash
# Step 2.1: Create show_info_menu() function
# Sub-menu with options 1-5 and 0 to go back

# Step 2.2: Create individual info pages:
# - show_info_how_it_works()
# - show_info_stats()
# - show_info_security()
# - show_info_about()

# Step 2.3: Add menu option "i" to main menu
# Place after existing options, before exit
```

### Menu Structure
```
INFO & HELP
══════════════════════════════════════════════════
  1. 🔌 How Conduit Works
  2. 📊 Understanding the Stats
  3. 🔒 Security & Privacy
  4. 🚀 About Psiphon Conduit
  0. ← Back to Main Menu
```

### Verification
```bash
# Run the script and select option "i"
# Verify:
# - Info menu displays correctly
# - Each sub-page shows appropriate content
# - Can navigate back to main menu
# - Pressing any key returns from info pages
```

### Files Modified
- `conduit-mac.sh`: Add `show_info_menu()` and sub-functions, update main menu

---

## Phase 3: Live Peers by Country

### Current State
No GeoIP or per-country traffic tracking exists.

### Features to Add
From Linux version (lines 2047-2232):

1. **GeoIP Resolution** - Map IPs to countries
2. **Traffic Tracking** - Monitor bytes in/out per country
3. **Live Dashboard** - Real-time updating display

### macOS Adaptations Required

| Linux | macOS Equivalent |
|-------|------------------|
| `tcpdump` | `tcpdump` (requires sudo or sniff permission) |
| `/sys/class/net/*/statistics` | `netstat -ib` or `networksetup` |
| systemd service | launchd plist or background process |
| GeoIP database | MaxMind GeoLite2 or ip-api.com |

### Implementation Steps

```bash
# Step 3.1: Add GeoIP lookup function
# Option A: Use free ip-api.com (rate limited, 45 req/min)
# Option B: Install MaxMind GeoLite2 database via Homebrew

# Step 3.2: Create traffic tracking mechanism
# Parse Docker logs for connection IPs OR
# Use lightweight tcpdump on Docker network interface

# Step 3.3: Create show_peers() function
# - Real-time updating display (15-second refresh)
# - Top 10 countries by traffic
# - Show speed, total bytes, IP count

# Step 3.4: Add menu option for peers view
# Option "p" or include in dashboard
```

### Simplified Approach for macOS
Instead of full tcpdump tracking (requires elevated permissions), we can:
1. Parse Docker logs for peer connection info
2. Use Docker stats for network I/O
3. Cache GeoIP lookups to reduce API calls

### Data Structure
```bash
# ~/.conduit-peers-cache
# Format: IP|COUNTRY|TIMESTAMP
# Example: 1.2.3.4|Iran|1706500000
```

### Verification
```bash
# Run the script and select peers option
# Verify:
# - Countries display with traffic data
# - Refresh works (15-second cycle)
# - Can exit with 'q' key
# - No excessive API calls (check rate limiting)
```

### Files Modified
- `conduit-mac.sh`: Add `show_peers()`, `geo_lookup()`, GeoIP cache functions
- New file: `~/.conduit-geoip-cache` (runtime)

---

## Phase 4: Multi-Container Support

### Current State
Single container: `conduit-mac` with volume `conduit-data`

### Features to Add
From Linux version (lines 922-942, 2937-3194):

1. **Container Naming** - `conduit-mac`, `conduit-mac-2`, `conduit-mac-3`, etc.
2. **Volume Naming** - `conduit-data`, `conduit-data-2`, `conduit-data-3`, etc.
3. **Container Manager** - Add/remove containers dynamically
4. **Per-Container Settings** - Separate max-clients/bandwidth per container

### Implementation Steps

```bash
# Step 4.1: Add configuration for container count
# New config variable: CONTAINER_COUNT (default 1, max 5)
# Update CONFIG_FILE format

# Step 4.2: Create helper functions
# - get_container_name(index) -> "conduit-mac" or "conduit-mac-2"
# - get_volume_name(index) -> "conduit-data" or "conduit-data-2"
# - container_exists(index), container_running(index)

# Step 4.3: Update existing functions to loop over containers
# - smart_start() - start all containers
# - stop_service() - stop all containers
# - view_dashboard() - show stats for all
# - health_check() - check all containers

# Step 4.4: Create container manager menu
# - show_container_manager()
# - Add container (up to 5)
# - Remove container
# - View status of all

# Step 4.5: Update main menu
# Add option "c" for container manager
```

### Configuration Changes
```bash
# ~/.conduit-config additions:
CONTAINER_COUNT=1
# Per-container settings (optional):
MAX_CLIENTS_1=200
MAX_CLIENTS_2=200
BANDWIDTH_1=5
BANDWIDTH_2=5
```

### Menu Addition
```
 Configuration
   ...existing options...
   c. 📦 Manage Containers
```

### Container Manager Sub-Menu
```
CONTAINER MANAGER
══════════════════════════════════════════════════
  Current: 2 containers running

  Container        Status      Clients   Uptime
  ─────────────────────────────────────────────
  conduit-mac      Running     45/200    2h 15m
  conduit-mac-2    Running     38/200    1h 42m

  1. ➕ Add Container (max 5)
  2. ➖ Remove Container
  3. 🔄 Restart All
  4. ⚙️  Per-Container Settings
  0. ← Back
```

### Verification
```bash
# Step 4a: Test with single container (backward compatibility)
# - All existing functions work unchanged
# - Config with CONTAINER_COUNT=1 behaves as before

# Step 4b: Test adding second container
# - Container manager shows both
# - Health check shows both
# - Dashboard shows combined stats
# - Start/stop affects all containers

# Step 4c: Test removing container
# - Properly stops and removes
# - Updates CONTAINER_COUNT
# - Other containers unaffected
```

### Files Modified
- `conduit-mac.sh`: Major updates to support multi-container
- `~/.conduit-config`: New format with container count

---

## Implementation Order & Dependencies

```
Phase 1 (Health Check)     <- No dependencies, safe to start
       ↓
Phase 2 (Info Hub)         <- No dependencies on Phase 1
       ↓
Phase 3 (Live Peers)       <- Benefits from Phase 1 improvements
       ↓
Phase 4 (Multi-Container)  <- Most complex, requires all prior phases stable
```

## Risk Assessment

| Phase | Risk Level | Rollback Strategy |
|-------|------------|-------------------|
| 1 | Low | Revert health_check() function only |
| 2 | Low | Remove info menu and menu entry |
| 3 | Medium | Remove peers functions, may need cleanup of cache files |
| 4 | High | Requires careful testing; keep backup of working script |

## Version Bumping

| Phase | Version | Notes |
|-------|---------|-------|
| 1 | 1.8.0 | Improved health check |
| 2 | 1.9.0 | Info & Help hub |
| 3 | 1.10.0 | Live peers by country |
| 4 | 2.0.0 | Multi-container (major feature) |

---

## Verification Checklist (Per Phase)

### Phase Complete Criteria
- [ ] Feature works as described
- [ ] No regression in existing functionality
- [ ] Script passes `bash -n` syntax check
- [ ] Can start/stop/restart container(s)
- [ ] Dashboard displays correctly
- [ ] Health check passes
- [ ] Menu navigation works
- [ ] User tested the feature

### Ready for Next Phase
- [ ] Changes committed to git
- [ ] Version number bumped
- [ ] README updated if needed
- [ ] User approved to proceed

---

## Notes

### macOS-Specific Considerations
1. **No systemd** - Can't use systemd services for background tracking
2. **tcpdump permissions** - Requires sudo or special entitlements
3. **GeoIP** - May need Homebrew package or use web API
4. **Terminal differences** - Some ANSI codes may render differently

### Preserving Security
All new features must maintain the existing security model:
- Bridge networking (not host mode)
- Read-only filesystem
- Dropped capabilities
- Resource limits
- Seccomp profile

### Backward Compatibility
- Existing single-container setups must continue working
- Config file format changes must handle missing values gracefully
- No breaking changes to CLI behavior
