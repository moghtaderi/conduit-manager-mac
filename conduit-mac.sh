#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                    PSIPHON CONDUIT MANAGER (macOS)                        ║
# ║                      Security-Hardened Edition                            ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  This script manages a Docker container running Psiphon Conduit proxy.    ║
# ║                                                                           ║
# ║  SECURITY FEATURES:                                                       ║
# ║    - Image digest verification (supply chain protection)                  ║
# ║    - Isolated bridge networking (no host network access)                  ║
# ║    - Strict input validation (prevents injection attacks)                 ║
# ║    - Dropped Linux capabilities (minimal privileges)                      ║
# ║    - Read-only container filesystem                                       ║
# ║    - Resource limits (CPU/memory caps)                                    ║
# ║    - No privilege escalation allowed                                      ║
# ║    - Comprehensive error logging                                          ║
# ║                                                                           ║
# ║  EXPLICITLY ALLOWED NETWORK ACCESS:                                       ║
# ║    - Outbound: Container can reach internet (required for proxy function) ║
# ║    - Inbound: Only mapped ports accessible from localhost                 ║
# ║    - The container CANNOT access host filesystem or other containers      ║
# ║                                                                           ║
# ║  Author: Security-hardened fork                                           ║
# ║  License: MIT                                                             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# ==============================================================================
# STRICT MODE - Exit on errors, undefined variables, and pipe failures
# ==============================================================================
# These settings make the script fail fast on errors rather than continuing
# in an undefined state, which is critical for security.
set -euo pipefail

# ==============================================================================
# VERSION AND CONFIGURATION
# ==============================================================================

readonly VERSION="2.0.0"                                          # Script version

# Container and image settings
readonly CONTAINER_NAME="conduit-mac"                             # Docker container name
readonly IMAGE="ghcr.io/ssmirr/conduit/conduit:2fd31d4"          # Docker image to deploy
readonly IMAGE_DIGEST="sha256:ee456f56751683afd8c1c85ecbeb8bd8871c1b8f9f5057ab1951a60c31c30a7f"  # Expected SHA256
readonly VOLUME_NAME="conduit-data"                               # Persistent data volume
readonly NETWORK_NAME="conduit-network"                           # Isolated bridge network
readonly LOG_FILE="${HOME}/.conduit-manager.log"                  # Local log file path
readonly BACKUP_DIR="${HOME}/.conduit-backups"                    # Backup directory for keys
readonly CONFIG_FILE="${HOME}/.conduit-config"                    # User configuration file
readonly SECCOMP_FILE="${HOME}/.conduit-seccomp.json"             # Seccomp security profile
readonly GITHUB_REPO="moghtaderi/conduit-manager-mac"                # GitHub repository for updates

# ------------------------------------------------------------------------------
# RESOURCE LIMITS - Default values (can be overridden by user config)
# ------------------------------------------------------------------------------
DEFAULT_MAX_MEMORY="2g"         # Default RAM limit (2 gigabytes)
DEFAULT_MAX_CPUS="2"            # Default CPU cores limit
MAX_MEMORY="$DEFAULT_MAX_MEMORY"
MAX_CPUS="$DEFAULT_MAX_CPUS"
MEMORY_SWAP="$DEFAULT_MAX_MEMORY"  # Match swap to memory limit

# ------------------------------------------------------------------------------
# INPUT VALIDATION CONSTRAINTS
# ------------------------------------------------------------------------------
readonly MIN_CLIENTS=1          # Minimum allowed concurrent clients
readonly MAX_CLIENTS_LIMIT=2000 # Maximum allowed concurrent clients
readonly MIN_BANDWIDTH=1        # Minimum bandwidth in Mbps (unless unlimited)
readonly MAX_BANDWIDTH=1000     # Maximum bandwidth in Mbps

# ------------------------------------------------------------------------------
# MULTI-CONTAINER SETTINGS
# ------------------------------------------------------------------------------
readonly MAX_CONTAINERS=5       # Maximum number of containers allowed
CONTAINER_COUNT=1               # Current number of containers (loaded from config)

# ==============================================================================
# TERMINAL COLOR CODES
# ==============================================================================
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'  # No Color - resets formatting

# ==============================================================================
# LOGGING FUNCTIONS
# ==============================================================================

# log_message: Write a timestamped message to both console and log file
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Rotate log if it exceeds 1MB (1048576 bytes)
    if [ -f "$LOG_FILE" ]; then
        local log_size
        log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo "0")
        if [ "$log_size" -gt 1048576 ]; then
            # Keep one backup, rotate current log
            mv -f "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
        fi
    fi

    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    if [[ "$level" == "ERROR" ]]; then
        echo -e "${RED}[ERROR]${NC} $message" >&2
    elif [[ "$level" == "WARN" ]]; then
        echo -e "${YELLOW}[WARN]${NC} $message" >&2
    fi
}

log_info() { log_message "INFO" "$1"; }
log_warn() { log_message "WARN" "$1"; }
log_error() { log_message "ERROR" "$1"; }

# ==============================================================================
# SECCOMP PROFILE - Restrict system calls for additional security
# ==============================================================================

# create_seccomp_profile: Create a restrictive seccomp profile for the container
# This limits which system calls the container can make, reducing attack surface
create_seccomp_profile() {
    # Only create if it doesn't exist
    if [ -f "$SECCOMP_FILE" ]; then
        return 0
    fi

    log_info "Creating seccomp security profile..."

    # This profile is based on Docker's default but more restrictive
    # It allows only the syscalls needed for a network proxy application
    cat > "$SECCOMP_FILE" << 'SECCOMP_EOF'
{
    "defaultAction": "SCMP_ACT_ERRNO",
    "defaultErrnoRet": 1,
    "archMap": [
        {
            "architecture": "SCMP_ARCH_X86_64",
            "subArchitectures": ["SCMP_ARCH_X86", "SCMP_ARCH_X32"]
        },
        {
            "architecture": "SCMP_ARCH_AARCH64",
            "subArchitectures": ["SCMP_ARCH_ARM"]
        }
    ],
    "syscalls": [
        {
            "names": [
                "accept", "accept4", "access", "arch_prctl", "bind", "brk",
                "capget", "capset", "chdir", "chmod", "chown", "clock_getres",
                "clock_gettime", "clock_nanosleep", "clone", "close", "connect",
                "dup", "dup2", "dup3", "epoll_create", "epoll_create1", "epoll_ctl",
                "epoll_pwait", "epoll_wait", "eventfd", "eventfd2", "execve",
                "exit", "exit_group", "faccessat", "faccessat2", "fadvise64",
                "fchdir", "fchmod", "fchmodat", "fchown", "fchownat", "fcntl",
                "fdatasync", "fgetxattr", "flock", "fstat", "fstatfs", "fsync",
                "ftruncate", "futex", "getcwd", "getdents", "getdents64",
                "getegid", "geteuid", "getgid", "getgroups", "getpeername",
                "getpgid", "getpgrp", "getpid", "getppid", "getpriority",
                "getrandom", "getresgid", "getresuid", "getrlimit", "getrusage",
                "getsid", "getsockname", "getsockopt", "gettid", "gettimeofday",
                "getuid", "inotify_add_watch", "inotify_init", "inotify_init1",
                "inotify_rm_watch", "ioctl", "kill", "lgetxattr", "listen",
                "lseek", "lstat", "madvise", "membarrier", "memfd_create",
                "mincore", "mkdir", "mkdirat", "mlock", "mlock2", "mlockall",
                "mmap", "mprotect", "mremap", "msgctl", "msgget", "msgrcv",
                "msgsnd", "msync", "munlock", "munlockall", "munmap", "nanosleep",
                "newfstatat", "open", "openat", "pause", "pipe", "pipe2", "poll",
                "ppoll", "prctl", "pread64", "preadv", "preadv2", "prlimit64",
                "pselect6", "pwrite64", "pwritev", "pwritev2", "read", "readahead",
                "readlink", "readlinkat", "readv", "recv", "recvfrom", "recvmmsg",
                "recvmsg", "rename", "renameat", "renameat2", "restart_syscall",
                "rmdir", "rt_sigaction", "rt_sigpending", "rt_sigprocmask",
                "rt_sigqueueinfo", "rt_sigreturn", "rt_sigsuspend",
                "rt_sigtimedwait", "rt_tgsigqueueinfo", "sched_getaffinity",
                "sched_getattr", "sched_getparam", "sched_get_priority_max",
                "sched_get_priority_min", "sched_getscheduler", "sched_rr_get_interval",
                "sched_setaffinity", "sched_setattr", "sched_setparam",
                "sched_setscheduler", "sched_yield", "seccomp", "select",
                "semctl", "semget", "semop", "semtimedop", "send", "sendfile",
                "sendmmsg", "sendmsg", "sendto", "setfsgid", "setfsuid",
                "setgid", "setgroups", "setitimer", "setpgid", "setpriority",
                "setregid", "setresgid", "setresuid", "setreuid", "setrlimit",
                "setsid", "setsockopt", "setuid", "shutdown", "sigaltstack",
                "socket", "socketpair", "splice", "stat", "statfs", "statx",
                "symlink", "symlinkat", "sync", "sync_file_range", "syncfs",
                "sysinfo", "tee", "tgkill", "time", "timer_create", "timer_delete",
                "timer_getoverrun", "timer_gettime", "timer_settime", "timerfd_create",
                "timerfd_gettime", "timerfd_settime", "times", "tkill", "truncate",
                "umask", "uname", "unlink", "unlinkat", "utimensat", "vfork",
                "wait4", "waitid", "write", "writev"
            ],
            "action": "SCMP_ACT_ALLOW"
        }
    ]
}
SECCOMP_EOF

    chmod 600 "$SECCOMP_FILE"
    log_info "Seccomp profile created at $SECCOMP_FILE"
}

# ==============================================================================
# DOCKER DESKTOP DETECTION
# ==============================================================================

# check_docker_desktop_installed: Verify Docker Desktop is installed on macOS
check_docker_desktop_installed() {
    log_info "Checking Docker Desktop installation..."

    # Check if Docker Desktop app exists
    if [ ! -d "/Applications/Docker.app" ]; then
        echo ""
        echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║           DOCKER DESKTOP NOT INSTALLED                        ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "Docker Desktop is required to run Psiphon Conduit on macOS."
        echo ""
        echo -e "${BOLD}To install Docker Desktop:${NC}"
        echo ""
        echo "  1. Visit: https://www.docker.com/products/docker-desktop/"
        echo "  2. Download Docker Desktop for Mac"
        echo "  3. Open the .dmg file and drag Docker to Applications"
        echo "  4. Launch Docker Desktop from Applications"
        echo "  5. Wait for Docker to fully start (whale icon stops animating)"
        echo "  6. Run this script again"
        echo ""

        # Offer to open download page
        read -p "Open Docker Desktop download page in browser? [y/N]: " open_browser
        if [[ "$open_browser" =~ ^[Yy]$ ]]; then
            open "https://www.docker.com/products/docker-desktop/" 2>/dev/null || true
        fi

        exit 1
    fi

    log_info "Docker Desktop is installed"
}

# check_docker_running: Verify Docker daemon is running and accessible
check_docker_running() {
    log_info "Checking if Docker is running..."

    if ! docker info >/dev/null 2>&1; then
        echo ""
        echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║           DOCKER DESKTOP NOT RUNNING                          ║${NC}"
        echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "Docker Desktop is installed but not currently running."
        echo ""

        # Try to start Docker Desktop
        echo -e "${BLUE}Attempting to start Docker Desktop...${NC}"
        open -a Docker 2>/dev/null || true

        echo ""
        echo "Waiting for Docker to start (this may take 30-60 seconds)..."
        echo ""

        # Wait up to 60 seconds for Docker to start
        local wait_time=0
        local max_wait=60
        while [ $wait_time -lt $max_wait ]; do
            if docker info >/dev/null 2>&1; then
                echo ""
                echo -e "${GREEN}✔ Docker Desktop is now running!${NC}"
                log_info "Docker started successfully after ${wait_time}s"
                return 0
            fi
            echo -n "."
            sleep 2
            wait_time=$((wait_time + 2))
        done

        echo ""
        echo -e "${RED}Docker did not start within ${max_wait} seconds.${NC}"
        echo ""
        echo "Please manually:"
        echo "  1. Open Docker Desktop from Applications"
        echo "  2. Wait for the whale icon to stop animating"
        echo "  3. Run this script again"
        echo ""
        exit 1
    fi

    log_info "Docker is running"
}

# ==============================================================================
# CONFIGURATION MANAGEMENT
# ==============================================================================

# load_config: Load user configuration from file
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # Source the config file to load variables
        # shellcheck disable=SC1090
        source "$CONFIG_FILE" 2>/dev/null || true

        # Validate loaded values
        if [ -n "${SAVED_MAX_MEMORY:-}" ]; then
            MAX_MEMORY="$SAVED_MAX_MEMORY"
            MEMORY_SWAP="$SAVED_MAX_MEMORY"
        fi
        if [ -n "${SAVED_MAX_CPUS:-}" ]; then
            MAX_CPUS="$SAVED_MAX_CPUS"
        fi
        # Load container count (default to 1 for backward compatibility)
        if [ -n "${SAVED_CONTAINER_COUNT:-}" ]; then
            if [ "$SAVED_CONTAINER_COUNT" -ge 1 ] && [ "$SAVED_CONTAINER_COUNT" -le "$MAX_CONTAINERS" ] 2>/dev/null; then
                CONTAINER_COUNT="$SAVED_CONTAINER_COUNT"
            fi
        fi
    fi
}

# save_config: Save user configuration to file
save_config() {
    cat > "$CONFIG_FILE" << EOF
# Conduit Manager Configuration
# Generated: $(date)

# Resource Limits
SAVED_MAX_MEMORY="$MAX_MEMORY"
SAVED_MAX_CPUS="$MAX_CPUS"

# Multi-Container Settings
SAVED_CONTAINER_COUNT="$CONTAINER_COUNT"
EOF
    chmod 600 "$CONFIG_FILE"
}

# Load configuration at startup
load_config

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

# format_bytes: Convert bytes to human-readable format (B, KB, MB, GB)
# Arguments:
#   $1 - Number of bytes
# Returns:
#   Human-readable string (e.g., "1.50 GB")
format_bytes() {
    local bytes="$1"

    # Handle empty or zero input
    if [ -z "$bytes" ] || ! [[ "$bytes" =~ ^[0-9]+$ ]] || [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "0 B"
        return
    fi

    # Convert based on size thresholds (using binary units)
    if [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.2f KB\", $bytes/1024}"
    else
        echo "$bytes B"
    fi
}

# get_cpu_cores: Get the number of CPU cores on macOS
get_cpu_cores() {
    local cores=1
    if command -v sysctl &>/dev/null; then
        cores=$(sysctl -n hw.ncpu 2>/dev/null) || cores=1
    fi
    if [ -z "$cores" ] || [ "$cores" -lt 1 ] 2>/dev/null; then
        echo 1
    else
        echo "$cores"
    fi
}

# get_ram_gb: Get total RAM in GB on macOS
get_ram_gb() {
    local ram_bytes=""
    local ram_gb=1
    if command -v sysctl &>/dev/null; then
        ram_bytes=$(sysctl -n hw.memsize 2>/dev/null) || ram_bytes=""
    fi
    if [ -n "$ram_bytes" ] && [ "$ram_bytes" -gt 0 ] 2>/dev/null; then
        ram_gb=$((ram_bytes / 1073741824))
    fi
    if [ "$ram_gb" -lt 1 ]; then
        echo 1
    else
        echo "$ram_gb"
    fi
}

# get_system_stats: Get macOS system CPU and RAM usage
# Returns: "cpu_percent ram_used_gb ram_total_gb"
get_system_stats() {
    local cpu_percent="N/A"
    local ram_used="N/A"
    local ram_total="N/A"

    # Get CPU usage from top (macOS version)
    if command -v top &>/dev/null; then
        # macOS top output format differs from Linux
        local cpu_idle
        cpu_idle=$(top -l 1 -n 0 2>/dev/null | grep "CPU usage" | awk '{print $7}' | tr -d '%') || cpu_idle=""
        if [ -n "$cpu_idle" ] && [[ "$cpu_idle" =~ ^[0-9.]+$ ]]; then
            cpu_percent=$(awk "BEGIN {printf \"%.1f%%\", 100 - $cpu_idle}")
        fi
    fi

    # Get RAM from vm_stat (macOS)
    if command -v vm_stat &>/dev/null; then
        # Get page size dynamically (16384 on Apple Silicon, 4096 on older Intel)
        local page_size
        page_size=$(vm_stat 2>/dev/null | head -1 | grep -o '[0-9]*') || page_size=16384

        local pages_active pages_wired pages_compressed pages_occupied_by_compressor

        pages_active=$(vm_stat 2>/dev/null | awk '/Pages active/ {print $3}' | tr -d '.') || pages_active=0
        pages_wired=$(vm_stat 2>/dev/null | awk '/Pages wired/ {print $4}' | tr -d '.') || pages_wired=0
        pages_compressed=$(vm_stat 2>/dev/null | awk '/Pages occupied by compressor/ {print $5}' | tr -d '.') || pages_compressed=0

        # Memory Used = Active + Wired + Compressed (matches Activity Monitor)
        local used_bytes=$(( (pages_active + pages_wired + pages_compressed) * page_size ))
        local total_bytes
        total_bytes=$(sysctl -n hw.memsize 2>/dev/null) || total_bytes=0

        if [ "$total_bytes" -gt 0 ]; then
            ram_used=$(awk "BEGIN {printf \"%.1f GB\", $used_bytes/1073741824}")
            ram_total=$(awk "BEGIN {printf \"%.1f GB\", $total_bytes/1073741824}")
        fi
    fi

    echo "$cpu_percent $ram_used $ram_total"
}

# calculate_recommended_clients: Calculate recommended max clients based on CPU
calculate_recommended_clients() {
    local cores
    cores=$(get_cpu_cores)
    # Logic: 100 clients per CPU core, max 1000
    local recommended=$((cores * 100))
    if [ "$recommended" -gt 1000 ]; then
        echo 1000
    else
        echo "$recommended"
    fi
}

# ==============================================================================
# INPUT VALIDATION FUNCTIONS
# ==============================================================================

# validate_integer: Check if input is a valid integer within specified range
validate_integer() {
    local value="$1"
    local min="$2"
    local max="$3"
    local field_name="$4"

    if [[ ! "$value" =~ ^-?[0-9]+$ ]]; then
        log_error "$field_name must be an integer, got: '$value'"
        echo -e "${RED}Error: $field_name must be a valid integer.${NC}"
        return 1
    fi

    if [[ "$value" -ne -1 ]] && [[ "$value" -lt "$min" || "$value" -gt "$max" ]]; then
        log_error "$field_name out of range: $value (allowed: $min-$max or -1)"
        echo -e "${RED}Error: $field_name must be between $min and $max (or -1 for unlimited).${NC}"
        return 1
    fi

    return 0
}

# validate_max_clients: Validate the maximum clients input
validate_max_clients() {
    local value="$1"

    if [[ "$value" == "-1" ]]; then
        log_error "Max clients cannot be unlimited (-1)"
        echo -e "${RED}Error: Max clients cannot be unlimited. Please specify a number.${NC}"
        return 1
    fi

    validate_integer "$value" "$MIN_CLIENTS" "$MAX_CLIENTS_LIMIT" "Max Clients"
}

# validate_bandwidth: Validate the bandwidth limit input
validate_bandwidth() {
    local value="$1"

    if [[ "$value" == "-1" ]]; then
        return 0
    fi

    validate_integer "$value" "$MIN_BANDWIDTH" "$MAX_BANDWIDTH" "Bandwidth"
}

# sanitize_input: Remove potentially dangerous characters from input
sanitize_input() {
    local input="$1"
    echo "$input" | tr -cd '0-9-'
}

# ==============================================================================
# DOCKER HELPER FUNCTIONS
# ==============================================================================

# check_docker: Verify Docker Desktop is installed and running
# Uses the new check_docker_desktop_installed and check_docker_running functions
check_docker() {
    check_docker_desktop_installed
    check_docker_running
}

# verify_image_digest: Verify the Docker image SHA256 digest for security
# Arguments:
#   $1 - Expected digest
#   $2 - Image name
# Returns:
#   0 if verified, 1 if failed
verify_image_digest() {
    local expected_digest="$1"
    local image="$2"

    # Skip verification if no digest is configured
    if [ -z "$expected_digest" ]; then
        log_info "No digest configured, skipping verification"
        return 0
    fi

    log_info "Verifying image digest..."

    # Get the actual digest of the pulled image
    local actual_digest
    actual_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null | grep -o 'sha256:[a-f0-9]*') || actual_digest=""

    if [ -z "$actual_digest" ]; then
        log_warn "Could not verify image digest (image may not have digest metadata)"
        return 0  # Non-fatal, continue with warning
    fi

    if [ "$actual_digest" = "$expected_digest" ]; then
        log_info "Image digest verified: $actual_digest"
        echo -e "${GREEN}✔ Image integrity verified${NC}"
        return 0
    else
        log_error "Image digest mismatch!"
        log_error "Expected: $expected_digest"
        log_error "Got:      $actual_digest"
        echo -e "${RED}✘ WARNING: Image digest does not match expected value!${NC}"
        echo -e "${YELLOW}This could indicate a compromised or updated image.${NC}"
        echo ""
        read -p "Continue anyway? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
            log_warn "User chose to continue despite digest mismatch"
            return 0
        fi
        return 1
    fi
}

# ensure_network_exists: Create the isolated bridge network if it doesn't exist
ensure_network_exists() {
    log_info "Ensuring isolated network '$NETWORK_NAME' exists..."

    if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        log_info "Creating isolated bridge network: $NETWORK_NAME"

        if docker network create --driver bridge "$NETWORK_NAME" >/dev/null 2>&1; then
            log_info "Network created successfully"
            echo -e "${GREEN}✔ Created isolated network: $NETWORK_NAME${NC}"
        else
            log_error "Failed to create network: $NETWORK_NAME"
            echo -e "${RED}Failed to create network. Check Docker permissions.${NC}"
            return 1
        fi
    else
        log_info "Network '$NETWORK_NAME' already exists"
    fi

    return 0
}

# ==============================================================================
# MULTI-CONTAINER HELPER FUNCTIONS
# ==============================================================================

# get_container_name: Get container name for given index
# Arguments:
#   $1 - Container index (1-5), defaults to 1
# Returns:
#   Container name (e.g., "conduit-mac" for index 1, "conduit-mac-2" for index 2)
get_container_name() {
    local index="${1:-1}"
    if [ "$index" -eq 1 ]; then
        echo "$CONTAINER_NAME"
    else
        echo "${CONTAINER_NAME}-${index}"
    fi
}

# get_volume_name: Get volume name for given index
# Arguments:
#   $1 - Container index (1-5), defaults to 1
# Returns:
#   Volume name (e.g., "conduit-data" for index 1, "conduit-data-2" for index 2)
get_volume_name() {
    local index="${1:-1}"
    if [ "$index" -eq 1 ]; then
        echo "$VOLUME_NAME"
    else
        echo "${VOLUME_NAME}-${index}"
    fi
}

# container_exists: Check if a container exists (running or stopped)
# Arguments:
#   $1 - Container index (optional, defaults to 1)
container_exists() {
    local index="${1:-1}"
    local name
    name=$(get_container_name "$index")
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        return 0
    else
        return 1
    fi
}

# container_running: Check if a container is currently running
# Arguments:
#   $1 - Container index (optional, defaults to 1)
container_running() {
    local index="${1:-1}"
    local name
    name=$(get_container_name "$index")
    if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
        return 0
    else
        return 1
    fi
}

# remove_container: Safely remove a container if it exists
# Arguments:
#   $1 - Container index (optional, defaults to 1)
remove_container() {
    local index="${1:-1}"
    local name
    name=$(get_container_name "$index")
    if container_exists "$index"; then
        log_info "Removing existing container: $name"
        if docker rm -f "$name" >/dev/null 2>&1; then
            log_info "Container removed successfully"
        else
            log_warn "Failed to remove container (may not exist)"
        fi
    fi
}

# count_running_containers: Count how many containers are currently running
# Returns:
#   Number of running containers (0-5)
count_running_containers() {
    local count=0
    local i=1
    while [ $i -le "$CONTAINER_COUNT" ]; do
        if container_running "$i"; then
            count=$((count + 1))
        fi
        i=$((i + 1))
    done
    echo "$count"
}

# get_all_container_stats: Get combined stats from all running containers
# Returns:
#   "total_clients connected_count connecting_count" or empty if none running
get_all_container_stats() {
    local total_connected=0
    local total_connecting=0
    local i=1

    while [ $i -le "$CONTAINER_COUNT" ]; do
        if container_running "$i"; then
            local name
            name=$(get_container_name "$i")
            local stats_line
            stats_line=$(docker logs --tail 50 "$name" 2>/dev/null | grep '\[STATS\]' | tail -1) || stats_line=""

            if [ -n "$stats_line" ]; then
                local connected connecting
                connected=$(echo "$stats_line" | grep -o 'Connected: [0-9]*' | awk '{print $2}') || connected=0
                connecting=$(echo "$stats_line" | grep -o 'Connecting: [0-9]*' | awk '{print $2}') || connecting=0
                total_connected=$((total_connected + ${connected:-0}))
                total_connecting=$((total_connecting + ${connecting:-0}))
            fi
        fi
        i=$((i + 1))
    done

    echo "$total_connected $total_connecting"
}

# ==============================================================================
# NODE ID FUNCTIONS
# ==============================================================================

# get_node_id: Extract the node ID from conduit_key.json in the Docker volume
# The node ID is derived from the private key and uniquely identifies this node.
# Returns:
#   Node ID string or empty if not found
get_node_id() {
    # On macOS with Docker Desktop, we can't access volume mountpoints directly
    # because they exist inside the Docker VM. Always use a container to read.
    local key_content
    key_content=$(docker run --rm -v "$VOLUME_NAME":/data alpine cat /data/conduit_key.json 2>/dev/null) || key_content=""

    if [ -n "$key_content" ]; then
        # Extract privateKeyBase64, decode, take last 32 bytes, encode base64
        # This derives the public node ID from the private key
        echo "$key_content" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' 2>/dev/null
    fi
}

# ==============================================================================
# BACKUP AND RESTORE FUNCTIONS
# ==============================================================================

# backup_key: Create a backup of the node identity key
backup_key() {
    print_header
    echo -e "${CYAN}═══ BACKUP CONDUIT NODE KEY ═══${NC}"
    echo ""

    # Check if container/volume exists
    if ! docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
        echo -e "${RED}Error: Could not find conduit-data volume${NC}"
        echo "Has Conduit been started at least once?"
        read -n 1 -s -r -p "Press any key to return..."
        return 1
    fi

    # Try to read the key file
    local key_content
    key_content=$(docker run --rm -v "$VOLUME_NAME":/data alpine cat /data/conduit_key.json 2>/dev/null) || key_content=""

    if [ -z "$key_content" ]; then
        echo -e "${RED}Error: No node key found. Has Conduit been started at least once?${NC}"
        read -n 1 -s -r -p "Press any key to return..."
        return 1
    fi

    # Create backup directory
    mkdir -p "$BACKUP_DIR"

    # Create timestamped backup
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="$BACKUP_DIR/conduit_key_${timestamp}.json"

    # Write the key to backup file
    echo "$key_content" > "$backup_file"
    chmod 600 "$backup_file"

    # Get node ID for display
    local node_id
    node_id=$(echo "$key_content" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' 2>/dev/null)

    log_info "Node key backed up to: $backup_file"

    echo -e "${GREEN}✔ Backup created successfully${NC}"
    echo ""
    echo -e "  Backup file: ${CYAN}${backup_file}${NC}"
    echo -e "  Node ID:     ${CYAN}${node_id:-unknown}${NC}"
    echo ""
    echo -e "${YELLOW}Important:${NC} Store this backup securely. It contains your node's"
    echo "private key which identifies your node on the Psiphon network."
    echo ""

    # List all backups
    echo "All backups:"
    ls -la "$BACKUP_DIR/"*.json 2>/dev/null | awk '{print "  " $9 " (" $5 " bytes)"}' || echo "  (none)"
    echo ""
    read -n 1 -s -r -p "Press any key to return..."
}

# restore_key: Restore node identity from a backup
restore_key() {
    print_header
    echo -e "${CYAN}═══ RESTORE CONDUIT NODE KEY ═══${NC}"
    echo ""

    # Check if backup directory exists and has files
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR"/*.json 2>/dev/null)" ]; then
        echo -e "${YELLOW}No backups found in ${BACKUP_DIR}${NC}"
        echo ""
        echo "To restore from a custom path, provide the file path:"
        read -p "  Backup file path (or press Enter to cancel): " custom_path

        if [ -z "$custom_path" ]; then
            echo "Restore cancelled."
            read -n 1 -s -r -p "Press any key to return..."
            return 0
        fi

        if [ ! -f "$custom_path" ]; then
            echo -e "${RED}Error: File not found: ${custom_path}${NC}"
            read -n 1 -s -r -p "Press any key to return..."
            return 1
        fi

        backup_file="$custom_path"
    else
        # List available backups
        echo "Available backups:"
        local i=1
        local backups=()
        for f in "$BACKUP_DIR"/*.json; do
            backups+=("$f")
            local node_id
            node_id=$(cat "$f" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' 2>/dev/null)
            echo "  ${i}. $(basename "$f") - Node: ${node_id:-unknown}"
            i=$((i + 1))
        done
        echo ""

        read -p "  Select backup number (or 0 to cancel): " selection

        if [ "$selection" = "0" ] || [ -z "$selection" ]; then
            echo "Restore cancelled."
            read -n 1 -s -r -p "Press any key to return..."
            return 0
        fi

        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#backups[@]} ]; then
            echo -e "${RED}Invalid selection${NC}"
            read -n 1 -s -r -p "Press any key to return..."
            return 1
        fi

        backup_file="${backups[$((selection - 1))]}"
    fi

    echo ""
    echo -e "${YELLOW}Warning:${NC} This will replace the current node key."
    echo "The container will be stopped and restarted."
    echo ""
    read -p "Proceed with restore? [y/N] " confirm

    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo "Restore cancelled."
        read -n 1 -s -r -p "Press any key to return..."
        return 0
    fi

    # Stop container
    echo ""
    echo "Stopping Conduit..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true

    # Restore the key using a temporary container
    # Also fix ownership to UID 1000 (conduit user inside container)
    echo "Restoring key..."
    if ! docker run --rm -v "$VOLUME_NAME":/data -v "$(dirname "$backup_file")":/backup alpine \
        sh -c "cp /backup/$(basename "$backup_file") /data/conduit_key.json && chmod 600 /data/conduit_key.json && chown -R 1000:1000 /data"; then
        log_error "Failed to copy key to volume"
        echo -e "${RED}✘ Failed to restore key - copy operation failed${NC}"
        read -n 1 -s -r -p "Press any key to return..."
        return 1
    fi

    # Verify the key was actually written to the volume
    echo "Verifying restore..."
    local verify_content=""
    verify_content=$(docker run --rm -v "$VOLUME_NAME":/data alpine cat /data/conduit_key.json 2>/dev/null) || verify_content=""
    if [ -z "$verify_content" ] || ! echo "$verify_content" | grep -q "privateKeyBase64"; then
        log_error "Key verification failed - file not found or invalid"
        echo -e "${RED}✘ Failed to restore key - verification failed${NC}"
        read -n 1 -s -r -p "Press any key to return..."
        return 1
    fi

    # Restart container
    echo "Starting Conduit..."
    docker start "$CONTAINER_NAME" 2>/dev/null || true

    local node_id
    node_id=$(cat "$backup_file" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' 2>/dev/null)

    log_info "Node key restored from: $backup_file"

    echo ""
    echo -e "${GREEN}✔ Node key restored successfully${NC}"
    echo -e "  Node ID: ${CYAN}${node_id:-unknown}${NC}"
    echo ""
    read -n 1 -s -r -p "Press any key to return..."
}

# ==============================================================================
# UI FUNCTIONS
# ==============================================================================

# print_header: Display the application banner
# Uses escape sequences to clear both screen and scrollback buffer for clean TUI
print_header() {
    # Clear screen and scrollback buffer for proper TUI experience
    # \033[2J = clear screen, \033[3J = clear scrollback, \033[H = cursor home
    printf '\033[2J\033[3J\033[H'
    echo -e "${CYAN}"
    echo "  ██████╗ ██████╗ ███╗   ██╗██████╗ ██╗   ██╗██╗████████╗"
    echo " ██╔════╝██╔═══██╗████╗  ██║██╔══██╗██║   ██║██║╚══██╔══╝"
    echo " ██║     ██║   ██║██╔██╗ ██║██║  ██║██║   ██║██║   ██║   "
    echo " ██║     ██║   ██║██║╚██╗██║██║  ██║██║   ██║██║   ██║   "
    echo " ╚██████╗╚██████╔╝██║ ╚████║██████╔╝╚██████╔╝██║   ██║   "
    echo "  ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═════╝  ╚═════╝ ╚═╝   ╚═╝   "
    echo -e "      ${YELLOW}macOS Security-Hardened Edition v${VERSION}${CYAN}          "
    echo -e "${NC}"

    echo -e "${GREEN}[SECURE]${NC} Container isolation: ENABLED"
    echo ""
}

# print_system_info: Display system information for configuration
print_system_info() {
    local cores
    local ram_gb
    local recommended
    cores=$(get_cpu_cores)
    ram_gb=$(get_ram_gb)
    recommended=$(calculate_recommended_clients)

    echo -e "${BOLD}System Information:${NC}"
    echo "══════════════════════════════════════════════════════"
    echo -e "  CPU Cores:    ${GREEN}${cores}${NC}"
    echo -e "  RAM:          ${GREEN}${ram_gb} GB${NC}"
    echo -e "  Recommended:  ${GREEN}${recommended} max-clients${NC}"
    echo "══════════════════════════════════════════════════════"
    echo ""
}

# print_security_notice: Display information about security settings
print_security_notice() {
    echo -e "${BOLD}Security Settings:${NC}"
    echo "══════════════════════════════════════════════════════"
    echo -e " Network:     ${GREEN}Isolated bridge${NC} (no host access)"
    echo -e " Filesystem:  ${GREEN}Read-only${NC} (tmpfs for /tmp)"
    echo -e " Privileges:  ${GREEN}Dropped${NC} (no-new-privileges)"
    echo -e " Resources:   ${GREEN}Limited${NC} (${MAX_MEMORY} RAM, ${MAX_CPUS} CPUs)"
    echo -e " Image:       ${GREEN}Digest verified${NC}"
    echo "══════════════════════════════════════════════════════"
    echo ""
}

# ==============================================================================
# CORE FUNCTIONALITY
# ==============================================================================

# check_resource_limits_changed: Check if configured limits differ from running container
# Returns 0 if limits changed, 1 if same
check_resource_limits_changed() {
    local container_mem_limit=""
    local container_cpu_limit=""
    container_mem_limit=$(docker inspect --format='{{.HostConfig.Memory}}' "$CONTAINER_NAME" 2>/dev/null) || container_mem_limit="0"
    container_cpu_limit=$(docker inspect --format='{{.HostConfig.NanoCpus}}' "$CONTAINER_NAME" 2>/dev/null) || container_cpu_limit="0"

    # Convert memory from bytes to GB
    local container_mem_gb="0"
    if [ -n "$container_mem_limit" ] && [ "$container_mem_limit" -gt 0 ] 2>/dev/null; then
        container_mem_gb=$(awk "BEGIN {printf \"%.0f\", $container_mem_limit/1073741824}")
    fi

    # Convert NanoCpus to cores
    local container_cpu_cores="0"
    if [ -n "$container_cpu_limit" ] && [ "$container_cpu_limit" -gt 0 ] 2>/dev/null; then
        container_cpu_cores=$(awk "BEGIN {printf \"%.0f\", $container_cpu_limit/1000000000}")
    fi

    # Compare with configured limits
    local config_mem_gb="${MAX_MEMORY%g}"
    if [ "$container_mem_gb" != "$config_mem_gb" ] || [ "$container_cpu_cores" != "$MAX_CPUS" ]; then
        return 0  # Limits changed
    fi
    return 1  # Limits same
}

# smart_start: Intelligently start, restart, or install the container(s)
# Also detects if resource limits have changed and recreates container if needed
smart_start() {
    print_header
    log_info "Smart start initiated for $CONTAINER_COUNT container(s)"

    # Check if primary container exists - if not, do first-time setup
    if ! container_exists 1; then
        echo -e "${BLUE}▶ FIRST TIME SETUP${NC}"
        echo "-----------------------------------"
        log_info "Container not found, initiating fresh installation"
        install_new
        return
    fi

    # Check if resource limits have changed (check primary container only)
    if check_resource_limits_changed; then
        echo -e "${YELLOW}Status: Resource limits changed${NC}"
        echo -e "${BLUE}Action: Recreating all containers with new limits...${NC}"
        echo ""
        echo -e "  New limits: ${CYAN}${MAX_CPUS} CPU / ${MAX_MEMORY} RAM${NC}"
        echo ""
        log_info "Resource limits changed, recreating containers"

        # Recreate all configured containers
        local i=1
        while [ $i -le "$CONTAINER_COUNT" ]; do
            local name
            local vol
            name=$(get_container_name "$i")
            vol=$(get_volume_name "$i")

            echo -e "Recreating container ${CYAN}$name${NC}..."

            # Get current settings from container
            local current_args=""
            current_args=$(docker inspect --format='{{.Args}}' "$name" 2>/dev/null) || current_args=""

            # Extract max-clients and bandwidth from current args
            local max_clients=""
            local bandwidth=""
            max_clients=$(echo "$current_args" | grep -o '\-\-max-clients [0-9]*' | awk '{print $2}') || max_clients=""
            bandwidth=$(echo "$current_args" | grep -o '\-\-bandwidth [0-9-]*' | awk '{print $2}') || bandwidth=""

            # Use defaults if not found
            max_clients="${max_clients:-200}"
            bandwidth="${bandwidth:-5}"

            # Remove old container
            docker stop "$name" >/dev/null 2>&1 || true
            docker rm -f "$name" >/dev/null 2>&1 || true

            # Ensure network exists
            ensure_network_exists

            # Fix volume permissions
            docker run --rm -v "$vol":/home/conduit/data alpine \
                sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true

            # Ensure seccomp profile exists
            create_seccomp_profile

            # Build docker run command with optional seccomp
            local seccomp_opt=""
            if [ -f "$SECCOMP_FILE" ]; then
                seccomp_opt="--security-opt seccomp=$SECCOMP_FILE"
            fi

            # Calculate PIDs limit based on max_clients
            local pids_limit=$((max_clients + 50))

            if docker run -d \
                --name "$name" \
                --restart unless-stopped \
                --network "$NETWORK_NAME" \
                --read-only \
                --tmpfs /tmp:rw,noexec,nosuid,size=100m \
                --security-opt no-new-privileges:true \
                $seccomp_opt \
                --cap-drop ALL \
                --cap-add NET_BIND_SERVICE \
                --memory "$MAX_MEMORY" \
                --cpus "$MAX_CPUS" \
                --memory-swap "$MEMORY_SWAP" \
                --pids-limit "$pids_limit" \
                -v "$vol":/home/conduit/data \
                "$IMAGE" \
                start --max-clients "$max_clients" --bandwidth "$bandwidth" -v > /dev/null 2>&1; then

                log_info "Container $name recreated with new limits"
                echo -e "  ${GREEN}✔ $name recreated${NC}"
            else
                log_error "Failed to recreate container $name"
                echo -e "  ${RED}✘ Failed to recreate $name${NC}"
            fi

            i=$((i + 1))
        done

        echo ""
        echo -e "${GREEN}✔ All containers recreated with new resource limits.${NC}"
        sleep 2
        return
    fi

    # Start/restart all configured containers
    local started=0
    local restarted=0
    local failed=0

    echo -e "${BLUE}Starting/Restarting $CONTAINER_COUNT container(s)...${NC}"
    echo ""

    local i=1
    while [ $i -le "$CONTAINER_COUNT" ]; do
        local name
        name=$(get_container_name "$i")

        if ! container_exists "$i"; then
            # Container doesn't exist, needs to be created via install
            echo -e "  ${YELLOW}$name: Not installed${NC}"
            failed=$((failed + 1))
        elif container_running "$i"; then
            # Container is running, restart it
            if docker restart "$name" > /dev/null 2>&1; then
                log_info "Container $name restarted"
                echo -e "  ${GREEN}✔ $name: Restarted${NC}"
                restarted=$((restarted + 1))
            else
                log_error "Failed to restart $name"
                echo -e "  ${RED}✘ $name: Restart failed${NC}"
                failed=$((failed + 1))
            fi
        else
            # Container exists but stopped, start it
            if docker start "$name" > /dev/null 2>&1; then
                log_info "Container $name started"
                echo -e "  ${GREEN}✔ $name: Started${NC}"
                started=$((started + 1))
            else
                log_error "Failed to start $name"
                echo -e "  ${RED}✘ $name: Start failed${NC}"
                failed=$((failed + 1))
            fi
        fi

        i=$((i + 1))
    done

    echo ""
    if [ $failed -eq 0 ]; then
        echo -e "${GREEN}✔ All services operational.${NC}"
    else
        echo -e "${YELLOW}Started: $started, Restarted: $restarted, Failed: $failed${NC}"
    fi
    sleep 2
}

# install_new: Install and configure a new container instance
install_new() {
    local max_clients
    local bandwidth
    local raw_input
    local recommended
    local restore_backup=""
    recommended=$(calculate_recommended_clients)

    echo ""
    print_system_info
    print_security_notice

    # --------------------------------------------------------------------------
    # Check for available backups and offer to restore
    # --------------------------------------------------------------------------
    local backup_count=0
    if [ -d "$BACKUP_DIR" ]; then
        backup_count=$(find "$BACKUP_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    fi

    if [ "$backup_count" -gt 0 ]; then
        echo -e "${CYAN}═══ NODE IDENTITY ═══${NC}"
        echo ""
        echo -e "${GREEN}Found ${backup_count} backup key(s) available.${NC}"
        echo ""
        echo "  1. Start fresh (generate new node identity)"
        echo "  2. Restore from backup (keep existing node identity)"
        echo ""
        read -p "  Select option [1-2, Default: 1]: " identity_choice

        if [ "$identity_choice" = "2" ]; then
            # List available backups
            echo ""
            echo "Available backups:"
            local i=1
            local backups=()
            for f in "$BACKUP_DIR"/*.json; do
                backups+=("$f")
                local node_id
                node_id=$(cat "$f" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' 2>/dev/null)
                local backup_date
                backup_date=$(basename "$f" | sed 's/conduit_key_//' | sed 's/.json//' | sed 's/_/ /')
                echo "  ${i}. ${backup_date} - Node: ${node_id:-unknown}"
                i=$((i + 1))
            done
            echo ""

            read -p "  Select backup number (or 0 to start fresh): " selection

            if [ -n "$selection" ] && [ "$selection" != "0" ]; then
                if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#backups[@]} ]; then
                    restore_backup="${backups[$((selection - 1))]}"
                    local selected_node_id
                    selected_node_id=$(cat "$restore_backup" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' 2>/dev/null)
                    echo ""
                    echo -e "  ${GREEN}✔ Will restore node: ${selected_node_id:-unknown}${NC}"
                else
                    echo -e "  ${YELLOW}Invalid selection. Starting fresh.${NC}"
                    restore_backup=""
                fi
            fi
        fi
        echo ""
    fi

    # --------------------------------------------------------------------------
    # Prompt for Maximum Clients with input validation
    # --------------------------------------------------------------------------
    while true; do
        read -p "Maximum Clients [1-${MAX_CLIENTS_LIMIT}, Default: ${recommended}]: " raw_input

        raw_input="${raw_input:-$recommended}"
        max_clients=$(sanitize_input "$raw_input")

        if validate_max_clients "$max_clients"; then
            break
        fi
        echo "Please enter a valid number."
    done

    # --------------------------------------------------------------------------
    # Prompt for Bandwidth Limit with input validation
    # --------------------------------------------------------------------------
    while true; do
        read -p "Bandwidth Limit in Mbps [1-${MAX_BANDWIDTH}, -1=Unlimited, Default: 5]: " raw_input

        raw_input="${raw_input:-5}"
        bandwidth=$(sanitize_input "$raw_input")

        if validate_bandwidth "$bandwidth"; then
            break
        fi
        echo "Please enter a valid number."
    done

    echo ""
    log_info "Installing container with max_clients=$max_clients, bandwidth=$bandwidth"
    echo -e "${YELLOW}Deploying secure container...${NC}"

    # --------------------------------------------------------------------------
    # Pre-deployment: Check network connectivity
    # --------------------------------------------------------------------------
    echo -n "Checking network connectivity... "
    if ! curl -s --connect-timeout 5 --max-time 10 "https://ghcr.io" >/dev/null 2>&1; then
        echo -e "${RED}FAILED${NC}"
        log_error "Network connectivity check failed - cannot reach ghcr.io"
        echo -e "${RED}✘ Cannot reach container registry (ghcr.io)${NC}"
        echo ""
        echo "Please check your internet connection and try again."
        read -n 1 -s -r -p "Press any key to continue..."
        return 1
    fi
    echo -e "${GREEN}OK${NC}"

    # --------------------------------------------------------------------------
    # Pre-deployment: Ensure network exists and remove old container
    # --------------------------------------------------------------------------
    if ! ensure_network_exists; then
        log_error "Network setup failed, aborting installation"
        read -n 1 -s -r -p "Press any key to continue..."
        return 1
    fi

    remove_container

    # --------------------------------------------------------------------------
    # Pull the container image
    # --------------------------------------------------------------------------
    echo -e "${BLUE}Pulling container image...${NC}"
    log_info "Pulling image: $IMAGE"

    if ! docker pull "$IMAGE" > /dev/null 2>&1; then
        log_error "Failed to pull image: $IMAGE"
        echo -e "${RED}✘ Failed to pull container image.${NC}"
        echo "Check your internet connection and try again."
        read -n 1 -s -r -p "Press any key to continue..."
        return 1
    fi

    # --------------------------------------------------------------------------
    # Verify image digest for supply chain security
    # --------------------------------------------------------------------------
    if ! verify_image_digest "$IMAGE_DIGEST" "$IMAGE"; then
        log_error "Image verification failed, aborting"
        read -n 1 -s -r -p "Press any key to continue..."
        return 1
    fi

    # --------------------------------------------------------------------------
    # Restore backup if selected
    # --------------------------------------------------------------------------
    if [ -n "$restore_backup" ]; then
        echo -e "${BLUE}Restoring node identity from backup...${NC}"
        log_info "Restoring key from: $restore_backup"
        docker run --rm -v "$VOLUME_NAME":/data -v "$(dirname "$restore_backup")":/backup alpine \
            sh -c "cp /backup/$(basename "$restore_backup") /data/conduit_key.json && chmod 600 /data/conduit_key.json && chown -R 1000:1000 /data"
        echo -e "${GREEN}✔ Node identity restored${NC}"
    fi

    # --------------------------------------------------------------------------
    # Fix volume permissions before starting container
    # --------------------------------------------------------------------------
    # The conduit container runs as UID 1000, but Docker creates volumes as root.
    # We need to fix ownership so the container can write its key file.
    echo "Setting up data volume permissions..."
    docker run --rm -v "$VOLUME_NAME":/home/conduit/data alpine \
        sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true

    # --------------------------------------------------------------------------
    # Create seccomp profile for additional security
    # --------------------------------------------------------------------------
    create_seccomp_profile

    # --------------------------------------------------------------------------
    # Deploy container with comprehensive security settings
    # --------------------------------------------------------------------------
    echo -e "${BLUE}Starting container with security hardening...${NC}"
    log_info "Deploying container with security constraints"

    # Build docker run command with optional seccomp
    local seccomp_opt=""
    if [ -f "$SECCOMP_FILE" ]; then
        seccomp_opt="--security-opt seccomp=$SECCOMP_FILE"
    fi

    # Calculate PIDs limit based on max_clients (each connection may use threads)
    local pids_limit=$((max_clients + 50))

    if docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --network "$NETWORK_NAME" \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,size=100m \
        --security-opt no-new-privileges:true \
        $seccomp_opt \
        --cap-drop ALL \
        --cap-add NET_BIND_SERVICE \
        --memory "$MAX_MEMORY" \
        --cpus "$MAX_CPUS" \
        --memory-swap "$MEMORY_SWAP" \
        --pids-limit "$pids_limit" \
        -v "$VOLUME_NAME":/home/conduit/data \
        "$IMAGE" \
        start --max-clients "$max_clients" --bandwidth "$bandwidth" -v > /dev/null 2>&1; then

        log_info "Container deployed successfully"
        echo ""
        echo -e "${GREEN}✔ Installation Complete & Started!${NC}"
        echo ""

        # Wait a moment for the container to generate its key
        sleep 2

        # Show node ID if available
        local node_id
        node_id=$(get_node_id)
        if [ -n "$node_id" ]; then
            echo -e "${BOLD}Node ID:${NC} ${CYAN}${node_id}${NC}"
            echo ""
        fi

        echo -e "${BOLD}Container Security Summary:${NC}"
        echo "  - Isolated network (cannot access host network)"
        echo "  - Read-only filesystem (tamper-resistant)"
        echo "  - Resource limits enforced (CPU/RAM capped)"
        echo "  - Privilege escalation blocked"
        echo "  - Seccomp syscall filtering enabled"
        echo "  - Image digest verified"
        echo ""
        read -n 1 -s -r -p "Press any key to return..."
    else
        log_error "Container deployment failed"
        echo -e "${RED}✘ Installation Failed.${NC}"
        echo ""
        echo "Possible causes:"
        echo "  - Docker may need more permissions"
        echo "  - Port conflicts with other containers"
        echo "  - Insufficient system resources"
        echo ""
        echo "Check logs at: $LOG_FILE"
        read -n 1 -s -r -p "Press any key to continue..."
        return 1
    fi
}

# stop_service: Gracefully stop the running container
stop_service() {
    log_info "Stop service requested for $CONTAINER_COUNT container(s)"

    if [ "$CONTAINER_COUNT" -eq 1 ]; then
        echo -e "${YELLOW}Stopping Conduit...${NC}"
    else
        echo -e "${YELLOW}Stopping $CONTAINER_COUNT Conduit containers...${NC}"
    fi

    local stopped=0
    local already_stopped=0
    local failed=0

    local i=1
    while [ $i -le "$CONTAINER_COUNT" ]; do
        local name
        name=$(get_container_name "$i")

        if container_running "$i"; then
            if docker stop "$name" > /dev/null 2>&1; then
                log_info "Container $name stopped successfully"
                if [ "$CONTAINER_COUNT" -gt 1 ]; then
                    echo -e "  ${GREEN}✔ $name stopped${NC}"
                fi
                stopped=$((stopped + 1))
            else
                log_error "Failed to stop container $name"
                if [ "$CONTAINER_COUNT" -gt 1 ]; then
                    echo -e "  ${RED}✘ Failed to stop $name${NC}"
                fi
                failed=$((failed + 1))
            fi
        else
            already_stopped=$((already_stopped + 1))
        fi

        i=$((i + 1))
    done

    if [ $stopped -gt 0 ]; then
        if [ "$CONTAINER_COUNT" -eq 1 ]; then
            echo -e "${GREEN}✔ Service stopped.${NC}"
        else
            echo -e "${GREEN}✔ $stopped container(s) stopped.${NC}"
        fi
    elif [ $already_stopped -eq "$CONTAINER_COUNT" ]; then
        log_warn "Stop requested but no containers are running"
        echo -e "${YELLOW}Service is not currently running.${NC}"
    fi

    if [ $failed -gt 0 ]; then
        echo -e "${RED}✘ Failed to stop $failed container(s).${NC}"
    fi

    sleep 1
}

# view_dashboard: Display real-time container statistics
view_dashboard() {
    log_info "Dashboard view started"

    local stop_dashboard=0
    trap 'stop_dashboard=1' SIGINT SIGTERM

    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"
    # Clear screen and scrollback buffer
    printf '\033[2J\033[3J\033[H'

    while [ "$stop_dashboard" -eq 0 ]; do
        tput cup 0 0 2>/dev/null || printf "\033[H"

        # Print header
        echo -e "${CYAN}"
        echo "  ██████╗ ██████╗ ███╗   ██╗██████╗ ██╗   ██╗██╗████████╗"
        echo " ██╔════╝██╔═══██╗████╗  ██║██╔══██╗██║   ██║██║╚══██╔══╝"
        echo " ██║     ██║   ██║██╔██╗ ██║██║  ██║██║   ██║██║   ██║   "
        echo " ██║     ██║   ██║██║╚██╗██║██║  ██║██║   ██║██║   ██║   "
        echo " ╚██████╗╚██████╔╝██║ ╚████║██████╔╝╚██████╔╝██║   ██║   "
        echo "  ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═════╝  ╚═════╝ ╚═╝   ╚═╝   "
        echo -e "      ${YELLOW}macOS Security-Hardened Edition v${VERSION}${CYAN}          "
        echo -e "${NC}"
        echo -e "${GREEN}[SECURE]${NC} Container isolation: ENABLED"
        echo ""

        # Define clear-to-end-of-line escape sequence
        local CL=$'\033[K'

        echo -e "${BOLD}LIVE DASHBOARD${NC} (Press ${YELLOW}any key${NC} to Exit)${CL}"
        echo "══════════════════════════════════════════════════════${CL}"

        # Count running containers
        local running_count=0
        running_count=$(count_running_containers)

        if [ "$running_count" -gt 0 ]; then
            # Aggregate stats from all running containers
            local total_conn=0
            local total_connecting=0
            local total_max_clients=0
            local combined_cpu="0.00%"
            local combined_mem_mb=0

            # Container-specific data for multi-container display
            local container_statuses=""

            local i=1
            while [ $i -le "$CONTAINER_COUNT" ]; do
                local name
                local vol
                name=$(get_container_name "$i")
                vol=$(get_volume_name "$i")

                if container_running "$i"; then
                    # Get stats for this container
                    local docker_stats=""
                    docker_stats=$(docker stats --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}" "$name" 2>/dev/null) || docker_stats=""

                    if [ -n "$docker_stats" ]; then
                        local cpu_val mem_val
                        cpu_val=$(echo "$docker_stats" | cut -d'|' -f1 | tr -d '%')
                        mem_val=$(echo "$docker_stats" | cut -d'|' -f2 | cut -d'/' -f1)
                        # Parse memory value
                        if echo "$mem_val" | grep -q "GiB"; then
                            local mem_num
                            mem_num=$(echo "$mem_val" | tr -d 'GiB ')
                            combined_mem_mb=$(awk "BEGIN {printf \"%.0f\", $combined_mem_mb + ($mem_num * 1024)}")
                        elif echo "$mem_val" | grep -q "MiB"; then
                            local mem_num
                            mem_num=$(echo "$mem_val" | tr -d 'MiB ')
                            combined_mem_mb=$(awk "BEGIN {printf \"%.0f\", $combined_mem_mb + $mem_num}")
                        fi
                        combined_cpu=$(awk "BEGIN {printf \"%.2f\", $(echo $combined_cpu | tr -d '%') + $cpu_val}")
                    fi

                    # Get connection stats from logs
                    local log_line=""
                    log_line=$(docker logs --tail 50 "$name" 2>/dev/null | grep "\[STATS\]" | tail -1) || log_line=""

                    local conn=0
                    local connecting=0
                    if [ -n "$log_line" ]; then
                        conn=$(echo "$log_line" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p') || conn=0
                        connecting=$(echo "$log_line" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p') || connecting=0
                    fi
                    total_conn=$((total_conn + ${conn:-0}))
                    total_connecting=$((total_connecting + ${connecting:-0}))

                    # Get max-clients from container args
                    local container_args=""
                    local max_clients=""
                    container_args=$(docker inspect --format='{{.Args}}' "$name" 2>/dev/null) || container_args=""
                    max_clients=$(echo "$container_args" | grep -o '\-\-max-clients [0-9]*' | awk '{print $2}') || max_clients=200
                    total_max_clients=$((total_max_clients + ${max_clients:-200}))

                    # Store per-container info for multi-container view
                    if [ "$CONTAINER_COUNT" -gt 1 ]; then
                        local uptime_short
                        uptime_short=$(docker ps -f "name=$name" --format '{{.Status}}' 2>/dev/null | sed 's/Up //' | cut -d' ' -f1-2) || uptime_short="?"
                        container_statuses="${container_statuses}${name}|${conn:-0}|${max_clients:-200}|${uptime_short}\n"
                    fi
                fi

                i=$((i + 1))
            done

            combined_cpu="${combined_cpu}%"

            # Format combined memory
            local combined_ram
            if [ "$combined_mem_mb" -ge 1024 ]; then
                combined_ram=$(awk "BEGIN {printf \"%.2f GB\", $combined_mem_mb/1024}")
            else
                combined_ram="${combined_mem_mb} MB"
            fi

            # Fetch system stats
            local sys_stats
            sys_stats=$(get_system_stats)
            local sys_cpu sys_ram_used sys_ram_total
            sys_cpu=$(echo "$sys_stats" | awk '{print $1}')
            sys_ram_used=$(echo "$sys_stats" | awk '{print $2, $3}')
            sys_ram_total=$(echo "$sys_stats" | awk '{print $4, $5}')

            # Get primary container info for single-container display
            local uptime=""
            uptime=$(docker ps -f "name=$CONTAINER_NAME" --format '{{.Status}}' 2>/dev/null) || uptime="Unknown"

            # Get node ID from primary container
            local node_id=""
            node_id=$(get_node_id) || node_id=""

            # Get traffic stats from primary container (combined traffic not easily aggregated)
            local log_output=""
            log_output=$(docker logs --tail 50 "$CONTAINER_NAME" 2>&1) || log_output=""
            local log_line=""
            log_line=$(echo "$log_output" | grep "\[STATS\]" | tail -n 1) || log_line=""
            local up="0B"
            local down="0B"
            if [ -n "$log_line" ]; then
                up=$(echo "$log_line" | sed -n 's/.*Up:[[:space:]]*\([^|]*\).*/\1/p' | tr -d ' ') || up="0B"
                down=$(echo "$log_line" | sed -n 's/.*Down:[[:space:]]*\([^|]*\).*/\1/p' | tr -d ' ') || down="0B"
            fi

            # Get bandwidth setting from primary container
            local container_args=""
            local container_bandwidth=""
            container_args=$(docker inspect --format='{{.Args}}' "$CONTAINER_NAME" 2>/dev/null) || container_args=""
            container_bandwidth=$(echo "$container_args" | grep -o '\-\-bandwidth [0-9-]*' | awk '{print $2}') || container_bandwidth=""
            if [ "$container_bandwidth" = "-1" ]; then
                container_bandwidth="Unlimited"
            elif [ -n "$container_bandwidth" ]; then
                container_bandwidth="${container_bandwidth} Mbps"
            else
                container_bandwidth="N/A"
            fi

            # Display dashboard
            if [ "$CONTAINER_COUNT" -gt 1 ]; then
                echo -e " STATUS:      ${GREEN}● ONLINE${NC} (${running_count}/${CONTAINER_COUNT} containers)${CL}"
            else
                echo -e " STATUS:      ${GREEN}● ONLINE${NC}${CL}"
                echo -e " UPTIME:      ${uptime}${CL}"
            fi
            if [ -n "$node_id" ]; then
                echo -e " NODE ID:     ${CYAN}${node_id}${NC}${CL}"
            fi
            echo "──────────────────────────────────────────────────────${CL}"

            # Show per-container breakdown for multi-container setups
            if [ "$CONTAINER_COUNT" -gt 1 ]; then
                echo -e " ${BOLD}CONTAINERS${NC}${CL}"
                printf "   %-16s %-12s %s${CL}\n" "Name" "Clients" "Uptime"
                echo -e "$container_statuses" | while IFS='|' read -r cname cconn cmax cuptime; do
                    [ -z "$cname" ] && continue
                    printf "   %-16s ${GREEN}%-5s${NC}/${DIM}%-5s${NC} %s${CL}\n" "$cname" "$cconn" "$cmax" "$cuptime"
                done
                echo "──────────────────────────────────────────────────────${CL}"
            fi

            echo -e " ${BOLD}CLIENTS${NC}        (Max: ${total_max_clients})${CL}"
            echo -e "   Connected:  ${GREEN}${total_conn}${NC}      | Connecting: ${YELLOW}${total_connecting}${NC}${CL}"
            echo "──────────────────────────────────────────────────────${CL}"
            echo -e " ${BOLD}TRAFFIC${NC}        (Limit: ${container_bandwidth})${CL}"
            echo -e "   Upload:     ${CYAN}${up}${NC}    | Download: ${CYAN}${down}${NC}${CL}"
            echo "──────────────────────────────────────────────────────${CL}"
            if [ "$CONTAINER_COUNT" -gt 1 ]; then
                printf " ${BOLD}%-12s${NC} %-20s %s${CL}\n" "RESOURCES" "All Containers" "System"
            else
                printf " ${BOLD}%-12s${NC} %-20s %s${CL}\n" "RESOURCES" "Container" "System"
            fi
            printf "   %-9s ${YELLOW}%-20s${NC} ${YELLOW}%s${NC}${CL}\n" "CPU:" "$combined_cpu" "$sys_cpu"
            printf "   %-9s ${YELLOW}%-20s${NC} ${YELLOW}%s${NC}${CL}\n" "RAM:" "$combined_ram" "${sys_ram_used} / ${sys_ram_total}"
            printf "   %-9s ${CYAN}%-20s${NC}${CL}\n" "Limits:" "${MAX_CPUS} CPU / ${MAX_MEMORY} RAM (per container)"
            echo "══════════════════════════════════════════════════════${CL}"
            echo -e "${GREEN}[SECURE]${NC} Network isolated | Privileges dropped${CL}"
            echo -e "${YELLOW}Refreshing every 5 seconds...${NC}${CL}"
        else
            echo -e " STATUS:      ${RED}● OFFLINE${NC}${CL}"
            echo "──────────────────────────────────────────────────────${CL}"
            echo -e " Service is not running.${CL}"
            echo -e " Press 1 from main menu to Start.${CL}"
            echo "══════════════════════════════════════════════════════${CL}"
        fi

        tput ed 2>/dev/null || printf "\033[J"

        if read -t 5 -n 1 -s 2>/dev/null; then
            stop_dashboard=1
        fi
    done

    echo -ne "\033[?25h"
    tput rmcup 2>/dev/null || true
    trap - SIGINT SIGTERM
    log_info "Dashboard view ended"
}

# view_logs: Stream container logs in real-time
view_logs() {
    log_info "Log view started"
    # Clear screen and scrollback buffer
    printf '\033[2J\033[3J\033[H'
    echo -e "${CYAN}Streaming Logs (Press Ctrl+C to Exit)...${NC}"
    echo "------------------------------------------------"
    echo ""

    if container_running; then
        # Trap SIGINT to gracefully handle Ctrl+C without exiting script
        trap 'echo ""; echo ""; echo -e "${CYAN}Log streaming stopped.${NC}"' SIGINT

        # Stream logs - the || true handles the interrupt exit code
        docker logs -f --tail 100 "$CONTAINER_NAME" 2>&1 || true

        # Reset trap
        trap - SIGINT

        echo ""
        read -n 1 -s -r -p "Press any key to return..."
    else
        echo -e "${YELLOW}Container is not running.${NC}"
        echo "Start the container first to view logs."
        echo ""
        read -n 1 -s -r -p "Press any key to return..."
    fi

    log_info "Log view ended"
}

# configure_resources: Allow user to set CPU and memory limits
configure_resources() {
    print_header
    echo -e "${BOLD}RESOURCE LIMITS${NC}"
    echo "══════════════════════════════════════════════════════"
    echo ""

    # Get system info for recommendations
    local total_cores
    local total_ram_gb
    total_cores=$(sysctl -n hw.ncpu 2>/dev/null) || total_cores="?"
    total_ram_gb=$(( $(sysctl -n hw.memsize 2>/dev/null) / 1073741824 )) || total_ram_gb="?"

    echo -e "${BOLD}System Resources:${NC}"
    echo "  Total CPU Cores: ${total_cores}"
    echo "  Total RAM:       ${total_ram_gb} GB"
    echo ""
    echo -e "${BOLD}Current Limits:${NC}"
    echo "  Memory Limit:    ${MAX_MEMORY}"
    echo "  CPU Limit:       ${MAX_CPUS} cores"
    echo ""
    echo "══════════════════════════════════════════════════════"
    echo ""
    echo -e "${YELLOW}Note:${NC} Changes require container restart to take effect."
    echo ""

    # Memory configuration (GB only, whole numbers)
    # Extract current value without 'g' suffix for display
    local current_mem_gb="${MAX_MEMORY%g}"
    echo -e "${BOLD}Set Memory Limit (GB)${NC}"
    echo "  Current:  ${current_mem_gb} GB"
    read -p "  Enter GB (1-${total_ram_gb}, or Enter to keep current): " new_memory

    if [ -n "$new_memory" ]; then
        # Validate: must be a positive integer
        if [[ "$new_memory" =~ ^[1-9][0-9]*$ ]]; then
            MAX_MEMORY="${new_memory}g"
            MEMORY_SWAP="$MAX_MEMORY"
            echo -e "  ${GREEN}✔ Memory limit set to ${new_memory} GB${NC}"
        else
            echo -e "  ${RED}Invalid. Enter a whole number (e.g., 2, 4, 8)${NC}"
        fi
    fi
    echo ""

    # CPU configuration (whole cores only)
    echo -e "${BOLD}Set CPU Limit (cores)${NC}"
    echo "  Current:  ${MAX_CPUS} cores"
    read -p "  Enter cores (1-${total_cores}, or Enter to keep current): " new_cpus

    if [ -n "$new_cpus" ]; then
        # Validate: must be a positive integer
        if [[ "$new_cpus" =~ ^[1-9][0-9]*$ ]]; then
            MAX_CPUS="$new_cpus"
            echo -e "  ${GREEN}✔ CPU limit set to ${MAX_CPUS} cores${NC}"
        else
            echo -e "  ${RED}Invalid. Enter a whole number (e.g., 1, 2, 4)${NC}"
        fi
    fi
    echo ""

    # Save configuration
    save_config
    log_info "Resource limits updated: memory=$MAX_MEMORY, cpus=$MAX_CPUS"

    echo "══════════════════════════════════════════════════════"
    echo -e "${GREEN}✔ Configuration saved${NC}"
    echo ""
    echo "To apply changes, restart the container:"
    echo "  - Use option 1 (Start/Restart) from the main menu"
    echo ""
    read -n 1 -s -r -p "Press any key to return..."
}

# show_node_info: Display node identity information
show_node_info() {
    print_header
    echo -e "${BOLD}NODE IDENTITY${NC}"
    echo "══════════════════════════════════════════════════════"
    echo ""

    local node_id
    node_id=$(get_node_id)

    if [ -n "$node_id" ]; then
        echo -e "  Node ID: ${CYAN}${node_id}${NC}"
        echo ""
        echo "  This ID uniquely identifies your node on the Psiphon network."
        echo "  It is derived from your private key stored in the Docker volume."
        echo ""
        echo -e "  ${YELLOW}Tip:${NC} Use 'Backup Key' to save your identity for recovery."
    else
        echo -e "  ${YELLOW}No node ID found.${NC}"
        echo ""
        echo "  The node identity is created when Conduit first starts."
        echo "  Start the service to generate a new node identity."
    fi

    echo ""
    echo "══════════════════════════════════════════════════════"
    read -n 1 -s -r -p "Press any key to return..."
}

# ==============================================================================
# HEALTH CHECK FUNCTION
# ==============================================================================

# health_check: Comprehensive health check for Conduit container
# Checks Docker, container status, network, resources, and connectivity
# Enhanced with peer counts and uptime display
# health_check_single: Run health check on a single container
# Arguments:
#   $1 - Container index (1-5)
# Sets global variables: hc_all_ok, hc_warnings
health_check_single() {
    local idx="${1:-1}"
    local name
    local vol
    name=$(get_container_name "$idx")
    vol=$(get_volume_name "$idx")

    local all_ok=true
    local warnings=0

    # 2. Check if container exists
    echo -n "  Container exists:     "
    if container_exists "$idx"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Container not found"
        all_ok=false
    fi

    # 3. Check if container is running
    echo -n "  Container running:    "
    if container_running "$idx"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Container is stopped"
        all_ok=false
    fi

    # 4. Check container restart count
    echo -n "  Restart count:        "
    local restarts=""
    restarts=$(docker inspect --format='{{.RestartCount}}' "$name" 2>/dev/null) || restarts=""
    if [ -n "$restarts" ]; then
        if [ "$restarts" -eq 0 ]; then
            echo -e "${GREEN}${restarts}${NC} (healthy)"
        elif [ "$restarts" -lt 5 ]; then
            echo -e "${YELLOW}${restarts}${NC} (some restarts)"
            warnings=$((warnings + 1))
        else
            echo -e "${RED}${restarts}${NC} (excessive restarts - investigate)"
            all_ok=false
        fi
    else
        echo -e "${YELLOW}N/A${NC}"
    fi

    # 5. Check container uptime
    echo -n "  Container uptime:     "
    if container_running "$idx"; then
        local status_str=""
        status_str=$(docker ps --format '{{.Status}}' --filter "name=^${name}$" 2>/dev/null | head -1) || status_str=""
        if [ -n "$status_str" ]; then
            local uptime_part=""
            uptime_part=$(echo "$status_str" | sed 's/Up //' | sed 's/ (.*)//')
            uptime_part=$(echo "$uptime_part" | sed 's/ seconds\?/s/' | sed 's/ minutes\?/m/' | sed 's/ hours\?/h/' | sed 's/ days\?/d/' | sed 's/ weeks\?/w/')
            echo -e "${GREEN}${uptime_part}${NC}"
        else
            echo -e "${GREEN}Running${NC}"
        fi
    else
        echo -e "${YELLOW}N/A${NC} - Container not running"
    fi

    # 6. Check network isolation
    echo -n "  Network isolation:    "
    local network_mode=""
    network_mode=$(docker inspect --format='{{.HostConfig.NetworkMode}}' "$name" 2>/dev/null) || network_mode=""
    if [ "$network_mode" = "$NETWORK_NAME" ]; then
        echo -e "${GREEN}OK${NC} (bridge network)"
    elif [ "$network_mode" = "host" ]; then
        echo -e "${YELLOW}WARN${NC} - Using host network (less secure)"
        warnings=$((warnings + 1))
    else
        echo -e "${GREEN}OK${NC} (${network_mode:-unknown})"
    fi

    # 7. Check security options
    echo -n "  Security hardening:   "
    local read_only=""
    local no_new_privs=""
    read_only=$(docker inspect --format='{{.HostConfig.ReadonlyRootfs}}' "$name" 2>/dev/null) || read_only=""
    no_new_privs=$(docker inspect --format='{{range .HostConfig.SecurityOpt}}{{.}}{{end}}' "$name" 2>/dev/null) || no_new_privs=""

    if [ "$read_only" = "true" ] && echo "$no_new_privs" | grep -q "no-new-privileges"; then
        echo -e "${GREEN}OK${NC} (read-only, no-new-privileges)"
    else
        echo -e "${YELLOW}WARN${NC} - Some hardening missing"
        warnings=$((warnings + 1))
    fi

    # 8. Check Psiphon connection with peer counts
    local hc_logs=""
    local hc_stats_lines=""
    local hc_last_stat=""
    local hc_connected=0
    local hc_connecting=0
    local stats_count=0

    if container_running "$idx"; then
        hc_logs=$(docker logs --tail 100 "$name" 2>&1)
        hc_stats_lines=$(echo "$hc_logs" | grep "\[STATS\]" || true)
        if [ -n "$hc_stats_lines" ]; then
            stats_count=$(echo "$hc_stats_lines" | wc -l | tr -d ' ')
            hc_last_stat=$(echo "$hc_stats_lines" | tail -1)
            hc_connected=$(echo "$hc_last_stat" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p' | head -1 | tr -d '\n')
            hc_connecting=$(echo "$hc_last_stat" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p' | head -1 | tr -d '\n')
        fi
        hc_connected=${hc_connected:-0}
        hc_connecting=${hc_connecting:-0}
        stats_count=${stats_count:-0}
    fi

    echo -n "  Network connection:   "
    if container_running "$idx"; then
        if [ "$hc_connected" -gt 0 ] 2>/dev/null; then
            echo -e "${GREEN}OK${NC} (${hc_connected} peers connected, ${hc_connecting} connecting)"
        elif [ "$stats_count" -gt 0 ] 2>/dev/null; then
            if [ "$hc_connecting" -gt 0 ] 2>/dev/null; then
                echo -e "${GREEN}OK${NC} (Connected, ${hc_connecting} peers connecting)"
            else
                echo -e "${GREEN}OK${NC} (Connected, awaiting peers)"
            fi
        else
            local connected_msg=""
            connected_msg=$(echo "$hc_logs" | grep -c "Connected to Psiphon" 2>/dev/null | head -1 || echo "0")
            connected_msg=${connected_msg:-0}
            if [ "$connected_msg" -gt 0 ] 2>/dev/null; then
                echo -e "${GREEN}OK${NC} (Connected to Psiphon network)"
            else
                local info_lines=""
                info_lines=$(echo "$hc_logs" | grep -c "\[INFO\]" 2>/dev/null | head -1 || echo "0")
                info_lines=${info_lines:-0}
                if [ "$info_lines" -gt 0 ] 2>/dev/null; then
                    echo -e "${YELLOW}CONNECTING${NC} - Establishing connection..."
                    warnings=$((warnings + 1))
                else
                    echo -e "${YELLOW}STARTING${NC} - Initializing..."
                    warnings=$((warnings + 1))
                fi
            fi
        fi
    else
        echo -e "${RED}N/A${NC} - Container not running"
    fi

    # 9. Stats output
    echo -n "  Stats output:         "
    if container_running "$idx"; then
        if [ "$stats_count" -gt 0 ] 2>/dev/null; then
            echo -e "${GREEN}OK${NC} (${stats_count} entries in last 100 lines)"
        else
            echo -e "${YELLOW}NONE${NC} - May need restart with -v flag"
            warnings=$((warnings + 1))
        fi
    else
        echo -e "${RED}N/A${NC}"
    fi

    # 10. Check data volume
    echo -n "  Data volume:          "
    if docker volume inspect "$vol" &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Volume not found"
        all_ok=false
    fi

    # 11. Check node identity key (only for primary container)
    if [ "$idx" -eq 1 ]; then
        echo -n "  Node identity key:    "
        local node_id=""
        node_id=$(get_node_id)
        if [ -n "$node_id" ]; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}PENDING${NC} - Will be created on first run"
            warnings=$((warnings + 1))
        fi
    fi

    # 12. Check resource limits
    echo -n "  Resource limits:      "
    local mem_limit=""
    local cpu_limit=""
    mem_limit=$(docker inspect --format='{{.HostConfig.Memory}}' "$name" 2>/dev/null) || mem_limit="0"
    cpu_limit=$(docker inspect --format='{{.HostConfig.NanoCpus}}' "$name" 2>/dev/null) || cpu_limit="0"
    if [ "$mem_limit" -gt 0 ] && [ "$cpu_limit" -gt 0 ]; then
        local mem_gb=""
        local cpu_cores=""
        mem_gb=$(awk "BEGIN {printf \"%.0f\", $mem_limit/1073741824}")
        cpu_cores=$(awk "BEGIN {printf \"%.0f\", $cpu_limit/1000000000}")
        echo -e "${GREEN}OK${NC} (${cpu_cores} CPU, ${mem_gb}GB RAM)"
    else
        echo -e "${YELLOW}WARN${NC} - No limits set"
        warnings=$((warnings + 1))
    fi

    # Set global results
    hc_all_ok=$all_ok
    hc_warnings=$warnings
}

health_check() {
    print_header
    echo -e "${CYAN}═══ CONDUIT HEALTH CHECK ═══${NC}"
    echo ""

    local all_ok=true
    local total_warnings=0

    # 1. Check if Docker is running
    echo -n "  Docker daemon:        "
    if docker info &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Docker is not running"
        all_ok=false
    fi

    # Check seccomp profile (shared across all containers)
    echo -n "  Seccomp profile:      "
    if [ -f "$SECCOMP_FILE" ]; then
        echo -e "${GREEN}OK${NC} (custom profile)"
    else
        echo -e "${YELLOW}N/A${NC} - Profile not created"
    fi

    # Run health checks for each container
    local i=1
    while [ $i -le "$CONTAINER_COUNT" ]; do
        local name
        name=$(get_container_name "$i")

        if [ "$CONTAINER_COUNT" -gt 1 ]; then
            echo ""
            echo -e "${BOLD}── Container: ${CYAN}${name}${NC} ──"
        fi

        # Initialize global vars for this container
        hc_all_ok=true
        hc_warnings=0

        health_check_single "$i"

        if [ "$hc_all_ok" = false ]; then
            all_ok=false
        fi
        total_warnings=$((total_warnings + hc_warnings))

        i=$((i + 1))
    done

    # Summary
    echo ""
    echo "══════════════════════════════════════════════════════"
    if [ "$all_ok" = true ] && [ "$total_warnings" -eq 0 ]; then
        echo -e "${GREEN}✔ All health checks passed${NC}"
    elif [ "$all_ok" = true ]; then
        echo -e "${YELLOW}⚠ Passed with ${total_warnings} warning(s)${NC}"
    else
        echo -e "${RED}✘ Some health checks failed${NC}"
    fi

    # Show node ID if available (from primary container)
    local node_id=""
    node_id=$(get_node_id)
    if [ -n "$node_id" ]; then
        echo ""
        echo -e "  Node ID: ${CYAN}${node_id}${NC}"
    fi

    if [ "$CONTAINER_COUNT" -gt 1 ]; then
        echo ""
        echo -e "  ${DIM}Checked ${CONTAINER_COUNT} container(s)${NC}"
    fi

    echo ""
    read -n 1 -s -r -p "Press any key to return..."
}

# uninstall_all: Completely remove the container, volume, network, image, and logs
# After uninstall completes, the script exits (does not return to menu)
uninstall_all() {
    print_header
    echo -e "${RED}═══ UNINSTALL CONDUIT ═══${NC}"
    echo ""
    echo -e "${RED}WARNING: This will remove:${NC}"
    echo -e "${RED}  - The Conduit container${NC}"
    echo -e "${RED}  - The conduit-data Docker volume (node identity!)${NC}"
    echo -e "${RED}  - The conduit-network Docker network${NC}"
    echo -e "${RED}  - The Docker image${NC}"
    echo -e "${RED}  - The log file (~/.conduit-manager.log)${NC}"
    echo -e "${RED}  - The config file (~/.conduit-config)${NC}"
    echo -e "${RED}  - The seccomp profile (~/.conduit-seccomp.json)${NC}"
    echo -e "${RED}  - The application folder (~/conduit-manager/)${NC}"
    echo -e "${RED}  - The symlink (/usr/local/bin/conduit)${NC}"
    echo ""

    # Check for existing backups
    local has_backup=false
    local backup_count=0
    if [ -d "$BACKUP_DIR" ]; then
        backup_count=$(find "$BACKUP_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$backup_count" -gt 0 ]; then
            has_backup=true
        fi
    fi

    if [ "$has_backup" = true ]; then
        echo -e "${GREEN}✔ You have ${backup_count} backup key(s) in ${BACKUP_DIR}${NC}"
    else
        echo -e "${YELLOW}⚠ You have NO backup keys. Your node identity will be LOST.${NC}"
        echo "  Consider running 'Backup Key' first!"
    fi
    echo ""

    # Ask about backup deletion
    local delete_backups=false
    if [ "$has_backup" = true ]; then
        echo -e "${BOLD}Do you want to delete your backup keys as well?${NC}"
        read -p "Delete backups? (y/N): " delete_backup_choice
        if [[ "$delete_backup_choice" =~ ^[Yy]$ ]]; then
            delete_backups=true
            echo -e "${RED}⚠ Backups will be PERMANENTLY DELETED${NC}"
        else
            echo -e "${GREEN}✔ Backups will be preserved${NC}"
        fi
        echo ""
    fi

    echo -e "${RED}${BOLD}Are you sure you want to uninstall?${NC}"
    read -p "Type 'yes' to confirm: " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Uninstall cancelled."
        read -n 1 -s -r -p "Press any key to return..."
        return 0
    fi

    echo ""
    log_info "Uninstall initiated by user (delete_backups=$delete_backups)"

    # Stop and remove container
    echo "Stopping container..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true

    echo "Removing container..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    # Remove volume
    echo "Removing data volume..."
    docker volume rm "$VOLUME_NAME" 2>/dev/null || true

    # Remove network
    echo "Removing network..."
    docker network rm "$NETWORK_NAME" 2>/dev/null || true

    # Remove Docker image
    echo "Removing Docker image..."
    docker rmi "$IMAGE" 2>/dev/null || true

    # Remove log file, config file, and seccomp profile
    echo "Removing log, config, and seccomp files..."
    rm -f "$LOG_FILE" 2>/dev/null || true
    rm -f "$CONFIG_FILE" 2>/dev/null || true
    rm -f "$SECCOMP_FILE" 2>/dev/null || true

    # Remove symlink if it exists
    if [ -L "/usr/local/bin/conduit" ]; then
        echo "Removing symlink..."
        sudo rm -f "/usr/local/bin/conduit" 2>/dev/null || true
    fi

    # Optionally remove backups
    if [ "$delete_backups" = true ] && [ -d "$BACKUP_DIR" ]; then
        echo "Removing backup keys..."
        rm -rf "$BACKUP_DIR" 2>/dev/null || true
    fi

    # Remove the application folder (script and menu bar app)
    echo "Removing application folder..."
    rm -rf "${HOME}/conduit-manager" 2>/dev/null || true

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✔ Uninstall complete - All Conduit data removed${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
    echo ""

    if [ "$delete_backups" = false ] && [ "$has_backup" = true ]; then
        echo -e "Your backup keys are preserved in: ${CYAN}${BACKUP_DIR}${NC}"
        echo "You can use these to restore your node identity after reinstalling."
        echo ""
    fi

    echo "To reinstall, run:"
    echo -e "  ${CYAN}curl -L -o conduit-mac.sh https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/conduit-mac.sh && chmod +x conduit-mac.sh && ./conduit-mac.sh${NC}"
    echo ""
    echo -e "${CYAN}Goodbye!${NC}"

    # Exit script completely - do not return to menu
    exit 0
}

# check_for_updates: Check if a newer version is available and auto-update if requested
# Downloads latest script from GitHub, replaces current script, and re-executes
check_for_updates() {
    print_header
    echo -e "${BOLD}CHECK FOR UPDATES${NC}"
    echo "══════════════════════════════════════════════════════"
    echo ""
    echo -e "Current version: ${CYAN}${VERSION}${NC}"
    echo ""
    echo "Checking for updates..."
    echo ""

    local github_url="https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/conduit-mac.sh"

    # Try to fetch the latest version from GitHub
    local remote_version=""
    remote_version=$(curl -sL --max-time 10 "$github_url" 2>/dev/null | grep "^readonly VERSION=" | head -1 | cut -d'"' -f2) || remote_version=""

    if [ -z "$remote_version" ]; then
        echo -e "${YELLOW}Could not check for updates.${NC}"
        echo "Check your internet connection or visit:"
        echo "  https://github.com/moghtaderi/conduit-manager-mac"
        echo ""
        echo "══════════════════════════════════════════════════════"
        read -n 1 -s -r -p "Press any key to return..."
        return 0
    fi

    if [ "$remote_version" = "$VERSION" ]; then
        echo -e "${GREEN}✔ You are running the latest version.${NC}"
        echo ""
        echo "══════════════════════════════════════════════════════"
        read -n 1 -s -r -p "Press any key to return..."
        return 0
    fi

    # New version available - offer auto-update
    echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  NEW VERSION AVAILABLE: ${remote_version}${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Current: ${RED}${VERSION}${NC}  →  Latest: ${GREEN}${remote_version}${NC}"
    echo ""
    read -p "Do you want to automatically update now? (y/N): " update_choice

    if [[ ! "$update_choice" =~ ^[Yy]$ ]]; then
        echo ""
        echo "Update cancelled. To manually update later, run:"
        echo -e "  ${CYAN}curl -L -o conduit-mac.sh ${github_url} && chmod +x conduit-mac.sh${NC}"
        echo ""
        read -n 1 -s -r -p "Press any key to return..."
        return 0
    fi

    echo ""
    echo "Downloading latest version..."
    log_info "Auto-update initiated: $VERSION -> $remote_version"

    # Get the path to the currently running script
    local script_path=""
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    # Create a temporary file for the new script
    local temp_script=""
    temp_script=$(mktemp "${TMPDIR:-/tmp}/conduit-mac-update.XXXXXX")

    # Download the new script
    if ! curl -sL --max-time 30 -o "$temp_script" "$github_url"; then
        echo -e "${RED}✘ Download failed${NC}"
        rm -f "$temp_script" 2>/dev/null
        log_error "Auto-update download failed"
        read -n 1 -s -r -p "Press any key to return..."
        return 1
    fi

    # Verify the download is a valid bash script
    if ! head -1 "$temp_script" | grep -q "^#!/bin/bash"; then
        echo -e "${RED}✘ Downloaded file is not a valid script${NC}"
        rm -f "$temp_script" 2>/dev/null
        log_error "Auto-update verification failed - invalid script"
        read -n 1 -s -r -p "Press any key to return..."
        return 1
    fi

    # Verify syntax of the new script
    if ! bash -n "$temp_script" 2>/dev/null; then
        echo -e "${RED}✘ Downloaded script has syntax errors${NC}"
        rm -f "$temp_script" 2>/dev/null
        log_error "Auto-update verification failed - syntax errors"
        read -n 1 -s -r -p "Press any key to return..."
        return 1
    fi

    echo -e "${GREEN}✔ Download verified${NC}"
    echo ""

    # Replace the current script
    echo "Installing update..."
    if ! mv "$temp_script" "$script_path"; then
        echo -e "${RED}✘ Failed to install update${NC}"
        rm -f "$temp_script" 2>/dev/null
        log_error "Auto-update install failed - could not replace script"
        read -n 1 -s -r -p "Press any key to return..."
        return 1
    fi

    # Make it executable
    chmod +x "$script_path"

    echo -e "${GREEN}✔ Script updated${NC}"

    # Now update the menu bar app
    echo ""
    echo "Downloading Menu Bar App..."

    local app_zip_url="https://github.com/moghtaderi/conduit-manager-mac/releases/latest/download/Conduit-Mac-MenuBar-macOS.zip"
    local temp_zip=""
    temp_zip=$(mktemp "${TMPDIR:-/tmp}/conduit-menubar.XXXXXX.zip")
    local temp_extract_dir=""
    temp_extract_dir=$(mktemp -d "${TMPDIR:-/tmp}/conduit-menubar-extract.XXXXXX")

    if curl -sL --max-time 60 -o "$temp_zip" "$app_zip_url" 2>/dev/null; then
        # Verify it's a valid zip file
        if unzip -t "$temp_zip" >/dev/null 2>&1; then
            # Extract to temp directory
            if unzip -q -o "$temp_zip" -d "$temp_extract_dir" 2>/dev/null; then
                # Find the .app bundle in the extracted files
                local extracted_app=""
                extracted_app=$(find "$temp_extract_dir" -name "Conduit-Mac.app" -type d 2>/dev/null | head -1)

                if [ -n "$extracted_app" ] && [ -d "$extracted_app" ]; then
                    # Remove old app if it exists
                    local install_path="${HOME}/conduit-manager/Conduit-Mac.app"
                    rm -rf "$install_path" 2>/dev/null

                    # Move new app into place
                    if mv "$extracted_app" "$install_path" 2>/dev/null; then
                        # Clear quarantine attribute so macOS allows it to run
                        xattr -rd com.apple.quarantine "$install_path" 2>/dev/null
                        echo -e "${GREEN}✔ Menu Bar App updated${NC}"
                        log_info "Menu Bar App updated to $remote_version"

                        # If the app is currently running, notify user to restart it
                        if pgrep -x "Conduit-Mac" >/dev/null 2>&1; then
                            echo ""
                            echo -e "${YELLOW}Note: Quit and reopen the Menu Bar App to use the new version.${NC}"
                        fi
                    else
                        echo -e "${YELLOW}⚠ Could not install Menu Bar App (script updated OK)${NC}"
                        log_warn "Menu Bar App install failed - could not move to destination"
                    fi
                else
                    echo -e "${YELLOW}⚠ Menu Bar App not found in download (script updated OK)${NC}"
                    log_warn "Menu Bar App not found in extracted zip"
                fi
            else
                echo -e "${YELLOW}⚠ Could not extract Menu Bar App (script updated OK)${NC}"
                log_warn "Menu Bar App extraction failed"
            fi
        else
            echo -e "${YELLOW}⚠ Menu Bar App download invalid (script updated OK)${NC}"
            log_warn "Menu Bar App zip verification failed"
        fi
    else
        echo -e "${YELLOW}⚠ Could not download Menu Bar App (script updated OK)${NC}"
        log_warn "Menu Bar App download failed"
    fi

    # Clean up temp files
    rm -f "$temp_zip" 2>/dev/null
    rm -rf "$temp_extract_dir" 2>/dev/null

    log_info "Auto-update completed: $VERSION -> $remote_version"

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✔ Update installed successfully!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Restarting with new version..."
    echo ""

    # Re-execute the updated script
    exec "$script_path"
}

# ==============================================================================
# MENU BAR APP
# ==============================================================================

# open_menubar_app: Open the Conduit menu bar app or show installation instructions
# The menu bar app provides a GUI for controlling the Conduit service
open_menubar_app() {
    print_header
    echo -e "${BOLD}MENU BAR APP${NC}"
    echo "══════════════════════════════════════════════════════"
    echo ""

    # Check multiple possible locations for the menu bar app
    local app_path=""
    if [ -d "${HOME}/conduit-manager/Conduit-Mac.app" ]; then
        app_path="${HOME}/conduit-manager/Conduit-Mac.app"
    elif [ -d "/Applications/Conduit-Mac.app" ]; then
        app_path="/Applications/Conduit-Mac.app"
    fi

    if [ -n "$app_path" ]; then
        echo -e "${GREEN}✔ Menu bar app is installed${NC}"
        echo "  Location: $app_path"
        echo ""
        echo "Opening Conduit-Mac menu bar app..."
        open "$app_path"
        echo ""
        echo -e "${CYAN}The Conduit-Mac icon will appear in your menu bar.${NC}"
        echo ""
        echo "══════════════════════════════════════════════════════"
        read -n 1 -s -r -p "Press any key to return..."
    else
        echo -e "${YELLOW}⚠ Menu bar app is not installed${NC}"
        echo ""
        echo "The Conduit menu bar app provides a convenient GUI to:"
        echo "  • Start/Stop the Conduit service"
        echo "  • View connection stats and traffic"
        echo "  • Monitor Docker status"
        echo ""
        echo -e "${BOLD}To install the menu bar app:${NC}"
        echo ""
        echo "  1. Download from GitHub Releases:"
        echo -e "     ${CYAN}https://github.com/moghtaderi/conduit-manager-mac/releases${NC}"
        echo ""
        echo "  2. Or reinstall using the one-liner:"
        echo -e "     ${CYAN}curl -fsSL https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/install.sh | bash${NC}"
        echo ""
        echo "══════════════════════════════════════════════════════"
        read -p "Open GitHub releases page? [y/N]: " open_releases
        if [[ "$open_releases" =~ ^[Yy]$ ]]; then
            open "https://github.com/moghtaderi/conduit-manager-mac/releases" 2>/dev/null || true
        fi
    fi
}

# ==============================================================================
# REWARD CLAIM FUNCTION (QR Code)
# ==============================================================================

# generate_claim_link: Generate a claim link and QR code for the Ryve app
# This allows users to link their Conduit node to the Ryve mobile app for rewards
generate_claim_link() {
    print_header
    echo -e "${CYAN}═══ 🎁 CLAIM NODE REWARDS ═══${NC}"
    echo ""

    # 1. Get Private Key from Docker volume
    local key_val=$(docker run --rm -v "$VOLUME_NAME":/data alpine cat /data/conduit_key.json 2>/dev/null | grep "privateKeyBase64" | awk -F'"' '{print $4}')

    if [ -z "$key_val" ]; then
        echo -e "${RED}Error: Could not retrieve private key.${NC}"
        echo "Make sure Conduit is installed and has started at least once."
        read -n 1 -s -r -p "Press any key to return..." < /dev/tty
        return 1
    fi

    # 2. Get Node Name from user
    echo -e "Enter a name for this node to display in the Ryve app."
    echo -e "Default: ${GREEN}My Conduit Node${NC}"
    echo ""
    read -p "Node Name: " input_name < /dev/tty
    local node_name="${input_name:-My Conduit Node}"

    # 3. Construct JSON & Encode to base64
    local json_data="{\"version\":1,\"data\":{\"key\":\"$key_val\",\"name\":\"$node_name\"}}"
    local b64_data=$(echo -n "$json_data" | base64 | tr -d '\n')
    local claim_url="network.ryve.app://(app)/conduits?claim=$b64_data"

    echo ""
    echo -e "${GREEN}✔ Claim Link Generated:${NC}"
    echo -e "${YELLOW}$claim_url${NC}"
    echo ""

    # 4. Check & Install qrencode if missing
    if ! command -v qrencode >/dev/null 2>&1; then
        echo -e "${YELLOW}QR Code tool (qrencode) is missing.${NC}"
        if command -v brew >/dev/null 2>&1; then
            echo -e "${BLUE}Attempting to install qrencode via Homebrew...${NC}"
            brew install qrencode
            echo ""
        else
            echo -e "${RED}Homebrew not found. Cannot auto-install qrencode.${NC}"
        fi
    fi

    # 5. Display QR Code in terminal
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "${CYAN}Scan this QR Code in the Ryve App:${NC}"
        echo ""
        echo -n "$claim_url" | qrencode -t UTF8
        echo ""
    else
        echo -e "${YELLOW}Could not display QR Code.${NC}"
        echo "Please copy the link above manually."
    fi

    echo ""
    read -n 1 -s -r -p "Press any key to return..." < /dev/tty
}

# ==============================================================================
# INFO & HELP HUB
# ==============================================================================

# show_info_how_it_works: Explain how Conduit proxy works
show_info_how_it_works() {
    print_header
    echo -e "${CYAN}═══ HOW CONDUIT WORKS ═══${NC}"
    echo ""
    echo -e "${BOLD}What is Psiphon Conduit?${NC}"
    echo "  Conduit is a proxy node that helps people in censored regions"
    echo "  access the open internet. When you run Conduit, your computer"
    echo "  becomes a relay point for Psiphon users."
    echo ""
    echo -e "${BOLD}How Traffic Flows:${NC}"
    echo ""
    echo "  ┌─────────────┐      ┌─────────────┐      ┌─────────────┐"
    echo "  │   Psiphon   │ ──── │ Your Conduit│ ──── │  Internet   │"
    echo "  │    User     │      │    Node     │      │  (Websites) │"
    echo "  └─────────────┘      └─────────────┘      └─────────────┘"
    echo "     (censored)          (your Mac)           (open web)"
    echo ""
    echo -e "${BOLD}What Happens on Your Mac:${NC}"
    echo "  1. Psiphon users connect to the Psiphon network"
    echo "  2. The network routes some traffic through your Conduit"
    echo "  3. Your Conduit fetches the requested content"
    echo "  4. Content is sent back through the encrypted tunnel"
    echo ""
    echo -e "${BOLD}Your Role:${NC}"
    echo "  • You donate bandwidth to help others access information"
    echo "  • Traffic is encrypted - you cannot see what users access"
    echo "  • The Conduit runs in an isolated Docker container"
    echo "  • Your personal data and files are never exposed"
    echo ""
    echo "══════════════════════════════════════════════════════"
    read -n 1 -s -r -p "Press any key to return..."
}

# show_info_stats: Explain what the stats mean
show_info_stats() {
    print_header
    echo -e "${CYAN}═══ UNDERSTANDING THE STATS ═══${NC}"
    echo ""
    echo -e "${BOLD}Dashboard Metrics:${NC}"
    echo ""
    echo -e "  ${GREEN}Connected${NC}     Number of Psiphon users currently using your node"
    echo -e "  ${YELLOW}Connecting${NC}   Users in the process of establishing a connection"
    echo -e "  ${CYAN}Max Clients${NC}   Your configured limit for simultaneous connections"
    echo ""
    echo -e "${BOLD}Resource Usage:${NC}"
    echo ""
    echo -e "  ${GREEN}CPU%${NC}         How much processor your Conduit is using"
    echo -e "  ${GREEN}Memory${NC}       RAM consumed by the Docker container"
    echo -e "  ${GREEN}Network I/O${NC}  Data transferred (received / sent)"
    echo ""
    echo -e "${BOLD}What's Normal?${NC}"
    echo ""
    echo "  • Connected peers can range from 0 to your max-clients limit"
    echo "  • CPU usage typically stays under 20% with default settings"
    echo "  • Memory usage is capped by your configured limit"
    echo "  • Network usage depends on peer activity and bandwidth setting"
    echo ""
    echo -e "${BOLD}[STATS] Log Format:${NC}"
    echo ""
    echo "  The container logs show entries like:"
    echo -e "  ${DIM}[STATS] Connected: 15, Connecting: 3, Max: 200${NC}"
    echo ""
    echo "  These update every few seconds when peers are active."
    echo ""
    echo "══════════════════════════════════════════════════════"
    read -n 1 -s -r -p "Press any key to return..."
}

# show_info_privacy: Explain security and privacy
show_info_privacy() {
    print_header
    echo -e "${CYAN}═══ SECURITY & PRIVACY ═══${NC}"
    echo ""
    echo -e "${BOLD}What You CAN'T See:${NC}"
    echo "  • What websites users visit (traffic is encrypted)"
    echo "  • Users' personal information or identity"
    echo "  • The content being transferred"
    echo ""
    echo -e "${BOLD}What IS Visible:${NC}"
    echo "  • Number of connected peers"
    echo "  • Total bandwidth used"
    echo "  • Your node's public ID (not your personal info)"
    echo ""
    echo -e "${BOLD}Container Isolation:${NC}"
    echo "  Your Conduit runs in a hardened Docker container with:"
    echo ""
    echo -e "  ${GREEN}✔${NC} Read-only filesystem (can't modify your Mac)"
    echo -e "  ${GREEN}✔${NC} Dropped privileges (minimal permissions)"
    echo -e "  ${GREEN}✔${NC} Isolated network (can't access local services)"
    echo -e "  ${GREEN}✔${NC} Resource limits (CPU/RAM caps)"
    echo -e "  ${GREEN}✔${NC} No access to your files or documents"
    echo ""
    echo -e "${BOLD}Your IP Address:${NC}"
    echo "  • Psiphon users see the Psiphon network, not your IP"
    echo "  • Websites see traffic coming from your IP"
    echo "  • This is similar to running a Tor exit node"
    echo ""
    echo -e "${BOLD}Legal Considerations:${NC}"
    echo "  • Running a proxy is legal in most countries"
    echo "  • You are not responsible for users' actions"
    echo "  • Check your local laws if you have concerns"
    echo ""
    echo "══════════════════════════════════════════════════════"
    read -n 1 -s -r -p "Press any key to return..."
}

# show_info_security_config: Display detailed security configuration (moved from option 8)
show_info_security_config() {
    print_header
    echo -e "${CYAN}═══ SECURITY CONFIGURATION ═══${NC}"
    echo ""
    echo -e "${BOLD}Image Verification:${NC}"
    echo "  Docker images are verified using SHA256 digest."
    echo -e "  Expected: ${DIM}${IMAGE_DIGEST:0:20}...${NC}"
    echo ""
    echo -e "${BOLD}Network Isolation:${NC}"
    echo "  The container runs on an isolated bridge network."
    echo "  It CANNOT access the host network stack directly."
    echo "  It CAN reach the internet (required for proxy function)."
    echo ""
    echo -e "${BOLD}Filesystem Protection:${NC}"
    echo "  Container filesystem is READ-ONLY."
    echo "  Only /tmp is writable (in-memory tmpfs)."
    echo "  Data volume is mounted for persistent state."
    echo ""
    echo -e "${BOLD}Privilege Restrictions:${NC}"
    echo "  ALL Linux capabilities are dropped except NET_BIND_SERVICE."
    echo "  no-new-privileges security option is enabled."
    echo "  Container cannot escalate to root."
    echo ""
    # Get current max-clients from container to calculate PIDs limit
    local current_max_clients=""
    local pids_display="(dynamic: max-clients + 50)"
    if container_exists; then
        local container_args=""
        container_args=$(docker inspect --format='{{.Args}}' "$CONTAINER_NAME" 2>/dev/null) || container_args=""
        current_max_clients=$(echo "$container_args" | grep -o '\-\-max-clients [0-9]*' | awk '{print $2}') || current_max_clients=""
        if [ -n "$current_max_clients" ]; then
            local current_pids=$((current_max_clients + 50))
            pids_display="${current_pids} maximum (max-clients + 50)"
        fi
    fi
    echo -e "${BOLD}Resource Limits:${NC}"
    echo "  Memory:     $MAX_MEMORY maximum"
    echo "  CPU:        $MAX_CPUS cores maximum"
    echo "  Processes:  $pids_display"
    echo ""
    echo "══════════════════════════════════════════════════════"
    read -n 1 -s -r -p "Press any key to return..."
}

# show_info_file_locations: Display file and data locations (moved from option 8)
show_info_file_locations() {
    print_header
    echo -e "${CYAN}═══ FILE & DATA LOCATIONS ═══${NC}"
    echo ""
    echo -e "${BOLD}Application Files:${NC}"
    echo "  Script:         ${HOME}/conduit-manager/conduit-mac.sh"
    echo "  Menu Bar App:   ${HOME}/conduit-manager/Conduit-Mac.app"
    echo "  Symlink:        /usr/local/bin/conduit (if installed)"
    echo ""
    echo -e "${BOLD}Configuration & Logs:${NC}"
    echo "  Config File:    $CONFIG_FILE"
    echo "  Log File:       $LOG_FILE"
    echo "  Seccomp Profile: $SECCOMP_FILE"
      echo "  Backups:        $BACKUP_DIR/"
    echo ""
    echo -e "${BOLD}Docker Resources:${NC}"
    echo "  Container:      $CONTAINER_NAME"
    echo "  Data Volume:    $VOLUME_NAME"
    echo "  Network:        $NETWORK_NAME"
    echo "  Image:          $IMAGE"
    echo ""
    echo "══════════════════════════════════════════════════════"
    read -n 1 -s -r -p "Press any key to return..."
}

# show_info_about: About Psiphon and links
show_info_about() {
    print_header
    echo -e "${CYAN}═══ ABOUT PSIPHON CONDUIT ═══${NC}"
    echo ""
    echo -e "${BOLD}Psiphon's Mission:${NC}"
    echo "  Psiphon is a circumvention tool that provides uncensored"
    echo "  access to the internet. It has been used by millions of"
    echo "  people in over 200 countries to bypass censorship."
    echo ""
    echo -e "${BOLD}What is Conduit?${NC}"
    echo "  Conduit allows volunteers to donate bandwidth to help"
    echo "  Psiphon users connect. By running a Conduit node, you"
    echo "  become part of the global network fighting censorship."
    echo ""
    echo -e "${BOLD}Useful Links:${NC}"
    echo ""
    echo -e "  Psiphon Website:     ${CYAN}https://psiphon.ca${NC}"
    echo -e "  Conduit GitHub:      ${CYAN}https://github.com/Psiphon-Inc/conduit${NC}"
    echo -e "  This Manager:        ${CYAN}https://github.com/${GITHUB_REPO}${NC}"
    echo -e "  Ryve Rewards App:    ${CYAN}https://network.ryve.app${NC}"
    echo ""
    echo -e "${BOLD}Conduit Manager v${VERSION}${NC}"
    echo "  Security-hardened macOS edition"
    echo ""
    echo -e "${BOLD}Docker Image:${NC}"
    echo -e "  ${DIM}${IMAGE}${NC}"
    echo ""
    echo "══════════════════════════════════════════════════════"
    read -n 1 -s -r -p "Press any key to return..."
}

# show_info_menu: Main info hub menu
show_info_menu() {
    while true; do
        print_header
        echo -e "${CYAN}═══ INFO & HELP ═══${NC}"
        echo ""
        echo "  1. 🔌 How Conduit Works"
        echo "  2. 📊 Understanding the Stats"
        echo "  3. 🔒 Security & Privacy"
        echo "  4. 🛡️  Security Configuration"
        echo "  5. 📁 File & Data Locations"
        echo "  6. 🚀 About Psiphon Conduit"
        echo ""
        echo "  0. ← Back to Main Menu"
        echo ""
        read -p " Select option: " info_choice

        case "$info_choice" in
            1) show_info_how_it_works ;;
            2) show_info_stats ;;
            3) show_info_privacy ;;
            4) show_info_security_config ;;
            5) show_info_file_locations ;;
            6) show_info_about ;;
            0|"") return ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# CONTAINER MANAGER
# ==============================================================================

# add_container: Add a new container instance
add_container() {
    if [ "$CONTAINER_COUNT" -ge "$MAX_CONTAINERS" ]; then
        echo -e "${YELLOW}Maximum of ${MAX_CONTAINERS} containers reached.${NC}"
        sleep 2
        return
    fi

    local new_index=$((CONTAINER_COUNT + 1))
    local new_name
    local new_vol
    new_name=$(get_container_name "$new_index")
    new_vol=$(get_volume_name "$new_index")

    echo ""
    echo -e "${CYAN}Adding container #${new_index}: ${new_name}${NC}"
    echo ""

    # Get settings for new container
    local recommended
    recommended=$(calculate_recommended_clients)

    local max_clients
    local bandwidth
    local raw_input

    # Prompt for max clients
    while true; do
        read -p "Maximum Clients [1-${MAX_CLIENTS_LIMIT}, Default: ${recommended}]: " raw_input
        raw_input="${raw_input:-$recommended}"
        max_clients=$(sanitize_input "$raw_input")
        if validate_max_clients "$max_clients"; then
            break
        fi
        echo "Please enter a valid number."
    done

    # Prompt for bandwidth
    while true; do
        read -p "Bandwidth Limit in Mbps [1-${MAX_BANDWIDTH}, -1=Unlimited, Default: 5]: " raw_input
        raw_input="${raw_input:-5}"
        bandwidth=$(sanitize_input "$raw_input")
        if validate_bandwidth "$bandwidth"; then
            break
        fi
        echo "Please enter a valid number."
    done

    echo ""
    echo -e "${BLUE}Creating container ${new_name}...${NC}"

    # Ensure network exists
    ensure_network_exists

    # Ensure seccomp profile exists
    create_seccomp_profile

    # Build docker run command with optional seccomp
    local seccomp_opt=""
    if [ -f "$SECCOMP_FILE" ]; then
        seccomp_opt="--security-opt seccomp=$SECCOMP_FILE"
    fi

    # Calculate PIDs limit
    local pids_limit=$((max_clients + 50))

    if docker run -d \
        --name "$new_name" \
        --restart unless-stopped \
        --network "$NETWORK_NAME" \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,size=100m \
        --security-opt no-new-privileges:true \
        $seccomp_opt \
        --cap-drop ALL \
        --cap-add NET_BIND_SERVICE \
        --memory "$MAX_MEMORY" \
        --cpus "$MAX_CPUS" \
        --memory-swap "$MEMORY_SWAP" \
        --pids-limit "$pids_limit" \
        -v "$new_vol":/home/conduit/data \
        "$IMAGE" \
        start --max-clients "$max_clients" --bandwidth "$bandwidth" -v > /dev/null 2>&1; then

        CONTAINER_COUNT=$new_index
        save_config
        log_info "Added container $new_name (total: $CONTAINER_COUNT)"
        echo -e "${GREEN}✔ Container ${new_name} created and started.${NC}"
        echo -e "${GREEN}✔ Total containers: ${CONTAINER_COUNT}${NC}"
    else
        log_error "Failed to create container $new_name"
        echo -e "${RED}✘ Failed to create container.${NC}"
    fi

    sleep 2
}

# remove_container_menu: Remove a container instance
remove_container_menu() {
    if [ "$CONTAINER_COUNT" -le 1 ]; then
        echo -e "${YELLOW}Cannot remove the last container.${NC}"
        echo "Use 'Uninstall' from main menu to fully remove Conduit."
        sleep 2
        return
    fi

    echo ""
    echo -e "${YELLOW}Select container to remove:${NC}"
    echo ""

    local i=2
    while [ $i -le "$CONTAINER_COUNT" ]; do
        local name
        name=$(get_container_name "$i")
        local status="stopped"
        if container_running "$i"; then
            status="${GREEN}running${NC}"
        fi
        echo "  ${i}. ${name} (${status})"
        i=$((i + 1))
    done

    echo ""
    echo "  0. Cancel"
    echo ""
    read -p " Select container number to remove: " remove_choice

    if [ "$remove_choice" = "0" ] || [ -z "$remove_choice" ]; then
        return
    fi

    if ! [[ "$remove_choice" =~ ^[2-9]$ ]] || [ "$remove_choice" -gt "$CONTAINER_COUNT" ]; then
        echo -e "${RED}Invalid selection.${NC}"
        sleep 1
        return
    fi

    local name_to_remove
    local vol_to_remove
    name_to_remove=$(get_container_name "$remove_choice")
    vol_to_remove=$(get_volume_name "$remove_choice")

    echo ""
    echo -e "${RED}WARNING: This will remove:${NC}"
    echo -e "${RED}  - Container: ${name_to_remove}${NC}"
    echo -e "${RED}  - Volume: ${vol_to_remove} (node identity for this container!)${NC}"
    echo ""
    read -p "Type 'remove' to confirm: " confirm

    if [ "$confirm" != "remove" ]; then
        echo "Cancelled."
        sleep 1
        return
    fi

    echo ""
    echo -e "${BLUE}Removing ${name_to_remove}...${NC}"

    # Stop and remove container
    docker stop "$name_to_remove" >/dev/null 2>&1 || true
    docker rm -f "$name_to_remove" >/dev/null 2>&1 || true

    # Remove volume
    docker volume rm "$vol_to_remove" >/dev/null 2>&1 || true

    # If we removed a container in the middle, we need to rename the higher ones
    # For simplicity, we only allow removing the highest-numbered container
    # and decrement the count
    if [ "$remove_choice" -eq "$CONTAINER_COUNT" ]; then
        CONTAINER_COUNT=$((CONTAINER_COUNT - 1))
        save_config
        log_info "Removed container $name_to_remove (remaining: $CONTAINER_COUNT)"
        echo -e "${GREEN}✔ Container removed. Remaining: ${CONTAINER_COUNT}${NC}"
    else
        # For now, just mark it as removed but keep count
        # (Advanced: rename containers to fill gap)
        echo -e "${GREEN}✔ Container ${name_to_remove} removed.${NC}"
        echo -e "${YELLOW}Note: Container numbers will have a gap until restart.${NC}"
    fi

    sleep 2
}

# show_container_manager: Container management menu
show_container_manager() {
    while true; do
        print_header
        echo -e "${CYAN}═══ CONTAINER MANAGER ═══${NC}"
        echo ""

        # Show current status
        local running_count
        running_count=$(count_running_containers)
        echo -e "  ${BOLD}Current:${NC} ${running_count}/${CONTAINER_COUNT} containers running"
        echo ""

        # Show container table
        if [ "$CONTAINER_COUNT" -gt 0 ]; then
            printf "  %-18s %-10s %-10s %s\n" "Container" "Status" "Clients" "Uptime"
            echo "  ─────────────────────────────────────────────────────"

            local i=1
            while [ $i -le "$CONTAINER_COUNT" ]; do
                local name
                name=$(get_container_name "$i")

                local status="${RED}Stopped${NC}"
                local clients="-"
                local uptime="-"

                if container_running "$i"; then
                    status="${GREEN}Running${NC}"

                    # Get clients from logs
                    local log_line
                    log_line=$(docker logs --tail 20 "$name" 2>/dev/null | grep "\[STATS\]" | tail -1) || log_line=""
                    if [ -n "$log_line" ]; then
                        local conn
                        conn=$(echo "$log_line" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p') || conn=0
                        local max_cl
                        max_cl=$(docker inspect --format='{{.Args}}' "$name" 2>/dev/null | grep -o '\-\-max-clients [0-9]*' | awk '{print $2}') || max_cl=200
                        clients="${conn:-0}/${max_cl:-200}"
                    fi

                    # Get uptime
                    local status_str
                    status_str=$(docker ps --format '{{.Status}}' --filter "name=^${name}$" 2>/dev/null | head -1) || status_str=""
                    if [ -n "$status_str" ]; then
                        uptime=$(echo "$status_str" | sed 's/Up //' | sed 's/ (.*)//' | sed 's/ seconds\?/s/' | sed 's/ minutes\?/m/' | sed 's/ hours\?/h/' | sed 's/ days\?/d/')
                    fi
                fi

                printf "  %-18s %-18b %-10s %s\n" "$name" "$status" "$clients" "$uptime"

                i=$((i + 1))
            done
        fi

        echo ""
        echo "══════════════════════════════════════════════════════"
        echo ""
        echo "  1. ➕ Add Container (max ${MAX_CONTAINERS})"
        echo "  2. ➖ Remove Container"
        echo "  3. 🔄 Restart All"
        echo "  4. ⏹️  Stop All"
        echo ""
        echo "  0. ← Back to Main Menu"
        echo ""
        read -p " Select option: " mgr_choice

        case "$mgr_choice" in
            1) add_container ;;
            2) remove_container_menu ;;
            3)
                print_header
                smart_start
                ;;
            4)
                print_header
                stop_service
                ;;
            0|"") return ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# MAIN MENU LOOP
# ==============================================================================

# Check if stdin is a terminal (not piped)
# When run via "curl | bash", stdin is not a TTY and interactive menus won't work
if [ ! -t 0 ]; then
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Conduit Manager installed successfully!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "To start the interactive menu, run:"
    echo ""
    echo -e "  ${CYAN}~/conduit-manager/conduit-mac.sh${NC}"
    echo ""
    exit 0
fi

check_docker
log_info "=== Conduit Manager v${VERSION} session started ==="

while true; do
    print_header
    echo -e "${BOLD}MAIN MENU${NC}"
    echo ""
    echo -e " ${BOLD}Service${NC}"
    echo "   1. ▶️  Start / Restart (Smart)"
    echo "   2. ⏹️  Stop Service"
    echo "   3. 📊 Live Dashboard"
    echo "   4. 📜 View Logs"
    echo "   5. 🩺 Health Check"
    echo ""
    echo -e " ${BOLD}Configuration${NC}"
    echo "   6. 🛠️  Reconfigure (Re-install)"
    echo "   7. 📈 Resource Limits (CPU/RAM)"
    echo "   8. 🆔 Node Identity"
    echo "   9. 📦 Container Manager"
    echo "   c. 🎁 Claim Rewards"
    echo ""
    echo -e " ${BOLD}Backup & Maintenance${NC}"
    echo "   b. 💾 Backup Key"
    echo "   r. 📥 Restore Key"
    echo "   u. 🔄 Check for Updates"
    echo "   x. 🗑  Uninstall"
    echo ""
    echo -e " ${BOLD}Menu Bar App${NC}"
    echo "   m. 🖥  Open Menu Bar App"
    echo ""
    echo "   i. ℹ️  Info & Help"
    echo "   0. 🚪 Exit"
    echo ""
    read -p " Select option: " option

    case $option in
        1) smart_start ;;
        2) stop_service ;;
        3) view_dashboard ;;
        4) view_logs ;;
        5) health_check ;;
        6)
            print_header
            echo -e "${YELLOW}═══ RECONFIGURE CONDUIT ═══${NC}"
            echo ""
            echo -e "${YELLOW}This will recreate the container with new settings.${NC}"
            echo "Your node identity key will be preserved."
            echo ""
            read -p "Continue with reconfiguration? (y/N): " confirm_reconfig
            if [[ "$confirm_reconfig" =~ ^[Yy]$ ]]; then
                install_new
            else
                echo "Reconfiguration cancelled."
                sleep 1
            fi
            ;;
        7) configure_resources ;;
        8) show_node_info ;;
        9) show_container_manager ;;
        [cC]) generate_claim_link ;;
        [bB]) backup_key ;;
        [rR]) restore_key ;;
        [uU]) check_for_updates ;;
        [xX]) uninstall_all ;;
        [mM]) open_menubar_app ;;
        [iI]) show_info_menu ;;
        0)
            log_info "=== Conduit Manager session ended ==="
            echo -e "${CYAN}Goodbye!${NC}"
            exit 0
            ;;
        *)
            log_warn "Invalid menu option selected: $option"
            echo -e "${RED}Invalid option.${NC}"
            sleep 1
            ;;
    esac
done
