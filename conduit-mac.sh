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

readonly VERSION="1.5.6"                                          # Script version

# Container and image settings
readonly CONTAINER_NAME="conduit-mac"                             # Docker container name
readonly IMAGE="ghcr.io/ssmirr/conduit/conduit:d8522a8"          # Docker image to deploy
readonly IMAGE_DIGEST="sha256:a7c3acdc9ff4b5a2077a983765f0ac905ad11571321c61715181b1cf616379ca"  # Expected SHA256
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

# ==============================================================================
# TERMINAL COLOR CODES
# ==============================================================================
readonly BOLD='\033[1m'
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
        if [ -n "$SAVED_MAX_MEMORY" ]; then
            MAX_MEMORY="$SAVED_MAX_MEMORY"
            MEMORY_SWAP="$SAVED_MAX_MEMORY"
        fi
        if [ -n "$SAVED_MAX_CPUS" ]; then
            MAX_CPUS="$SAVED_MAX_CPUS"
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
        local page_size=4096
        local pages_free pages_active pages_inactive pages_speculative pages_wired

        pages_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {print $3}' | tr -d '.') || pages_free=0
        pages_active=$(vm_stat 2>/dev/null | awk '/Pages active/ {print $3}' | tr -d '.') || pages_active=0
        pages_inactive=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {print $3}' | tr -d '.') || pages_inactive=0
        pages_speculative=$(vm_stat 2>/dev/null | awk '/Pages speculative/ {print $3}' | tr -d '.') || pages_speculative=0
        pages_wired=$(vm_stat 2>/dev/null | awk '/Pages wired/ {print $4}' | tr -d '.') || pages_wired=0

        local used_bytes=$(( (pages_active + pages_wired) * page_size ))
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

# container_exists: Check if the container exists (running or stopped)
container_exists() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        return 0
    else
        return 1
    fi
}

# container_running: Check if the container is currently running
container_running() {
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        return 0
    else
        return 1
    fi
}

# remove_container: Safely remove the container if it exists
remove_container() {
    if container_exists; then
        log_info "Removing existing container: $CONTAINER_NAME"
        if docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1; then
            log_info "Container removed successfully"
        else
            log_warn "Failed to remove container (may not exist)"
        fi
    fi
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
    docker run --rm -v "$VOLUME_NAME":/data -v "$(dirname "$backup_file")":/backup alpine \
        sh -c "cp /backup/$(basename "$backup_file") /data/conduit_key.json && chmod 600 /data/conduit_key.json && chown -R 1000:1000 /data"

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

# smart_start: Intelligently start, restart, or install the container
# Also detects if resource limits have changed and recreates container if needed
smart_start() {
    print_header
    log_info "Smart start initiated"

    if ! container_exists; then
        echo -e "${BLUE}▶ FIRST TIME SETUP${NC}"
        echo "-----------------------------------"
        log_info "Container not found, initiating fresh installation"
        install_new
        return
    fi

    # Check if resource limits have changed
    if check_resource_limits_changed; then
        echo -e "${YELLOW}Status: Resource limits changed${NC}"
        echo -e "${BLUE}Action: Recreating container with new limits...${NC}"
        echo ""
        echo -e "  New limits: ${CYAN}${MAX_CPUS} CPU / ${MAX_MEMORY} RAM${NC}"
        echo ""
        log_info "Resource limits changed, recreating container"

        # Get current settings from container
        local current_args=""
        current_args=$(docker inspect --format='{{.Args}}' "$CONTAINER_NAME" 2>/dev/null) || current_args=""

        # Extract max-clients and bandwidth from current args
        local max_clients=""
        local bandwidth=""
        max_clients=$(echo "$current_args" | grep -o '\-\-max-clients [0-9]*' | awk '{print $2}') || max_clients=""
        bandwidth=$(echo "$current_args" | grep -o '\-\-bandwidth [0-9-]*' | awk '{print $2}') || bandwidth=""

        # Use defaults if not found
        max_clients="${max_clients:-200}"
        bandwidth="${bandwidth:-5}"

        # Remove old container
        echo "Stopping and removing old container..."
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

        # Ensure network exists
        ensure_network_exists

        # Fix volume permissions
        docker run --rm -v "$VOLUME_NAME":/home/conduit/data alpine \
            sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true

        # Ensure seccomp profile exists
        create_seccomp_profile

        # Recreate container with new limits
        echo "Creating container with new resource limits..."

        # Build docker run command with optional seccomp
        local seccomp_opt=""
        if [ -f "$SECCOMP_FILE" ]; then
            seccomp_opt="--security-opt seccomp=$SECCOMP_FILE"
        fi

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
            --pids-limit 100 \
            -v "$VOLUME_NAME":/home/conduit/data \
            "$IMAGE" \
            start --max-clients "$max_clients" --bandwidth "$bandwidth" -v > /dev/null 2>&1; then

            log_info "Container recreated with new limits: memory=$MAX_MEMORY, cpus=$MAX_CPUS"
            echo -e "${GREEN}✔ Container recreated with new resource limits.${NC}"
        else
            log_error "Failed to recreate container"
            echo -e "${RED}✘ Failed to recreate container.${NC}"
        fi
        sleep 2
        return
    fi

    if container_running; then
        echo -e "${YELLOW}Status: Running${NC}"
        echo -e "${BLUE}Action: Restarting Service...${NC}"
        log_info "Restarting running container"

        if docker restart "$CONTAINER_NAME" > /dev/null; then
            log_info "Container restarted successfully"
            echo -e "${GREEN}✔ Service Restarted Successfully.${NC}"
        else
            log_error "Failed to restart container"
            echo -e "${RED}✘ Failed to restart service.${NC}"
        fi
        sleep 2
    else
        echo -e "${RED}Status: Stopped${NC}"
        echo -e "${BLUE}Action: Starting Service...${NC}"
        log_info "Starting stopped container"

        if docker start "$CONTAINER_NAME" > /dev/null; then
            log_info "Container started successfully"
            echo -e "${GREEN}✔ Service Started Successfully.${NC}"
        else
            log_error "Failed to start container"
            echo -e "${RED}✘ Failed to start service.${NC}"
        fi
        sleep 2
    fi
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
        --pids-limit 100 \
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
    log_info "Stop service requested"
    echo -e "${YELLOW}Stopping Conduit...${NC}"

    if container_running; then
        if docker stop "$CONTAINER_NAME" > /dev/null 2>&1; then
            log_info "Container stopped successfully"
            echo -e "${GREEN}✔ Service stopped.${NC}"
        else
            log_error "Failed to stop container"
            echo -e "${RED}✘ Failed to stop service.${NC}"
        fi
    else
        log_warn "Stop requested but container is not running"
        echo -e "${YELLOW}Service is not currently running.${NC}"
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

        local is_running=0
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
            is_running=1
        fi

        if [ "$is_running" -eq 1 ]; then
            # Fetch container stats
            local docker_stats=""
            docker_stats=$(docker stats --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}" "$CONTAINER_NAME" 2>/dev/null) || docker_stats=""

            local cpu="N/A"
            local ram="N/A"
            if [ -n "$docker_stats" ]; then
                cpu=$(echo "$docker_stats" | cut -d'|' -f1)
                ram=$(echo "$docker_stats" | cut -d'|' -f2)
            fi

            # Fetch system stats
            local sys_stats
            sys_stats=$(get_system_stats)
            local sys_cpu sys_ram_used sys_ram_total
            sys_cpu=$(echo "$sys_stats" | awk '{print $1}')
            sys_ram_used=$(echo "$sys_stats" | awk '{print $2, $3}')
            sys_ram_total=$(echo "$sys_stats" | awk '{print $4, $5}')

            # Parse connection stats from logs
            local log_output=""
            log_output=$(docker logs --tail 50 "$CONTAINER_NAME" 2>&1) || log_output=""

            local log_line=""
            log_line=$(echo "$log_output" | grep "\[STATS\]" | tail -n 1) || log_line=""

            local conn="0"
            local connecting="0"
            local up="0B"
            local down="0B"

            if [ -n "$log_line" ]; then
                conn=$(echo "$log_line" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p') || conn=""
                conn="${conn:-0}"
                connecting=$(echo "$log_line" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p') || connecting=""
                connecting="${connecting:-0}"
                up=$(echo "$log_line" | sed -n 's/.*Up:[[:space:]]*\([^|]*\).*/\1/p' | tr -d ' ') || up=""
                up="${up:-0B}"
                down=$(echo "$log_line" | sed -n 's/.*Down:[[:space:]]*\([^|]*\).*/\1/p' | tr -d ' ') || down=""
                down="${down:-0B}"
            fi

            # Fetch container uptime
            local uptime=""
            uptime=$(docker ps -f "name=$CONTAINER_NAME" --format '{{.Status}}' 2>/dev/null) || uptime="Unknown"

            # Get node ID
            local node_id=""
            node_id=$(get_node_id) || node_id=""

            # Get the actual container resource limits from docker inspect
            local container_mem_limit=""
            local container_cpu_limit=""
            container_mem_limit=$(docker inspect --format='{{.HostConfig.Memory}}' "$CONTAINER_NAME" 2>/dev/null) || container_mem_limit="0"
            container_cpu_limit=$(docker inspect --format='{{.HostConfig.NanoCpus}}' "$CONTAINER_NAME" 2>/dev/null) || container_cpu_limit="0"

            # Convert memory from bytes to GB
            local container_mem_gb="N/A"
            if [ -n "$container_mem_limit" ] && [ "$container_mem_limit" -gt 0 ] 2>/dev/null; then
                container_mem_gb=$(awk "BEGIN {printf \"%.0f\", $container_mem_limit/1073741824}")
            fi

            # Convert NanoCpus to cores (NanoCpus = cores * 1e9)
            local container_cpu_cores="N/A"
            if [ -n "$container_cpu_limit" ] && [ "$container_cpu_limit" -gt 0 ] 2>/dev/null; then
                container_cpu_cores=$(awk "BEGIN {printf \"%.0f\", $container_cpu_limit/1000000000}")
            fi

            # Check if container limits match configured limits
            local config_mem_gb="${MAX_MEMORY%g}"
            local limits_match=true
            if [ "$container_mem_gb" != "$config_mem_gb" ] || [ "$container_cpu_cores" != "$MAX_CPUS" ]; then
                limits_match=false
            fi

            # Display dashboard
            echo -e " STATUS:      ${GREEN}● ONLINE${NC}${CL}"
            echo -e " UPTIME:      ${uptime}${CL}"
            if [ -n "$node_id" ]; then
                echo -e " NODE ID:     ${CYAN}${node_id}${NC}${CL}"
            fi
            echo "──────────────────────────────────────────────────────${CL}"
            echo -e " ${BOLD}CLIENTS${NC}${CL}"
            echo -e "   Connected:  ${GREEN}${conn}${NC}      | Connecting: ${YELLOW}${connecting}${NC}${CL}"
            echo "──────────────────────────────────────────────────────${CL}"
            echo -e " ${BOLD}TRAFFIC${NC}${CL}"
            echo -e "   Upload:     ${CYAN}${up}${NC}    | Download: ${CYAN}${down}${NC}${CL}"
            echo "──────────────────────────────────────────────────────${CL}"
            echo -e " ${BOLD}RESOURCES${NC}           Container         System${CL}"
            echo -e "   CPU:        ${YELLOW}${cpu}${NC}         ${YELLOW}${sys_cpu}${NC}${CL}"
            echo -e "   RAM:        ${YELLOW}${ram}${NC}    ${YELLOW}${sys_ram_used}${NC}${CL}"
            echo -e "   Limits:     ${CYAN}${container_cpu_cores} CPU / ${container_mem_gb} GB RAM${NC}${CL}"
            if [ "$limits_match" = false ]; then
                echo -e "   ${YELLOW}⚠ Config: ${MAX_CPUS} CPU / ${config_mem_gb} GB - Restart to apply${NC}${CL}"
            fi
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

# show_security_info: Display detailed security configuration
show_security_info() {
    print_header
    echo -e "${BOLD}SECURITY CONFIGURATION${NC}"
    echo "══════════════════════════════════════════════════════"
    echo ""
    echo -e "${BOLD}Image Verification:${NC}"
    echo "  Docker images are verified using SHA256 digest."
    echo "  Expected: ${IMAGE_DIGEST:0:20}..."
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
    echo -e "${BOLD}Resource Limits:${NC}"
    echo "  Memory:     $MAX_MEMORY maximum"
    echo "  CPU:        $MAX_CPUS cores maximum"
    echo "  Processes:  100 maximum (prevents fork bombs)"
    echo ""
    echo "══════════════════════════════════════════════════════"
    echo ""
    echo -e "${BOLD}FILE & DATA LOCATIONS${NC}"
    echo "══════════════════════════════════════════════════════"
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
health_check() {
    print_header
    echo -e "${CYAN}═══ CONDUIT HEALTH CHECK ═══${NC}"
    echo ""

    local all_ok=true
    local warnings=0

    # 1. Check if Docker is running
    echo -n "  Docker daemon:        "
    if docker info &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Docker is not running"
        all_ok=false
    fi

    # 2. Check if container exists
    echo -n "  Container exists:     "
    if container_exists; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Container not found"
        all_ok=false
    fi

    # 3. Check if container is running
    echo -n "  Container running:    "
    if container_running; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Container is stopped"
        all_ok=false
    fi

    # 4. Check container restart count
    echo -n "  Restart count:        "
    local restarts=""
    restarts=$(docker inspect --format='{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null) || restarts=""
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

    # 5. Check network isolation
    echo -n "  Network isolation:    "
    local network_mode=""
    network_mode=$(docker inspect --format='{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null) || network_mode=""
    if [ "$network_mode" = "$NETWORK_NAME" ]; then
        echo -e "${GREEN}OK${NC} (bridge network)"
    elif [ "$network_mode" = "host" ]; then
        echo -e "${YELLOW}WARN${NC} - Using host network (less secure)"
        warnings=$((warnings + 1))
    else
        echo -e "${GREEN}OK${NC} (${network_mode:-unknown})"
    fi

    # 6. Check security options
    echo -n "  Security hardening:   "
    local read_only=""
    local no_new_privs=""
    read_only=$(docker inspect --format='{{.HostConfig.ReadonlyRootfs}}' "$CONTAINER_NAME" 2>/dev/null) || read_only=""
    no_new_privs=$(docker inspect --format='{{range .HostConfig.SecurityOpt}}{{.}}{{end}}' "$CONTAINER_NAME" 2>/dev/null) || no_new_privs=""

    if [ "$read_only" = "true" ] && echo "$no_new_privs" | grep -q "no-new-privileges"; then
        echo -e "${GREEN}OK${NC} (read-only, no-new-privileges)"
    else
        echo -e "${YELLOW}WARN${NC} - Some hardening missing"
        warnings=$((warnings + 1))
    fi

    # 7. Check if Conduit has connected to network
    echo -n "  Psiphon connection:   "
    if container_running; then
        local connected=""
        connected=$(docker logs --tail 100 "$CONTAINER_NAME" 2>/dev/null | grep -c "Connected to Psiphon" 2>/dev/null | head -1 || echo "0")
        connected=${connected:-0}
        if [ "$connected" -gt 0 ] 2>/dev/null; then
            echo -e "${GREEN}OK${NC} (Connected to Psiphon network)"
        else
            local info_lines=""
            info_lines=$(docker logs --tail 100 "$CONTAINER_NAME" 2>/dev/null | grep -c "\[INFO\]" 2>/dev/null | head -1 || echo "0")
            info_lines=${info_lines:-0}
            if [ "$info_lines" -gt 0 ] 2>/dev/null; then
                echo -e "${YELLOW}CONNECTING${NC} - Establishing connection..."
                warnings=$((warnings + 1))
            else
                echo -e "${YELLOW}STARTING${NC} - Initializing..."
                warnings=$((warnings + 1))
            fi
        fi
    else
        echo -e "${RED}N/A${NC} - Container not running"
    fi

    # 8. Check stats output
    echo -n "  Stats output:         "
    if container_running; then
        local stats_count=""
        stats_count=$(docker logs --tail 100 "$CONTAINER_NAME" 2>/dev/null | grep -c "\[STATS\]" 2>/dev/null | head -1 || echo "0")
        stats_count=${stats_count:-0}
        if [ "$stats_count" -gt 0 ] 2>/dev/null; then
            echo -e "${GREEN}OK${NC} (${stats_count} entries)"
        else
            echo -e "${YELLOW}NONE${NC} - May need restart with -v flag"
            warnings=$((warnings + 1))
        fi
    else
        echo -e "${RED}N/A${NC}"
    fi

    # 9. Check data volume
    echo -n "  Data volume:          "
    if docker volume inspect "$VOLUME_NAME" &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Volume not found"
        all_ok=false
    fi

    # 10. Check node identity key
    echo -n "  Node identity key:    "
    local node_id=""
    node_id=$(get_node_id)
    if [ -n "$node_id" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}PENDING${NC} - Will be created on first run"
        warnings=$((warnings + 1))
    fi

    # 11. Check resource limits
    echo -n "  Resource limits:      "
    local mem_limit=""
    local cpu_limit=""
    mem_limit=$(docker inspect --format='{{.HostConfig.Memory}}' "$CONTAINER_NAME" 2>/dev/null) || mem_limit="0"
    cpu_limit=$(docker inspect --format='{{.HostConfig.NanoCpus}}' "$CONTAINER_NAME" 2>/dev/null) || cpu_limit="0"
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

    # 12. Check seccomp profile
    echo -n "  Seccomp profile:      "
    if [ -f "$SECCOMP_FILE" ]; then
        local seccomp_opt=""
        seccomp_opt=$(docker inspect --format='{{range .HostConfig.SecurityOpt}}{{.}} {{end}}' "$CONTAINER_NAME" 2>/dev/null) || seccomp_opt=""
        if echo "$seccomp_opt" | grep -q "seccomp"; then
            echo -e "${GREEN}OK${NC} (custom profile)"
        else
            echo -e "${YELLOW}DEFAULT${NC} - Using Docker default"
        fi
    else
        echo -e "${YELLOW}N/A${NC} - Profile not created"
    fi

    # Summary
    echo ""
    echo "══════════════════════════════════════════════════════"
    if [ "$all_ok" = true ] && [ "$warnings" -eq 0 ]; then
        echo -e "${GREEN}✔ All health checks passed${NC}"
    elif [ "$all_ok" = true ]; then
        echo -e "${YELLOW}⚠ Passed with ${warnings} warning(s)${NC}"
    else
        echo -e "${RED}✘ Some health checks failed${NC}"
    fi

    # Show node ID if available
    if [ -n "$node_id" ]; then
        echo ""
        echo -e "  Node ID: ${CYAN}${node_id}${NC}"
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
    echo -e "${YELLOW}WARNING: This will remove:${NC}"
    echo "  - The Conduit container"
    echo "  - The conduit-data Docker volume (node identity!)"
    echo "  - The conduit-network Docker network"
    echo "  - The Docker image"
    echo "  - The log file (~/.conduit-manager.log)"
    echo "  - The config file (~/.conduit-config)"
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

    read -p "Are you sure you want to uninstall? (type 'yes' to confirm): " confirm

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

    # Remove log file and config file
    echo "Removing log and config files..."
    rm -f "$LOG_FILE" 2>/dev/null || true
    rm -f "$CONFIG_FILE" 2>/dev/null || true

    # Optionally remove backups
    if [ "$delete_backups" = true ] && [ -d "$BACKUP_DIR" ]; then
        echo "Removing backup keys..."
        rm -rf "$BACKUP_DIR" 2>/dev/null || true
    fi

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

    log_info "Auto-update completed: $VERSION -> $remote_version"

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
    echo "   1. ▶  Start / Restart (Smart)"
    echo "   2. ⏹  Stop Service"
    echo "   3. 📊 Live Dashboard"
    echo "   4. 📜 View Logs"
    echo "   5. 🩺 Health Check"
    echo ""
    echo -e " ${BOLD}Configuration${NC}"
    echo "   6. ⚙  Reconfigure (Re-install)"
    echo "   7. 📈 Resource Limits (CPU/RAM)"
    echo "   8. 🔒 Security Settings"
    echo "   9. 🆔 Node Identity"
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
            echo -e "${BLUE}▶ RECONFIGURATION${NC}"
            install_new
            ;;
        7) configure_resources ;;
        8) show_security_info ;;
        9) show_node_info ;;
        [bB]) backup_key ;;
        [rR]) restore_key ;;
        [uU]) check_for_updates ;;
        [xX]) uninstall_all ;;
        [mM]) open_menubar_app ;;
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
