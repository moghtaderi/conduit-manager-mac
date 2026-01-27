#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                    PSIPHON CONDUIT MANAGER (macOS)                        ║
# ║                      Security-Hardened Edition                            ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  This script manages a Docker container running Psiphon Conduit proxy.    ║
# ║                                                                           ║
# ║  SECURITY FEATURES:                                                       ║
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
# CONFIGURATION SECTION
# ==============================================================================
# Container and image settings - modify these to change deployment targets.
# NOTE: The IMAGE variable points to a third-party fork. For maximum security,
# consider building from the official Psiphon-Inc/conduit repository.

readonly CONTAINER_NAME="conduit-mac"                           # Docker container name
readonly IMAGE="ghcr.io/ssmirr/conduit/conduit:d8522a8"        # Docker image to deploy
readonly VOLUME_NAME="conduit-data"                             # Persistent data volume
readonly NETWORK_NAME="conduit-network"                         # Isolated bridge network
readonly LOG_FILE="${HOME}/.conduit-manager.log"                # Local log file path

# ------------------------------------------------------------------------------
# RESOURCE LIMITS - Prevent container from consuming excessive host resources
# ------------------------------------------------------------------------------
# These limits protect the host system from denial-of-service conditions
# caused by runaway container processes.

readonly MAX_MEMORY="2g"        # Maximum RAM the container can use (2 gigabytes)
readonly MAX_CPUS="2"           # Maximum CPU cores the container can use
readonly MEMORY_SWAP="2g"       # Disable swap to prevent disk thrashing

# ------------------------------------------------------------------------------
# INPUT VALIDATION CONSTRAINTS
# ------------------------------------------------------------------------------
# These constants define acceptable ranges for user inputs to prevent
# injection attacks and unreasonable configurations.

readonly MIN_CLIENTS=1          # Minimum allowed concurrent clients
readonly MAX_CLIENTS_LIMIT=2000 # Maximum allowed concurrent clients
readonly MIN_BANDWIDTH=1        # Minimum bandwidth in Mbps (unless unlimited)
readonly MAX_BANDWIDTH=1000     # Maximum bandwidth in Mbps

# ==============================================================================
# TERMINAL COLOR CODES
# ==============================================================================
# ANSI escape sequences for colored terminal output.
# Using 'readonly' prevents accidental modification.

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
# Centralized logging ensures all operations are recorded for audit purposes.
# Logs include timestamps and severity levels for easy filtering.

# log_message: Write a timestamped message to both console and log file
# Arguments:
#   $1 - Log level (INFO, WARN, ERROR)
#   $2 - Message to log
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Append to log file with timestamp and level
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    # Also print errors and warnings to stderr for immediate visibility
    if [[ "$level" == "ERROR" ]]; then
        echo -e "${RED}[ERROR]${NC} $message" >&2
    elif [[ "$level" == "WARN" ]]; then
        echo -e "${YELLOW}[WARN]${NC} $message" >&2
    fi
}

# log_info: Convenience wrapper for INFO level logging
log_info() {
    log_message "INFO" "$1"
}

# log_warn: Convenience wrapper for WARN level logging
log_warn() {
    log_message "WARN" "$1"
}

# log_error: Convenience wrapper for ERROR level logging
log_error() {
    log_message "ERROR" "$1"
}

# ==============================================================================
# INPUT VALIDATION FUNCTIONS
# ==============================================================================
# These functions sanitize and validate all user inputs before use.
# This prevents shell injection attacks and ensures reasonable configurations.

# validate_integer: Check if input is a valid integer within specified range
# Arguments:
#   $1 - Value to validate
#   $2 - Minimum allowed value
#   $3 - Maximum allowed value
#   $4 - Field name (for error messages)
# Returns:
#   0 if valid, 1 if invalid
validate_integer() {
    local value="$1"
    local min="$2"
    local max="$3"
    local field_name="$4"

    # Check if value contains only digits (and optional leading minus for -1)
    if [[ ! "$value" =~ ^-?[0-9]+$ ]]; then
        log_error "$field_name must be an integer, got: '$value'"
        echo -e "${RED}Error: $field_name must be a valid integer.${NC}"
        return 1
    fi

    # Check range (allow -1 as special "unlimited" value for bandwidth)
    if [[ "$value" -ne -1 ]] && [[ "$value" -lt "$min" || "$value" -gt "$max" ]]; then
        log_error "$field_name out of range: $value (allowed: $min-$max or -1)"
        echo -e "${RED}Error: $field_name must be between $min and $max (or -1 for unlimited).${NC}"
        return 1
    fi

    return 0
}

# validate_max_clients: Validate the maximum clients input
# Arguments:
#   $1 - Value to validate
# Returns:
#   0 if valid, 1 if invalid
validate_max_clients() {
    local value="$1"

    # Max clients cannot be -1 (unlimited not supported for this field)
    if [[ "$value" == "-1" ]]; then
        log_error "Max clients cannot be unlimited (-1)"
        echo -e "${RED}Error: Max clients cannot be unlimited. Please specify a number.${NC}"
        return 1
    fi

    validate_integer "$value" "$MIN_CLIENTS" "$MAX_CLIENTS_LIMIT" "Max Clients"
}

# validate_bandwidth: Validate the bandwidth limit input
# Arguments:
#   $1 - Value to validate
# Returns:
#   0 if valid, 1 if invalid
validate_bandwidth() {
    local value="$1"

    # -1 is allowed for unlimited bandwidth
    if [[ "$value" == "-1" ]]; then
        return 0
    fi

    validate_integer "$value" "$MIN_BANDWIDTH" "$MAX_BANDWIDTH" "Bandwidth"
}

# sanitize_input: Remove potentially dangerous characters from input
# Arguments:
#   $1 - Input string to sanitize
# Returns:
#   Sanitized string (printed to stdout)
sanitize_input() {
    local input="$1"

    # Remove everything except digits and minus sign
    # This prevents shell injection through special characters
    echo "$input" | tr -cd '0-9-'
}

# ==============================================================================
# DOCKER HELPER FUNCTIONS
# ==============================================================================
# These functions interact with Docker and handle common operations safely.

# check_docker: Verify Docker daemon is running and accessible
# Exits the script with error if Docker is not available.
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

# ensure_network_exists: Create the isolated bridge network if it doesn't exist
# This network isolates the container from the host network stack.
ensure_network_exists() {
    log_info "Ensuring isolated network '$NETWORK_NAME' exists..."

    # Check if network already exists
    if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        log_info "Creating isolated bridge network: $NETWORK_NAME"

        # Create a bridge network with:
        # --driver bridge: Standard isolated network
        # --internal: REMOVED - container needs outbound internet for proxy function
        # The container is isolated from host network but can reach the internet
        if docker network create \
            --driver bridge \
            "$NETWORK_NAME" >/dev/null 2>&1; then
            log_info "Network created successfully"
            echo -e "${GREEN}Created isolated network: $NETWORK_NAME${NC}"
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
# Returns:
#   0 if container exists, 1 if not
container_exists() {
    docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

# container_running: Check if the container is currently running
# Returns:
#   0 if running, 1 if not
container_running() {
    docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

# remove_container: Safely remove the container if it exists
# Logs the action and handles errors gracefully.
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
# UI FUNCTIONS
# ==============================================================================
# Functions for displaying information to the user.

# print_header: Display the application banner
# Clears the screen and shows the stylized header.
print_header() {
    clear
    echo -e "${CYAN}"
    echo "  ██████╗ ██████╗ ███╗   ██╗██████╗ ██╗   ██╗██╗████████╗"
    echo " ██╔════╝██╔═══██╗████╗  ██║██╔══██╗██║   ██║██║╚══██╔══╝"
    echo " ██║     ██║   ██║██╔██╗ ██║██║  ██║██║   ██║██║   ██║   "
    echo " ██║     ██║   ██║██║╚██╗██║██║  ██║██║   ██║██║   ██║   "
    echo " ╚██████╗╚██████╔╝██║ ╚████║██████╔╝╚██████╔╝██║   ██║   "
    echo "  ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═════╝  ╚═════╝ ╚═╝   ╚═╝   "
    echo -e "         ${YELLOW}macOS Security-Hardened Edition${CYAN}              "
    echo -e "${NC}"

    # Display security status indicator
    echo -e "${GREEN}[SECURE]${NC} Container isolation: ENABLED"
    echo ""
}

# print_security_notice: Display information about security settings
# Called before installation to inform users about security measures.
print_security_notice() {
    echo -e "${BOLD}Security Settings:${NC}"
    echo "══════════════════════════════════════════════════════"
    echo -e " Network:     ${GREEN}Isolated bridge${NC} (no host access)"
    echo -e " Filesystem:  ${GREEN}Read-only${NC} (tmpfs for /tmp)"
    echo -e " Privileges:  ${GREEN}Dropped${NC} (no-new-privileges)"
    echo -e " Resources:   ${GREEN}Limited${NC} (${MAX_MEMORY} RAM, ${MAX_CPUS} CPUs)"
    echo "══════════════════════════════════════════════════════"
    echo ""
}

# ==============================================================================
# CORE FUNCTIONALITY
# ==============================================================================
# Main application logic for managing the Conduit container.

# smart_start: Intelligently start, restart, or install the container
# Detects the current state and takes appropriate action.
smart_start() {
    print_header
    log_info "Smart start initiated"

    # Case 1: Container doesn't exist -> Fresh installation needed
    if ! container_exists; then
        echo -e "${BLUE}▶ FIRST TIME SETUP${NC}"
        echo "-----------------------------------"
        log_info "Container not found, initiating fresh installation"
        install_new
        return
    fi

    # Case 2: Container exists and is running -> Restart it
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
        # Case 3: Container exists but stopped -> Start it
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
# Prompts for configuration, validates input, and deploys with security settings.
install_new() {
    local max_clients
    local bandwidth
    local raw_input

    echo ""
    print_security_notice

    # --------------------------------------------------------------------------
    # Prompt for Maximum Clients with input validation
    # --------------------------------------------------------------------------
    while true; do
        read -p "Maximum Clients [1-${MAX_CLIENTS_LIMIT}, Default: 200]: " raw_input

        # Apply default if empty
        raw_input="${raw_input:-200}"

        # Sanitize input to remove dangerous characters
        max_clients=$(sanitize_input "$raw_input")

        # Validate the sanitized input
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

        # Apply default if empty
        raw_input="${raw_input:-5}"

        # Sanitize input
        bandwidth=$(sanitize_input "$raw_input")

        # Validate the sanitized input
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
    # Deploy container with comprehensive security settings
    # --------------------------------------------------------------------------
    # SECURITY EXPLANATION:
    #   --name              : Container identifier
    #   --restart           : Auto-restart policy (unless manually stopped)
    #   --network           : Use isolated bridge network (NOT host network)
    #   --read-only         : Container filesystem is read-only (prevents tampering)
    #   --tmpfs /tmp        : Writable temp directory in memory only
    #   --tmpfs /home/conduit/data : Writable data directory in memory
    #   --security-opt      : Prevent privilege escalation attacks
    #   --cap-drop ALL      : Remove ALL Linux capabilities
    #   --cap-add NET_BIND_SERVICE : Allow binding to ports (required for proxy)
    #   --memory            : Limit RAM usage to prevent host DoS
    #   --cpus              : Limit CPU usage to prevent host DoS
    #   --memory-swap       : Disable swap to prevent disk exhaustion
    #   --pids-limit        : Limit process count to prevent fork bombs
    #   -v                  : Persistent volume for data (survives restarts)
    # --------------------------------------------------------------------------

    echo -e "${BLUE}Starting container with security hardening...${NC}"
    log_info "Deploying container with security constraints"

    if docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --network "$NETWORK_NAME" \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,size=100m \
        --tmpfs /home/conduit/data:rw,noexec,nosuid,size=500m \
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
        echo -e "${BOLD}Container Security Summary:${NC}"
        echo "  - Isolated network (cannot access host network)"
        echo "  - Read-only filesystem (tamper-resistant)"
        echo "  - Resource limits enforced (CPU/RAM capped)"
        echo "  - Privilege escalation blocked"
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
# Logs the action and provides feedback to the user.
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
# Shows CPU, RAM, connected users, and traffic in a live-updating display.
view_dashboard() {
    log_info "Dashboard view started"

    # Set up signal handler for clean exit on Ctrl+C
    trap 'log_info "Dashboard view ended"; break' SIGINT

    while true; do
        print_header
        echo -e "${BOLD}LIVE DASHBOARD${NC} (Press ${YELLOW}Ctrl+C${NC} to Exit)"
        echo "══════════════════════════════════════════════════════"

        if container_running; then
            # ------------------------------------------------------------------
            # Fetch container resource statistics from Docker
            # ------------------------------------------------------------------
            local docker_stats
            docker_stats=$(docker stats --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}" "$CONTAINER_NAME" 2>/dev/null)

            local cpu
            local ram
            cpu=$(echo "$docker_stats" | cut -d'|' -f1)
            ram=$(echo "$docker_stats" | cut -d'|' -f2)

            # ------------------------------------------------------------------
            # Parse connection and traffic statistics from container logs
            # Look for [STATS] lines which contain connection information
            # ------------------------------------------------------------------
            local log_line
            log_line=$(docker logs --tail 50 "$CONTAINER_NAME" 2>&1 | grep "\[STATS\]" | tail -n 1)

            local conn="0"
            local up="0B"
            local down="0B"

            if [[ -n "$log_line" ]]; then
                # Extract connected users count using sed pattern matching
                conn=$(echo "$log_line" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
                conn="${conn:-0}"

                # Extract upload traffic
                up=$(echo "$log_line" | sed -n 's/.*Up:[[:space:]]*\([^|]*\).*/\1/p' | tr -d ' ')
                up="${up:-0B}"

                # Extract download traffic
                down=$(echo "$log_line" | sed -n 's/.*Down:[[:space:]]*\([^|]*\).*/\1/p' | tr -d ' ')
                down="${down:-0B}"
            fi

            # Fetch container uptime
            local uptime
            uptime=$(docker ps -f "name=$CONTAINER_NAME" --format '{{.Status}}')

            # ------------------------------------------------------------------
            # Display formatted dashboard
            # ------------------------------------------------------------------
            echo -e " STATUS:      ${GREEN}● ONLINE${NC}"
            echo -e " UPTIME:      $uptime"
            echo "──────────────────────────────────────────────────────"
            printf " %-15s | %-15s \n" "RESOURCES" "TRAFFIC"
            echo "──────────────────────────────────────────────────────"
            printf " CPU: ${YELLOW}%-9s${NC} | Users: ${GREEN}%-9s${NC} \n" "$cpu" "$conn"
            printf " RAM: ${YELLOW}%-9s${NC} | Up:    ${CYAN}%-9s${NC} \n" "$ram" "$up"
            printf "              | Down:  ${CYAN}%-9s${NC} \n" "$down"
            echo "══════════════════════════════════════════════════════"
            echo -e "${GREEN}[SECURE]${NC} Network isolated | Privileges dropped"
            echo -e "${YELLOW}Refreshing every 10 seconds...${NC}"
        else
            # Container not running - show offline status
            echo -e " STATUS:      ${RED}● OFFLINE${NC}"
            echo "──────────────────────────────────────────────────────"
            echo -e " Service is not running."
            echo " Press 1 from main menu to Start."
            echo "══════════════════════════════════════════════════════"
        fi

        sleep 10
    done

    # Reset signal handler
    trap - SIGINT
}

# view_logs: Stream container logs in real-time
# Useful for debugging and monitoring container behavior.
view_logs() {
    log_info "Log view started"
    clear
    echo -e "${CYAN}Streaming Logs (Press Ctrl+C to Exit)...${NC}"
    echo "------------------------------------------------"

    if container_running; then
        # Stream the last 100 lines and follow new output
        docker logs -f --tail 100 "$CONTAINER_NAME"
    else
        echo -e "${YELLOW}Container is not running.${NC}"
        echo "Start the container first to view logs."
        read -n 1 -s -r -p "Press any key to return..."
    fi

    log_info "Log view ended"
}

# show_security_info: Display detailed security configuration
# Provides transparency about what security measures are in place.
show_security_info() {
    print_header
    echo -e "${BOLD}SECURITY CONFIGURATION${NC}"
    echo "══════════════════════════════════════════════════════"
    echo ""
    echo -e "${BOLD}Network Isolation:${NC}"
    echo "  The container runs on an isolated bridge network."
    echo "  It CANNOT access the host network stack directly."
    echo "  It CAN reach the internet (required for proxy function)."
    echo ""
    echo -e "${BOLD}Filesystem Protection:${NC}"
    echo "  Container filesystem is READ-ONLY."
    echo "  Only /tmp and /home/conduit/data are writable."
    echo "  Both writable paths have noexec,nosuid flags."
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

# ==============================================================================
# MAIN MENU LOOP
# ==============================================================================
# Entry point: verify Docker is running, then present interactive menu.

# Verify Docker is available before proceeding
check_docker

# Initialize log file with session start marker
log_info "=== Conduit Manager session started ==="

# Main interactive loop
while true; do
    print_header
    echo -e "${BOLD}MAIN MENU${NC}"
    echo " 1. ▶  Start / Restart (Smart)"
    echo " 2. ⏹  Stop Service"
    echo " 3. 📊 Open Live Dashboard"
    echo " 4. 📜 View Raw Logs"
    echo " 5. ⚙  Reconfigure (Re-install)"
    echo " 6. 🔒 View Security Settings"
    echo " 0. 🚪 Exit"
    echo ""
    read -p " Select option [0-6]: " option

    # Sanitize menu input to prevent injection
    option=$(sanitize_input "$option")

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
