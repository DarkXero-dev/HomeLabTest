#!/bin/bash
#
# XeroHomeLab Tooling Installer v0.1
#
# Stage 2 of the XeroHomeLab install. Runs INSIDE the target chroot as the
# unprivileged user created by xerohomelab-install.sh, with passwordless sudo
# granted for the duration. Installs the curated HomeLab toolset — NO desktop,
# NO window manager, NO display server. Headless server tooling only.
#
# All packages come from the official repos + xerolinux + chaotic-aur (enabled
# by stage 1), so plain pacman covers everything — no AUR helper required.
#
# Invocation (from xerohomelab-install.sh):
#   bash xerohomelab-tools.sh <filesystem>
#
# Can also be run standalone on an existing system.
#
# License: GPL-3.0

set -uo pipefail

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "")"

# Filesystem type passed as $1 from xerohomelab-install.sh; empty when standalone
FILESYSTEM="${1:-}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    clear
    echo -e "${PURPLE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║                                                ║${NC}"
    echo -e "${PURPLE}║${CYAN}      ✨ XeroHomeLab Tooling Installer ✨       ${PURPLE}║${NC}"
    echo -e "${PURPLE}║                                                ║${NC}"
    echo -e "${PURPLE}╚════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_step()    { echo -e "${BLUE}➜${NC} ${CYAN}$1${NC}"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; sleep 1; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; sleep 1; }

# ── Environment detection ─────────────────────────────────────────────────────

# NOTE: intentionally duplicated from xerohomelab-install.sh — this script runs
# standalone inside the target chroot as an unprivileged user, so it needs its
# own copy and cannot share a common library file.
detect_chroot() {
    if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ] 2>/dev/null; then
        return 0
    elif [ -f /etc/arch-chroot ]; then
        return 0
    elif [ "${EUID:-0}" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
        return 0
    else
        return 1
    fi
}

setup_sudo() {
    if [ "${EUID:-0}" -eq 0 ]; then
        SUDO_CMD=""
        print_step "Running as root (chroot environment)"
    else
        SUDO_CMD="sudo"
    fi
}

# NOTE: opposite logic from xerohomelab-install.sh —
#   xerohomelab-install.sh REQUIRES root (live ISO context).
#   This script REJECTS root unless inside a chroot (user context).
check_root() {
    if [[ ${EUID:-0} -eq 0 ]] && ! detect_chroot; then
        print_error "Do not run this script as root outside a chroot!"
        exit 1
    fi
    setup_sudo
}

# Target user + home (this script runs AS the user via `su -l`)
TARGET_USER="$(id -un)"
TARGET_HOME="$HOME"
IN_CHROOT="no"
detect_chroot && IN_CHROOT="yes"

# ── Package helpers ────────────────────────────────────────────────────────────

# install_group <name> <pkg...>
# Bulk install via pacman; on any failure retries each package individually.
# Never aborts — reports skipped packages as warnings.
install_group() {
    local group_name="$1"; shift
    local pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && { print_warning "[$group_name] No packages defined — skipping"; return 0; }

    print_step "[$group_name] Installing ${#pkgs[@]} packages..."

    if $SUDO_CMD pacman -S --needed --noconfirm "${pkgs[@]}" 2>/dev/null; then
        print_success "[$group_name] Done!"
        echo ""
        return 0
    fi

    print_warning "[$group_name] Bulk install failed — retrying individually..."
    local failed=() installed=0
    for pkg in "${pkgs[@]}"; do
        if $SUDO_CMD pacman -S --needed --noconfirm "$pkg" 2>/dev/null; then
            (( installed++ )) || true
        else
            failed+=("$pkg")
        fi
    done

    [[ ${#failed[@]} -gt 0 ]] && \
        print_warning "[$group_name] Skipped (${#failed[@]}): ${failed[*]}"
    print_success "[$group_name] Done — $installed installed, ${#failed[@]} skipped."
    echo ""
    return 0
}

# install_group_required <name> <pkg...>  — aborts if ZERO packages installed.
install_group_required() {
    local group_name="$1"; shift
    local pkgs=("$@")

    print_step "[$group_name] Installing ${#pkgs[@]} packages (required)..."
    if $SUDO_CMD pacman -S --needed --noconfirm "${pkgs[@]}" 2>/dev/null; then
        print_success "[$group_name] Done!"
        echo ""
        return 0
    fi

    print_warning "[$group_name] Bulk install failed — retrying individually..."
    local failed=() installed=0
    for pkg in "${pkgs[@]}"; do
        if $SUDO_CMD pacman -S --needed --noconfirm "$pkg" 2>/dev/null; then
            (( installed++ )) || true
        else
            failed+=("$pkg")
        fi
    done
    [[ ${#failed[@]} -gt 0 ]] && \
        print_warning "[$group_name] Skipped (${#failed[@]}): ${failed[*]}"

    if [[ $installed -eq 0 ]]; then
        print_error "[$group_name] Critical: zero packages installed — aborting!"
        exit 1
    fi
    print_success "[$group_name] Done — $installed installed, ${#failed[@]} skipped."
    echo ""
    return 0
}

# ── Service helpers ─────────────────────────────────────────────────────────────

enable_service_if_available() {
    local svc="$1"
    if $SUDO_CMD systemctl cat "$svc" &>/dev/null; then
        $SUDO_CMD systemctl enable "$svc" \
            && print_success "Enabled: $svc" \
            || print_warning "Failed to enable $svc"
    else
        print_warning "Unit $svc not found — skipping"
    fi
}

enable_if_installed() {
    local pkg="$1"
    local svc="${2:-$1}"
    if $SUDO_CMD pacman -Qq "$pkg" &>/dev/null; then
        enable_service_if_available "$svc"
    else
        print_warning "Package $pkg not installed — skipping $svc"
    fi
}

# ════════════════════════════════════════════════════════════════════════════════
# BASELINE
# ════════════════════════════════════════════════════════════════════════════════

# Always-on CLI baseline + support utilities for a headless box.
install_baseline() {
    install_group "Core CLI" \
        vim nano git wget curl rsync htop btop tmux zsh fastfetch \
        man-db man-pages bash-completion unzip zip tar openssh

    install_group "Support utils" \
        jq yq fzf ripgrep fd bat eza ncdu tree lsof age sops

    # SSH is the lifeline of a headless box — enable it.
    enable_if_installed openssh sshd
}

# ════════════════════════════════════════════════════════════════════════════════
# DOCKER CORE  (always installed)
# ════════════════════════════════════════════════════════════════════════════════

setup_docker() {
    # Full, usable Docker stack: engine, CLI plugins, BuildKit, Buildx, Compose.
    install_group_required "Docker" \
        docker docker-compose docker-buildx containerd

    # Add the target user to the docker group (no sudo for docker commands).
    print_step "Adding ${TARGET_USER} to the 'docker' group..."
    $SUDO_CMD usermod -aG docker "$TARGET_USER" \
        && print_success "${TARGET_USER} added to docker group (effective on next login)" \
        || print_warning "Could not add ${TARGET_USER} to docker group"

    # Enable the daemon so it starts on boot.
    enable_if_installed docker docker.service

    # Make network-online.target actually WAIT for connectivity, otherwise the
    # first-boot compose units race ahead of DHCP and image pulls fail.
    enable_if_installed networkmanager NetworkManager-wait-online.service

    # If we are on a live system (not a bare chroot), start it now too.
    if [[ "$IN_CHROOT" == "no" ]]; then
        $SUDO_CMD systemctl start docker.service 2>/dev/null \
            && print_success "docker.service started" \
            || print_warning "Could not start docker.service now — will start on boot"
    else
        print_step "Chroot detected — docker.service will start on first boot"
    fi
}

# ════════════════════════════════════════════════════════════════════════════════
# FIRST-BOOT COMPOSE BRING-UP HELPER
# ════════════════════════════════════════════════════════════════════════════════
# Docker isn't running in the chroot, so all stacks come up on first boot. A plain
# oneshot `docker compose up -d` races the daemon and the network: if dockerd isn't
# ready yet or DHCP hasn't leased, the image pull fails and the stack never starts.
# This wrapper waits for the daemon, retries the pull, and only marks the unit done
# (flag file + self-disable) on SUCCESS — so a transient failure retries next boot.
#   usage: xerohomelab-compose-up <unit-name> <compose-file> <done-flag>
install_compose_helper() {
    print_step "Installing first-boot compose bring-up helper..."
    $SUDO_CMD tee /usr/local/bin/xerohomelab-compose-up >/dev/null << 'HELPER'
#!/bin/sh
# Robust first-boot bring-up of a docker compose stack.
unit="$1"; file="$2"; flag="$3"
[ -n "$unit" ] && [ -n "$file" ] && [ -n "$flag" ] || { echo "usage: $0 <unit> <compose-file> <flag>" >&2; exit 2; }

# Wait up to ~2 min for the docker daemon to accept connections.
i=0
while ! docker info >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge 60 ] && { echo "docker daemon not ready" >&2; exit 1; }
    sleep 2
done

# Bring the stack up, retrying to ride out slow/transient image pulls.
n=0
until docker compose -f "$file" up -d; do
    n=$((n + 1)); [ "$n" -ge 5 ] && { echo "compose up failed after $n tries" >&2; exit 1; }
    echo "compose up failed (try $n) — retrying in 15s" >&2
    sleep 15
done

# Success — don't run again.
touch "$flag"
systemctl disable "$unit"
HELPER
    $SUDO_CMD chmod 755 /usr/local/bin/xerohomelab-compose-up
    print_success "Bring-up helper installed"
}

# ════════════════════════════════════════════════════════════════════════════════
# PORTAINER  (web UI — auto-started on first boot, then deploy apps via its UI)
# ════════════════════════════════════════════════════════════════════════════════

PORTAINER_DIR="${TARGET_HOME}/homelab/portainer"

write_portainer_stack() {
    print_step "Writing Portainer compose stack to ${PORTAINER_DIR}..."
    mkdir -p "$PORTAINER_DIR"
    cat > "${PORTAINER_DIR}/docker-compose.yml" << 'COMPOSE'
# Portainer CE — web UI for managing Docker. Deploy all other HomeLab apps
# (Jellyfin, *arr, Vaultwarden, etc.) as stacks from here: https://<host>:9443
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "8000:8000"   # Edge agent tunnel
      - "9443:9443"   # HTTPS web UI
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - portainer_data:/data
volumes:
  portainer_data:
COMPOSE
    print_success "Portainer stack written"
}

# Docker is NOT running inside the chroot, so we can't `compose up` now.
# Install a first-boot oneshot service that brings Portainer up after
# docker.service is active, then disables itself.
install_portainer_firstboot() {
    print_step "Installing Portainer first-boot bring-up service..."
    $SUDO_CMD tee /etc/systemd/system/xerohomelab-portainer.service >/dev/null << UNIT
[Unit]
Description=First-boot bring-up of Portainer stack (XeroHomeLab)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/xerohomelab-portainer-initialized

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/xerohomelab-compose-up xerohomelab-portainer.service ${PORTAINER_DIR}/docker-compose.yml /var/lib/xerohomelab-portainer-initialized

[Install]
WantedBy=multi-user.target
UNIT
    $SUDO_CMD systemctl enable xerohomelab-portainer.service 2>/dev/null \
        && print_success "Portainer will auto-start on first boot (https://<host>:9443)" \
        || print_warning "Could not enable Portainer first-boot service"

    # On a live system, bring it up immediately.
    if [[ "$IN_CHROOT" == "no" ]]; then
        $SUDO_CMD systemctl start xerohomelab-portainer.service 2>/dev/null || true
    fi
}

# Portainer locks its initial admin-creation page ~5 min after the container
# starts (anti-hijack). On a headless box you rarely reach the UI within that
# window of first boot. This timer restarts Portainer while NO admin exists yet,
# keeping the setup window perpetually fresh — and self-disables the moment an
# admin account is created. No credentials are stored anywhere.
install_portainer_setup_keepalive() {
    print_step "Installing Portainer setup-window keepalive..."

    $SUDO_CMD tee /usr/local/bin/xerohomelab-portainer-setup-check >/dev/null << 'CHECK'
#!/bin/sh
# Returns 204 if a Portainer admin exists, 404 if not yet, other if not ready.
code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 5 \
    https://localhost:9443/api/users/admin/check 2>/dev/null)
case "$code" in
    204) # admin configured — job done, stop restarting
        systemctl disable --now xerohomelab-portainer-setup.timer 2>/dev/null ;;
    404) # no admin yet — reset the 5-minute setup window
        docker restart portainer 2>/dev/null ;;
    *)   : ;; # not up yet (000/5xx) — wait for the next tick
esac
CHECK
    $SUDO_CMD chmod 755 /usr/local/bin/xerohomelab-portainer-setup-check

    $SUDO_CMD tee /etc/systemd/system/xerohomelab-portainer-setup.service >/dev/null << 'UNIT'
[Unit]
Description=Keep Portainer initial-setup window open until admin is created (XeroHomeLab)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xerohomelab-portainer-setup-check
UNIT

    $SUDO_CMD tee /etc/systemd/system/xerohomelab-portainer-setup.timer >/dev/null << 'UNIT'
[Unit]
Description=Periodic Portainer setup-window keepalive (XeroHomeLab)

[Timer]
OnBootSec=90s
OnUnitActiveSec=3min
Persistent=false

[Install]
WantedBy=timers.target
UNIT

    $SUDO_CMD systemctl enable xerohomelab-portainer-setup.timer 2>/dev/null \
        && print_success "Setup window stays open until you create the admin user" \
        || print_warning "Could not enable Portainer setup keepalive timer"

    if [[ "$IN_CHROOT" == "no" ]]; then
        $SUDO_CMD systemctl start xerohomelab-portainer-setup.timer 2>/dev/null || true
    fi
}

# ════════════════════════════════════════════════════════════════════════════════
# BESZEL  (lightweight, fully-free/MIT monitoring — hub web UI on :8090)
# ════════════════════════════════════════════════════════════════════════════════
# Beszel = a hub (web dashboard) + one agent per monitored host. The agent needs
# the hub's SSH public KEY, which the hub mints when you click "Add system" in the
# UI — so the agent can't be auto-registered ahead of time. We auto-start the hub
# on first boot (like Portainer) and pre-write the agent compose as a ready
# template: open the hub, add a system, paste the KEY it shows, `compose up`.

BESZEL_DIR="${TARGET_HOME}/homelab/beszel"

write_beszel_stack() {
    print_step "Writing Beszel compose stack to ${BESZEL_DIR}..."
    mkdir -p "$BESZEL_DIR"

    # Hub — auto-started on first boot. Web UI on :8090.
    cat > "${BESZEL_DIR}/docker-compose.yml" << 'COMPOSE'
# Beszel hub — lightweight server monitoring dashboard (MIT, fully free).
# Web UI: http://<host>:8090  —  create the admin user on first visit, then
# "Add system" to register this host (it hands you the agent KEY for agent-compose.yml).
services:
  beszel:
    image: henrygd/beszel:latest
    container_name: beszel
    restart: unless-stopped
    ports:
      - "8090:8090"
    volumes:
      - ./beszel_data:/beszel_data
COMPOSE

    # Agent — template. Paste the KEY from the hub UI, then: docker compose -f agent-compose.yml up -d
    cat > "${BESZEL_DIR}/agent-compose.yml" << 'COMPOSE'
# Beszel AGENT for THIS host. To enable local-host metrics in the hub:
#   1. Open the hub (http://<host>:8090), create the admin user.
#   2. Click "Add system" → it shows an "ssh-ed25519 ..." public key.
#   3. Paste that whole key into the KEY value below.
#   4. cd ~/homelab/beszel && docker compose -f agent-compose.yml up -d
services:
  beszel-agent:
    image: henrygd/beszel-agent:latest
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      LISTEN: 45876
      KEY: 'PASTE_HUB_PUBLIC_KEY_HERE'
COMPOSE

    print_success "Beszel stack written (hub auto-starts; agent is a ready template)"
}

# Docker isn't running in the chroot — bring the hub up on first boot, then disable.
install_beszel_firstboot() {
    print_step "Installing Beszel hub first-boot bring-up service..."
    $SUDO_CMD tee /etc/systemd/system/xerohomelab-beszel.service >/dev/null << UNIT
[Unit]
Description=First-boot bring-up of Beszel monitoring hub (XeroHomeLab)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/xerohomelab-beszel-initialized

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/xerohomelab-compose-up xerohomelab-beszel.service ${BESZEL_DIR}/docker-compose.yml /var/lib/xerohomelab-beszel-initialized

[Install]
WantedBy=multi-user.target
UNIT
    $SUDO_CMD systemctl enable xerohomelab-beszel.service 2>/dev/null \
        && print_success "Beszel hub will auto-start on first boot (http://<host>:8090)" \
        || print_warning "Could not enable Beszel first-boot service"

    if [[ "$IN_CHROOT" == "no" ]]; then
        $SUDO_CMD systemctl start xerohomelab-beszel.service 2>/dev/null || true
    fi
}

# ════════════════════════════════════════════════════════════════════════════════
# OPTIONAL HOST GROUPS  (all selected at build time)
# ════════════════════════════════════════════════════════════════════════════════

# Docker TUI/CLI — makes the docker host usable from the terminal.
install_docker_cli() {
    install_group "Docker TUI/CLI" lazydocker ctop dive
}

# Networking / remote access. tailscaled enabled; cloudflared needs manual config.
install_networking() {
    install_group "Networking" tailscale cloudflared wireguard-tools
    enable_if_installed tailscale tailscaled
    print_warning "tailscale: run 'sudo tailscale up' after boot to join your tailnet"
    print_warning "cloudflared: configure a tunnel before enabling its service"
}

# Storage / NAS host tooling.
# NOTE: snapraid is AUR-only (not in chaotic-aur) — omitted since we use no AUR
# helper. Build it manually post-install if needed: makepkg from the AUR.
install_storage() {
    install_group "Storage / NAS" smartmontools nfs-utils samba mergerfs hdparm
    enable_if_installed smartmontools smartd
}

# Backup CLIs.
install_backup() {
    install_group "Backup" restic rclone borg
}

# ── Login banner (headless visibility) ──────────────────────────────────────────
# Headless box boots to a TTY — the first-boot Portainer bring-up happens silently.
# This /etc/profile.d banner shows live status + access URLs on every TTY/SSH login.
install_welcome_motd() {
    print_step "Installing HomeLab login banner..."
    $SUDO_CMD tee /etc/profile.d/xerohomelab-welcome.sh >/dev/null << 'WELCOME'
#!/bin/sh
# XeroHomeLab login banner — generated by xerohomelab-tools.sh

_xhl_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
[ -z "$_xhl_ip" ] && _xhl_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$_xhl_ip" ] && _xhl_ip="<host-ip>"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx portainer; then
    _xhl_port="\033[0;32m● running\033[0m"
elif docker info >/dev/null 2>&1; then
    _xhl_port="\033[0;33m○ not running\033[0m → sudo systemctl start xerohomelab-portainer.service"
else
    _xhl_port="\033[0;33m? need docker access\033[0m → re-login, or: sudo docker ps"
fi

printf '\n\033[0;35m╔═══════════════════ XeroHomeLab ═══════════════════╗\033[0m\n'
printf '  Host IP    : \033[0;36m%s\033[0m\n' "$_xhl_ip"
printf '  Portainer  : %b\n' "$_xhl_port"
printf '               \033[0;32mhttps://%s:9443\033[0m\n' "$_xhl_ip"
printf '  Beszel     : \033[0;32mhttp://%s:8090\033[0m\n' "$_xhl_ip"
printf '\033[0;35m╚═══════════════════════════════════════════════════╝\033[0m\n\n'
unset _xhl_ip _xhl_port
WELCOME
    $SUDO_CMD chmod 644 /etc/profile.d/xerohomelab-welcome.sh
    print_success "Login banner installed (shows on every TTY/SSH login)"
}

# ── OS branding ──────────────────────────────────────────────────────────────────
# Make fastfetch / neofetch / login show the distro as "Xero ArchLab".
# /etc/os-release is normally a symlink → /usr/lib/os-release (owned by the
# 'filesystem' package). We replace it with a REAL file so our branding survives
# package upgrades — pacman writes a /etc/os-release.pacnew instead of clobbering.
# ID stays 'arch' so package tooling, AUR detection and the logo keep working.
brand_os_release() {
    print_step "Branding OS as 'Xero ArchLab'..."
    $SUDO_CMD rm -f /etc/os-release
    $SUDO_CMD tee /etc/os-release >/dev/null << 'OSREL'
NAME="Xero ArchLab"
PRETTY_NAME="Xero ArchLab"
ID=archlab
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://github.com/DarkXero-dev/HomeLabTest"
SUPPORT_URL="https://github.com/DarkXero-dev/HomeLabTest/issues"
BUG_REPORT_URL="https://github.com/DarkXero-dev/HomeLabTest/issues"
LOGO=archlinux-logo
OSREL
    $SUDO_CMD chmod 644 /etc/os-release
    print_success "os-release branded — fastfetch will show 'Xero ArchLab'"
}

# ── Finalize / completion ────────────────────────────────────────────────────────

finalize_system() {
    print_step "Finalizing..."
    # Btrfs tooling if root fs is btrfs (snapshots configured by stage 1).
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        install_group "Btrfs Tools" btrfs-assistant snapper snap-pac
    fi
    brand_os_release
    install_welcome_motd
    print_success "Done."
}

show_completion() {
    print_header
    echo -e "${GREEN}✨ XeroHomeLab tooling installation complete! ✨${NC}"
    echo ""
    echo -e "  ${BLUE}•${NC} Docker engine + compose + buildx installed; ${GREEN}${TARGET_USER}${NC} in docker group"
    echo -e "  ${BLUE}•${NC} Beszel monitoring → ${GREEN}http://<host-ip>:8090${NC} (add this host via its UI)"
    echo -e "  ${BLUE}•${NC} Host tools: Docker CLI, Networking, Storage/NAS, Backup"
    echo ""
    echo -e "${PURPLE}┌────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${PURPLE}│${NC}  ${CYAN}PORTAINER — deploy & manage all your containers from a UI${NC}  ${PURPLE}│${NC}"
    echo -e "${PURPLE}└────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  Portainer is ${YELLOW}NOT running yet${NC} — Docker can't start inside the"
    echo -e "  installer chroot. It is brought up ${GREEN}automatically on first boot${NC}"
    echo -e "  by the ${CYAN}xerohomelab-portainer.service${NC} unit (one-time, then self-disables)."
    echo ""
    echo -e "  ${BLUE}After you reboot:${NC}"
    echo -e "    1. Find the host IP:   ${GREEN}ip -4 addr | grep inet${NC}"
    echo -e "    2. Open in a browser:  ${GREEN}https://<host-ip>:9443${NC}   (accept the self-signed cert)"
    echo -e "    3. Create the ${YELLOW}admin user + password${NC}. (Portainer's 5-min setup lock is"
    echo -e "       auto-refreshed by a timer until you do this — no rush, no restart needed.)"
    echo -e "    4. Deploy stacks (Jellyfin, *arr, Vaultwarden, …) from the UI."
    echo ""
    echo -e "  ${BLUE}Verify it came up (run on the booted system):${NC}"
    echo -e "    ${GREEN}systemctl status xerohomelab-portainer.service${NC}"
    echo -e "    ${GREEN}docker ps${NC}        # should list the 'portainer' container"
    echo -e "    Compose file: ${CYAN}${PORTAINER_DIR}/docker-compose.yml${NC}"
    echo -e "    If it did not start: ${GREEN}cd ${PORTAINER_DIR} && docker compose up -d${NC}"
    echo ""
    echo -e "  ${BLUE}Other:${NC}"
    echo -e "    • ${GREEN}sudo tailscale up${NC} to join your tailnet"
    echo -e "    • Re-login (or ${GREEN}newgrp docker${NC}) so docker group membership applies"
    echo ""
    # Pause so the user actually reads this before the installer's final screen.
    read -rp "$(echo -e "${CYAN}Press Enter to finish...${NC}")" _
}

# ── Main ─────────────────────────────────────────────────────────────────────────

main() {
    print_header
    check_root

    print_step "User: ${TARGET_USER}   Home: ${TARGET_HOME}   Chroot: ${IN_CHROOT}   FS: ${FILESYSTEM:-n/a}"
    echo ""

    install_baseline

    # Docker core (always) + Portainer
    setup_docker
    install_compose_helper
    write_portainer_stack
    install_portainer_firstboot
    install_portainer_setup_keepalive

    # Monitoring — Beszel (free/MIT)
    write_beszel_stack
    install_beszel_firstboot

    # Selected optional host groups
    install_docker_cli
    install_networking
    install_storage
    install_backup

    finalize_system
    show_completion
}

# Only auto-run when executed directly; allows sourcing for tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
