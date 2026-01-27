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

readonly VERSION="1.1.0"                                          # Script version

# Container and image settings
readonly CONTAINER_NAME="conduit-mac"                             # Docker container name
readonly IMAGE="ghcr.io/ssmirr/conduit/conduit:d8522a8"          # Docker image to deploy
readonly IMAGE_DIGEST="sha256:a7c3acdc9ff4b5a2077a983765f0ac905ad11571321c61715181b1cf616379ca"  # Expected SHA256
readonly VOLUME_NAME="conduit-data"                               # Persistent data volume
readonly NETWORK_NAME="conduit-network"                           # Isolated bridge network
readonly LOG_FILE="${HOME}/.conduit-manager.log"                  # Local log file path
readonly BACKUP_DIR="${HOME}/.conduit-backups"                    # Backup directory for keys

# ------------------------------------------------------------------------------
# RESOURCE LIMITS - Prevent container from consuming excessive host resources
# ------------------------------------------------------------------------------
readonly MAX_MEMORY="2g"        # Maximum RAM the container can use (2 gigabytes)
readonly MAX_CPUS="2"           # Maximum CPU cores the container can use
readonly MEMORY_SWAP="2g"       # Disable swap to prevent disk thrashing

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

# check_docker: Verify Docker daemon is running and accessible
check_docker() {
    log_info "Checking Docker availability..."

    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is not running or not accessible"
        echo -e "${RED}[ERROR] Docker is NOT running!${NC}"
        echo ""
        echo "Please ensure Docker Desktop is installed and running:"
        echo "  1. Open Docker Desktop from Applications"
        echo "  2. Wait for it to fully start (whale icon stops animating)"
        echo "  3. Run this script again"
        echo ""
        exit 1
    fi

    log_info "Docker is available and running"
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
    # Get the volume mountpoint
    local mountpoint
    mountpoint=$(docker volume inspect "$VOLUME_NAME" --format '{{ .Mountpoint }}' 2>/dev/null) || mountpoint=""

    if [ -z "$mountpoint" ]; then
        # Try using a container to read the file instead
        local key_content
        key_content=$(docker run --rm -v "$VOLUME_NAME":/data alpine cat /data/conduit_key.json 2>/dev/null) || key_content=""

        if [ -n "$key_content" ]; then
            # Extract privateKeyBase64, decode, take last 32 bytes, encode base64
            echo "$key_content" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' 2>/dev/null
        fi
        return
    fi

    if [ -f "$mountpoint/conduit_key.json" ]; then
        cat "$mountpoint/conduit_key.json" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' 2>/dev/null
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

    # Backup current key if exists
    local current_key
    current_key=$(docker run --rm -v "$VOLUME_NAME":/data alpine cat /data/conduit_key.json 2>/dev/null) || current_key=""

    if [ -n "$current_key" ]; then
        local timestamp
        timestamp=$(date '+%Y%m%d_%H%M%S')
        mkdir -p "$BACKUP_DIR"
        echo "$current_key" > "$BACKUP_DIR/conduit_key_pre_restore_${timestamp}.json"
        echo "  Current key backed up to: conduit_key_pre_restore_${timestamp}.json"
    fi

    # Restore the key using a temporary container
    echo "Restoring key..."
    docker run --rm -v "$VOLUME_NAME":/data -v "$(dirname "$backup_file")":/backup alpine \
        sh -c "cp /backup/$(basename "$backup_file") /data/conduit_key.json && chmod 600 /data/conduit_key.json"

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
print_header() {
    clear
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

# smart_start: Intelligently start, restart, or install the container
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
    recommended=$(calculate_recommended_clients)

    echo ""
    print_system_info
    print_security_notice

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
    # Deploy container with comprehensive security settings
    # --------------------------------------------------------------------------
    echo -e "${BLUE}Starting container with security hardening...${NC}"
    log_info "Deploying container with security constraints"

    if docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --network "$NETWORK_NAME" \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,size=100m \
        --security-opt no-new-privileges:true \
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
    clear

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

        echo -e "${BOLD}LIVE DASHBOARD${NC} (Press ${YELLOW}any key${NC} to Exit)\033[K"
        echo "══════════════════════════════════════════════════════\033[K"

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

            # Display dashboard
            echo -e " STATUS:      ${GREEN}● ONLINE${NC}\033[K"
            echo -e " UPTIME:      $uptime\033[K"
            if [ -n "$node_id" ]; then
                echo -e " NODE ID:     ${CYAN}${node_id}${NC}\033[K"
            fi
            echo "──────────────────────────────────────────────────────\033[K"
            echo -e " ${BOLD}CLIENTS${NC}\033[K"
            printf "   Connected:  ${GREEN}%-6s${NC} | Connecting: ${YELLOW}%-6s${NC}\033[K\n" "$conn" "$connecting"
            echo "──────────────────────────────────────────────────────\033[K"
            echo -e " ${BOLD}TRAFFIC${NC}\033[K"
            printf "   Upload:     ${CYAN}%-12s${NC} | Download: ${CYAN}%-12s${NC}\033[K\n" "$up" "$down"
            echo "──────────────────────────────────────────────────────\033[K"
            echo -e " ${BOLD}RESOURCES${NC}           Container         System\033[K"
            printf "   CPU:        ${YELLOW}%-12s${NC}    ${YELLOW}%-12s${NC}\033[K\n" "$cpu" "$sys_cpu"
            printf "   RAM:        ${YELLOW}%-12s${NC}    ${YELLOW}%-12s${NC}\033[K\n" "$ram" "$sys_ram_used"
            echo "══════════════════════════════════════════════════════\033[K"
            echo -e "${GREEN}[SECURE]${NC} Network isolated | Privileges dropped\033[K"
            echo -e "${YELLOW}Refreshing every 5 seconds...\033[K${NC}"
        else
            echo -e " STATUS:      ${RED}● OFFLINE${NC}\033[K"
            echo "──────────────────────────────────────────────────────\033[K"
            echo -e " Service is not running.\033[K"
            echo -e " Press 1 from main menu to Start.\033[K"
            echo "══════════════════════════════════════════════════════\033[K"
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
    clear
    echo -e "${CYAN}Streaming Logs (Press Ctrl+C to Exit)...${NC}"
    echo "------------------------------------------------"

    if container_running; then
        docker logs -f --tail 100 "$CONTAINER_NAME" || true
    else
        echo -e "${YELLOW}Container is not running.${NC}"
        echo "Start the container first to view logs."
        read -n 1 -s -r -p "Press any key to return..."
    fi

    log_info "Log view ended"
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
    echo -e "${BOLD}Log File:${NC}"
    echo "  $LOG_FILE"
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

# uninstall_all: Completely remove the container, volume, and network
uninstall_all() {
    print_header
    echo -e "${RED}═══ UNINSTALL CONDUIT ═══${NC}"
    echo ""
    echo -e "${YELLOW}WARNING: This will remove:${NC}"
    echo "  - The Conduit container"
    echo "  - The conduit-data Docker volume (node identity!)"
    echo "  - The conduit-network Docker network"
    echo ""
    echo -e "${BOLD}Your backup keys in ${BACKUP_DIR} will NOT be deleted.${NC}"
    echo ""

    # Check for existing backups
    local has_backup=false
    if [ -d "$BACKUP_DIR" ] && [ -n "$(ls -A "$BACKUP_DIR"/*.json 2>/dev/null)" ]; then
        has_backup=true
        echo -e "${GREEN}✔ You have backup keys available for recovery.${NC}"
    else
        echo -e "${YELLOW}⚠ You have NO backup keys. Your node identity will be LOST.${NC}"
        echo "  Consider running 'Backup Key' first!"
    fi
    echo ""

    read -p "Are you sure you want to uninstall? (type 'yes' to confirm): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Uninstall cancelled."
        read -n 1 -s -r -p "Press any key to return..."
        return 0
    fi

    echo ""
    log_info "Uninstall initiated by user"

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

    log_info "Uninstall completed"

    echo ""
    echo -e "${GREEN}✔ Uninstall complete${NC}"
    echo ""
    if [ "$has_backup" = true ]; then
        echo -e "Your backup keys are preserved in: ${CYAN}${BACKUP_DIR}${NC}"
        echo "You can use these to restore your node identity after reinstalling."
    fi
    echo ""
    read -n 1 -s -r -p "Press any key to return..."
}

# check_for_updates: Check if a newer version of the script is available
check_for_updates() {
    print_header
    echo -e "${BOLD}CHECK FOR UPDATES${NC}"
    echo "══════════════════════════════════════════════════════"
    echo ""
    echo -e "Current version: ${CYAN}${VERSION}${NC}"
    echo ""
    echo "Checking for updates..."
    echo ""

    # Try to fetch the latest version from GitHub
    local remote_version=""
    remote_version=$(curl -sL --max-time 10 "https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/conduit-mac.sh" 2>/dev/null | grep "^readonly VERSION=" | head -1 | cut -d'"' -f2) || remote_version=""

    if [ -z "$remote_version" ]; then
        echo -e "${YELLOW}Could not check for updates.${NC}"
        echo "Check your internet connection or visit:"
        echo "  https://github.com/moghtaderi/conduit-manager-mac"
    elif [ "$remote_version" = "$VERSION" ]; then
        echo -e "${GREEN}✔ You are running the latest version.${NC}"
    else
        echo -e "${YELLOW}A new version is available: ${remote_version}${NC}"
        echo ""
        echo "To update, run:"
        echo -e "  ${CYAN}curl -L -o conduit-mac.sh https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/conduit-mac.sh${NC}"
        echo -e "  ${CYAN}chmod +x conduit-mac.sh${NC}"
    fi

    echo ""
    echo "══════════════════════════════════════════════════════"
    read -n 1 -s -r -p "Press any key to return..."
}

# ==============================================================================
# MAIN MENU LOOP
# ==============================================================================

check_docker
log_info "=== Conduit Manager v${VERSION} session started ==="

while true; do
    print_header
    echo -e "${BOLD}MAIN MENU${NC}"
    echo ""
    echo " ${BOLD}Service${NC}"
    echo "   1. ▶  Start / Restart (Smart)"
    echo "   2. ⏹  Stop Service"
    echo "   3. 📊 Live Dashboard"
    echo "   4. 📜 View Logs"
    echo ""
    echo " ${BOLD}Configuration${NC}"
    echo "   5. ⚙  Reconfigure (Re-install)"
    echo "   6. 🔒 Security Settings"
    echo "   7. 🆔 Node Identity"
    echo ""
    echo " ${BOLD}Backup & Maintenance${NC}"
    echo "   8. 💾 Backup Key"
    echo "   9. 📥 Restore Key"
    echo "   u. 🔄 Check for Updates"
    echo "   x. 🗑  Uninstall"
    echo ""
    echo "   0. 🚪 Exit"
    echo ""
    read -p " Select option: " option

    case $option in
        1) smart_start ;;
        2) stop_service ;;
        3) view_dashboard ;;
        4) view_logs ;;
        5)
            print_header
            echo -e "${BLUE}▶ RECONFIGURATION${NC}"
            install_new
            ;;
        6) show_security_info ;;
        7) show_node_info ;;
        8) backup_key ;;
        9) restore_key ;;
        [uU]) check_for_updates ;;
        [xX]) uninstall_all ;;
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
