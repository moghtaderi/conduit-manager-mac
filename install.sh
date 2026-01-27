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
    read -p "Open Docker Desktop download page? [y/N]: " open_browser
    if [[ "$open_browser" =~ ^[Yy]$ ]]; then
        open "https://www.docker.com/products/docker-desktop/" 2>/dev/null || true
    fi
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

# Create symlink in /usr/local/bin if possible
SYMLINK_PATH="/usr/local/bin/conduit"
if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
    ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "$SYMLINK_PATH" 2>/dev/null || true
    if [ -L "$SYMLINK_PATH" ]; then
        echo -e "${GREEN}✔${NC} Created command: conduit"
        echo "  You can now run 'conduit' from anywhere"
    fi
elif [ -d "/usr/local/bin" ]; then
    echo ""
    echo -e "${YELLOW}To add 'conduit' command system-wide, run:${NC}"
    echo "  sudo ln -sf \"${INSTALL_DIR}/${SCRIPT_NAME}\" /usr/local/bin/conduit"
fi

# Create alias suggestion
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}To run Conduit Manager:${NC}"
echo ""
echo "  ${INSTALL_DIR}/${SCRIPT_NAME}"
echo ""
if [ -L "$SYMLINK_PATH" ]; then
    echo "  Or simply: conduit"
    echo ""
fi

# Offer to run immediately
read -p "Launch Conduit Manager now? [Y/n]: " launch_now
if [[ ! "$launch_now" =~ ^[Nn]$ ]]; then
    echo ""
    exec "${INSTALL_DIR}/${SCRIPT_NAME}"
fi
