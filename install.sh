#!/bin/bash
#
# XeroHomeLab Installer - Quick Launch Script
# Run with: curl -fsSL https://raw.githubusercontent.com/DarkXero-dev/HomeLabTest/main/install.sh | bash
# Repo:     https://github.com/DarkXero-dev/HomeLabTest

set +e

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

echo -e "${PURPLE}"
clear
cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║                       ✨ XeroHomeLab Installer v0.1 ✨                        ║
║                                                                               ║
║      Headless Arch base + curated HomeLab tooling — no DE, no WM, no GUI      ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# ── Preflight Checks ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root${NC}"
    echo ""
    echo "Please run:"
    echo -e "  ${CYAN}sudo bash <(curl -fsSL https://raw.githubusercontent.com/DarkXero-dev/HomeLabTest/main/install.sh)${NC}"
    exit 1
fi

echo -e "${CYAN}Checking internet connection (might take a bit)...${NC}"
if ! ping -c 1 -W 3 xerolinux.xyz &>/dev/null; then
    echo -e "${RED}Error: No internet connection${NC}"
    echo "Please connect to the internet and try again."
    echo ""
    echo "For WiFi, use: iwctl"
    exit 1
fi
echo -e "${GREEN}✓ Internet connected${NC}"

if [[ ! -f /etc/arch-release ]]; then
    echo -e "${RED}Error: This script must be run from the Arch Linux live ISO${NC}"
    exit 1
fi

# ── Dependencies ─────────────────────────────────────────────────────────────
echo -e "${CYAN}Installing dependencies...${NC}"
pacman -Sy --noconfirm --needed gum arch-install-scripts parted dosfstools btrfs-progs &>/dev/null || true
echo -e "${GREEN}✓ Dependencies installed${NC}"

# ── Download Installer ────────────────────────────────────────────────────────
# Temp dir is cleaned up automatically on exit
INSTALL_DIR=$(mktemp -d)
trap 'rm -rf "$INSTALL_DIR"' EXIT
cd "$INSTALL_DIR"

echo -e "${CYAN}Downloading XeroHomeLab Installer...${NC}"
INSTALLER_URL="https://raw.githubusercontent.com/DarkXero-dev/HomeLabTest/main/xerohomelab-install.sh"
curl -fsSL "$INSTALLER_URL" -o xerohomelab-install.sh
if [[ ! -s xerohomelab-install.sh ]]; then
    echo -e "${RED}Error: Failed to download installer (empty file)${NC}"
    exit 1
fi
chmod +x xerohomelab-install.sh
echo -e "${GREEN}✓ Installer downloaded${NC}"

# ── Download HomeLab Tooling Script ─────────────────────────────────────────────
# Failure is non-fatal — the main installer will re-fetch if needed
echo -e "${CYAN}Downloading XeroHomeLab tooling script...${NC}"
TOOLS_URL="https://raw.githubusercontent.com/DarkXero-dev/HomeLabTest/main/xerohomelab-tools.sh"
curl -fsSL "$TOOLS_URL" -o /root/xerohomelab-tools.sh 2>/dev/null || {
    echo -e "${CYAN}Note: tooling script will be downloaded during installation${NC}"
}
[[ -f /root/xerohomelab-tools.sh ]] && chmod +x /root/xerohomelab-tools.sh
echo -e "${GREEN}✓ Ready to install${NC}"

# ── Launch ────────────────────────────────────────────────────────────────────
echo -e "${PURPLE}Starting installer...${NC}"
sleep 1
exec bash xerohomelab-install.sh
