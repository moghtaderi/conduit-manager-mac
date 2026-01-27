#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║              PSIPHON CONDUIT MANAGER - ONE-LINE INSTALLER                 ║
# ║                           For macOS                                       ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  Usage:                                                                   ║
# ║    curl -sL https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/install.sh | bash
# ║                                                                           ║
# ║  Or with wget:                                                            ║
# ║    wget -qO- https://raw.githubusercontent.com/moghtaderi/conduit-manager-mac/main/install.sh | bash
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
GITHUB_REPO="moghtaderi/conduit-manager-mac"
SCRIPT_NAME="conduit-mac.sh"
INSTALL_DIR="${HOME}/conduit-manager"

# Detect if user has sudo privileges
has_sudo_privileges() {
    # Check if user can run sudo without password (for non-interactive scripts)
    # or if they're already root
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    # Try a harmless sudo command with no password prompt
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    # Check if user is in admin/wheel group (potential sudo access)
    if groups | grep -qE '\b(admin|wheel|sudo)\b'; then
        return 0
    fi
    return 1
}

# Determine install type and set paths accordingly
setup_install_paths() {
    if has_sudo_privileges; then
        INSTALL_TYPE="system"
        BIN_DIR="/usr/local/bin"
        SHARE_DIR="/usr/local/share/conduit"
    else
        INSTALL_TYPE="local"
        BIN_DIR="${HOME}/.local/bin"
        SHARE_DIR="${HOME}/.local/share/conduit"
    fi
}

# Add local bin to PATH in shell profile if needed
configure_local_path() {
    local bin_dir="$1"
    local path_line="export PATH=\"${bin_dir}:\$PATH\""
    local profile_updated=false

    # Skip if already in PATH
    if echo "$PATH" | tr ':' '\n' | grep -qx "$bin_dir"; then
        return 0
    fi

    # Determine which shell profile to use
    local shell_profile=""
    if [ -n "$ZSH_VERSION" ] || [ "$SHELL" = "/bin/zsh" ]; then
        shell_profile="${HOME}/.zshrc"
    elif [ -n "$BASH_VERSION" ] || [ "$SHELL" = "/bin/bash" ]; then
        # On macOS, .bash_profile is preferred for login shells
        if [ -f "${HOME}/.bash_profile" ]; then
            shell_profile="${HOME}/.bash_profile"
        else
            shell_profile="${HOME}/.bashrc"
        fi
    else
        # Default to .profile for other shells
        shell_profile="${HOME}/.profile"
    fi

    # Check if PATH export already exists in profile
    if [ -f "$shell_profile" ] && grep -qF "$bin_dir" "$shell_profile"; then
        return 0
    fi

    # Add to shell profile
    echo "" >> "$shell_profile"
    echo "# Added by Conduit Manager installer" >> "$shell_profile"
    echo "$path_line" >> "$shell_profile"

    echo -e "${GREEN}✔${NC} Added ${bin_dir} to PATH in ${shell_profile}"
    echo -e "${YELLOW}!${NC} Run 'source ${shell_profile}' or restart your terminal to use 'conduit' command"
    return 0
}

# Initialize install paths
setup_install_paths

echo ""
echo -e "${CYAN}"
echo "  ██████╗ ██████╗ ███╗   ██╗██████╗ ██╗   ██╗██╗████████╗"
echo " ██╔════╝██╔═══██╗████╗  ██║██╔══██╗██║   ██║██║╚══██╔══╝"
echo " ██║     ██║   ██║██╔██╗ ██║██║  ██║██║   ██║██║   ██║   "
echo " ██║     ██║   ██║██║╚██╗██║██║  ██║██║   ██║██║   ██║   "
echo " ╚██████╗╚██████╔╝██║ ╚████║██████╔╝╚██████╔╝██║   ██║   "
echo "  ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═════╝  ╚═════╝ ╚═╝   ╚═╝   "
echo -e "${NC}"
echo -e "${BOLD}        Psiphon Conduit Manager Installer${NC}"
echo ""

# Check if running on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo -e "${RED}Error: This installer is for macOS only.${NC}"
    echo "For Linux, please use: https://github.com/SamNet-dev/conduit-manager"
    exit 1
fi

# Show install type
if [ "$INSTALL_TYPE" = "system" ]; then
    echo -e "${BLUE}Install type:${NC} System-wide (/usr/local)"
else
    echo -e "${BLUE}Install type:${NC} Local (~/.local) - no admin privileges detected"
fi
echo ""

# Check for Docker Desktop
echo -e "${BLUE}Checking prerequisites...${NC}"
if [ ! -d "/Applications/Docker.app" ]; then
    echo ""
    echo -e "${YELLOW}Docker Desktop is not installed.${NC}"
    echo ""
    echo "Docker Desktop is required to run Psiphon Conduit."
    echo ""
    echo -e "${BOLD}To install Docker Desktop:${NC}"
    echo "  1. Visit: https://www.docker.com/products/docker-desktop/"
    echo "  2. Download Docker Desktop for Mac"
    echo "  3. Install and launch Docker Desktop"
    echo "  4. Run this installer again"
    echo ""
    # Open browser automatically since we can't read input when piped
    echo -e "${BLUE}Opening Docker Desktop download page...${NC}"
    open "https://www.docker.com/products/docker-desktop/" 2>/dev/null || true
    exit 1
fi
echo -e "${GREEN}✔${NC} Docker Desktop is installed"

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    echo -e "${YELLOW}Docker Desktop is not running. Starting...${NC}"
    open -a Docker 2>/dev/null || true

    echo -n "Waiting for Docker to start"
    for i in {1..30}; do
        if docker info >/dev/null 2>&1; then
            echo ""
            echo -e "${GREEN}✔${NC} Docker is running"
            break
        fi
        echo -n "."
        sleep 2
    done

    if ! docker info >/dev/null 2>&1; then
        echo ""
        echo -e "${RED}Docker did not start in time.${NC}"
        echo "Please start Docker Desktop manually and run this installer again."
        exit 1
    fi
else
    echo -e "${GREEN}✔${NC} Docker is running"
fi

# Create install directory
echo -e "${BLUE}Installing Conduit Manager...${NC}"
mkdir -p "$INSTALL_DIR"

# Download the script
DOWNLOAD_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/${SCRIPT_NAME}"
echo "Downloading from: $DOWNLOAD_URL"

if command -v curl &>/dev/null; then
    curl -sL -o "${INSTALL_DIR}/${SCRIPT_NAME}" "$DOWNLOAD_URL"
elif command -v wget &>/dev/null; then
    wget -q -O "${INSTALL_DIR}/${SCRIPT_NAME}" "$DOWNLOAD_URL"
else
    echo -e "${RED}Error: Neither curl nor wget found.${NC}"
    exit 1
fi

# Verify download
if [ ! -f "${INSTALL_DIR}/${SCRIPT_NAME}" ]; then
    echo -e "${RED}Error: Download failed.${NC}"
    exit 1
fi

# Check if it's a valid bash script
if ! head -1 "${INSTALL_DIR}/${SCRIPT_NAME}" | grep -q "^#!/bin/bash"; then
    echo -e "${RED}Error: Downloaded file is not a valid script.${NC}"
    rm -f "${INSTALL_DIR}/${SCRIPT_NAME}"
    exit 1
fi

# Make executable
chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"

echo -e "${GREEN}✔${NC} Script installed to: ${INSTALL_DIR}/${SCRIPT_NAME}"

# Create symlink based on install type
SYMLINK_PATH="${BIN_DIR}/conduit"

if [ "$INSTALL_TYPE" = "local" ]; then
    # Local install: create ~/.local/bin directory and symlink
    mkdir -p "$BIN_DIR"
    ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "$SYMLINK_PATH" 2>/dev/null || true
    if [ -L "$SYMLINK_PATH" ]; then
        echo -e "${GREEN}✔${NC} Created command: conduit (in ${BIN_DIR})"
        # Configure PATH for local install
        configure_local_path "$BIN_DIR"
    fi
else
    # System install: use /usr/local/bin
    if [ -d "$BIN_DIR" ] && [ -w "$BIN_DIR" ]; then
        ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "$SYMLINK_PATH" 2>/dev/null || true
        if [ -L "$SYMLINK_PATH" ]; then
            echo -e "${GREEN}✔${NC} Created command: conduit"
            echo "  You can now run 'conduit' from anywhere"
        fi
    elif [ -d "$BIN_DIR" ]; then
        echo ""
        echo -e "${YELLOW}To add 'conduit' command system-wide, run:${NC}"
        echo "  sudo ln -sf \"${INSTALL_DIR}/${SCRIPT_NAME}\" ${BIN_DIR}/conduit"
    fi
fi

# Download and install Menu Bar app
echo -e "${BLUE}Installing Menu Bar App...${NC}"
MENUBAR_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/Conduit-MenuBar-macOS.zip"
MENUBAR_ZIP="${INSTALL_DIR}/Conduit-MenuBar.zip"
MENUBAR_APP="${INSTALL_DIR}/Conduit.app"

# Try to download the menu bar app
if command -v curl &>/dev/null; then
    curl -sL -o "$MENUBAR_ZIP" "$MENUBAR_URL" 2>/dev/null || true
elif command -v wget &>/dev/null; then
    wget -q -O "$MENUBAR_ZIP" "$MENUBAR_URL" 2>/dev/null || true
fi

# Check if download succeeded and extract
if [ -f "$MENUBAR_ZIP" ] && [ -s "$MENUBAR_ZIP" ]; then
    # Verify it's a valid zip file
    if unzip -t "$MENUBAR_ZIP" >/dev/null 2>&1; then
        rm -rf "$MENUBAR_APP" 2>/dev/null || true
        unzip -q -o "$MENUBAR_ZIP" -d "$INSTALL_DIR"
        rm -f "$MENUBAR_ZIP"

        if [ -d "$MENUBAR_APP" ]; then
            echo -e "${GREEN}✔${NC} Menu Bar app installed to: ${MENUBAR_APP}"

            # Add to Login Items (optional - runs at startup)
            # osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"${MENUBAR_APP}\", hidden:false}" 2>/dev/null || true
        fi
    else
        rm -f "$MENUBAR_ZIP"
        echo -e "${YELLOW}!${NC} Menu Bar app not available yet (build from source or wait for release)"
    fi
else
    rm -f "$MENUBAR_ZIP" 2>/dev/null || true
    echo -e "${YELLOW}!${NC} Menu Bar app not available yet (build from source or wait for release)"
fi

# Show completion message
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BOLD}What's installed:${NC}"
echo "  - Terminal Manager: ${INSTALL_DIR}/${SCRIPT_NAME}"
if [ -L "$SYMLINK_PATH" ]; then
    echo "  - Command symlink:  ${SYMLINK_PATH}"
fi
if [ -d "$MENUBAR_APP" ]; then
    echo "  - Menu Bar App:     ${MENUBAR_APP}"
fi
if [ "$INSTALL_TYPE" = "local" ]; then
    echo ""
    echo -e "  ${YELLOW}Note:${NC} Installed locally (no admin privileges)."
    echo "        PATH has been configured in your shell profile."
fi
echo ""

echo -e "${BOLD}Quick Start:${NC}"
echo ""
if [ -L "$SYMLINK_PATH" ]; then
    echo "  1. Run 'conduit' to set up and start the service"
else
    echo "  1. Run '${INSTALL_DIR}/${SCRIPT_NAME}' to set up and start"
fi
if [ -d "$MENUBAR_APP" ]; then
    echo "  2. Run 'open ${MENUBAR_APP}' to launch the menu bar app"
fi
echo ""

if [ -d "$MENUBAR_APP" ]; then
    echo -e "${BOLD}Menu Bar App:${NC}"
    echo "  The menu bar app shows status, lets you start/stop the service,"
    echo "  and copy your Node ID. Launch it with:"
    echo ""
    echo "    open ${MENUBAR_APP}"
    echo ""
    echo "  To start automatically at login, drag Conduit.app to:"
    echo "    System Settings > General > Login Items"
    echo ""
fi

echo -e "${YELLOW}To complete initial setup, run:${NC}"
echo ""
echo -e "  ${CYAN}~/conduit-manager/conduit-mac.sh${NC}"
echo ""
