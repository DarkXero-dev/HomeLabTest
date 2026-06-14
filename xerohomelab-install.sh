#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════════════════╗
# ║                                                                               ║
# ║                       ✨ XeroHomeLab Installer v0.1 ✨                        ║
# ║                                                                               ║
# ║     A headless Arch base + curated HomeLab tooling — no DE, no WM, no GUI     ║
# ║                                                                               ║
# ╚═══════════════════════════════════════════════════════════════════════════════╝
#
# Author: XeroLinux Team
# License: GPL-3.0
#

set -Eeuo pipefail

# ────────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ────────────────────────────────────────────────────────────────────────────────

VERSION="0.1"
SCRIPT_NAME="XeroHomeLab Installer"

# URL for fetching the HomeLab tooling stage script (runs in chroot, post-base)
XERO_TOOLS_URL="https://raw.githubusercontent.com/DarkXero-dev/HomeLabTest/main/xerohomelab-tools.sh"

# Mountpoint for installation
MOUNTPOINT="/mnt"

# Colors (fallback)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Installation configuration (associative array)
declare -A CONFIG
CONFIG[installer_lang]="English"
CONFIG[locale]="en_US.UTF-8"
CONFIG[keyboard]="us"
CONFIG[timezone]="UTC"
CONFIG[hostname]="xerolinux"
CONFIG[username]=""
CONFIG[user_password]=""
CONFIG[root_password]=""
CONFIG[disk]=""
CONFIG[filesystem]="btrfs"
CONFIG[swap]="zram"
CONFIG[swap_algo]="zstd"
CONFIG[parallel_downloads]="5"
CONFIG[extra_kernel]=""
CONFIG[uefi]="no"
CONFIG[boot_part]=""
CONFIG[root_part]=""
CONFIG[partition_mode]="auto"
CONFIG[reuse_efi]="no"

# ────────────────────────────────────────────────────────────────────────────────
# ERROR HANDLING
# ────────────────────────────────────────────────────────────────────────────────

have_gum() { command -v gum &>/dev/null; }

on_err() {
    local exit_code=$?
    local line_no=${1:-?}
    local cmd=${2:-?}

    if have_gum; then
        gum style --foreground 196 --bold --margin "1 2" \
            "❌ ERROR (exit=$exit_code) at line $line_no" \
            "$cmd"
        echo ""
        gum style --foreground 245 --margin "0 2" \
            "Tip: If this was during formatting, it's often missing partitions (udev timing) or empty device paths."
        echo ""
        gum input --placeholder "Press Enter to exit..."
    else
        echo -e "${RED}ERROR (exit=$exit_code) at line $line_no${NC}"
        echo -e "${RED}$cmd${NC}"
    fi

    exit "$exit_code"
}

trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

# ────────────────────────────────────────────────────────────────────────────────
# UTILITY FUNCTIONS
# ────────────────────────────────────────────────────────────────────────────────

# Detect if running in chroot environment
# NOTE: also present in xerohomelab-tools.sh — both scripts run standalone in
# different contexts and cannot share a common library file.
detect_chroot() {
    if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ] 2>/dev/null; then
        return 0  # In chroot
    elif [ -f /etc/arch-chroot ]; then
        return 0  # In chroot
    elif [ "${EUID:-0}" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
        return 0  # Running as root without sudo (likely chroot)
    else
        return 1  # Not in chroot
    fi
}

# Set up sudo command (empty if running as root/in chroot)
setup_sudo() {
    if [ "${EUID:-0}" -eq 0 ]; then
        SUDO_CMD=""
    else
        SUDO_CMD="sudo"
    fi
}

check_root() {
    if [[ ${EUID:-0} -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root${NC}"
        echo "Please run: sudo $0"
        exit 1
    fi
    setup_sudo
}

check_uefi() {
    if [[ -d /sys/firmware/efi/efivars ]]; then
        CONFIG[uefi]="yes"
    else
        CONFIG[uefi]="no"
    fi
}

# Cache so we never "re-check" during the same run
INTERNET_OK="no"

check_internet() {
    [[ "$INTERNET_OK" == "yes" ]] && return 0

    if ping -c 1 -W 3 archlinux.org &>/dev/null; then
        INTERNET_OK="yes"
        return 0
    fi

    echo -e "${RED}Error: No internet connection (or DNS is broken)${NC}"
    echo "Fix networking, then re-run the installer."
    exit 1
}

ensure_dependencies() {
    local deps_needed=()

    command -v gum &>/dev/null || deps_needed+=("gum")
    command -v parted &>/dev/null || deps_needed+=("parted")
    command -v arch-chroot &>/dev/null || deps_needed+=("arch-install-scripts")

    command -v sgdisk &>/dev/null || deps_needed+=("gptfdisk")
    command -v mkfs.btrfs &>/dev/null || deps_needed+=("btrfs-progs")
    command -v mkfs.fat &>/dev/null || deps_needed+=("dosfstools")
    command -v mkfs.ext4 &>/dev/null || deps_needed+=("e2fsprogs")
    command -v mkfs.xfs &>/dev/null || deps_needed+=("xfsprogs")
    command -v curl &>/dev/null || deps_needed+=("curl")

    if [[ ${#deps_needed[@]} -gt 0 ]]; then
        echo -e "${CYAN}Installing required dependencies...${NC}"
        pacman -Sy --noconfirm "${deps_needed[@]}" &>/dev/null
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# GUM UI HELPERS
# ────────────────────────────────────────────────────────────────────────────────

show_header() {
    clear
    gum style \
        --foreground 212 --border-foreground 212 --border double \
        --align center --width 70 --margin "1 2" --padding "1 2" \
        "✨ $SCRIPT_NAME v$VERSION ✨" \
        "" \
        "A beautiful Arch Linux installer for XeroLinux"
}

show_submenu_header() {
    local title="$1"
    gum style \
        --foreground 212 --bold --margin "1 2" \
        "$title"
}

show_info() {
    gum style \
        --foreground 81 --margin "0 2" \
        "$1"
}

show_success() {
    gum style --foreground 82 "  ✓ $1"
}

show_error() {
    gum style --foreground 196 "  ✗ $1"
}

show_warning() {
    gum style --foreground 214 "  ⚠ $1"
}

confirm_action() {
    gum confirm --affirmative "Yes" --negative "No" "$1"
}

run_step() {
    # Runs a function/command in the CURRENT shell (no subshell),
    # so CONFIG changes persist. If it fails, the ERR trap prints details.
    local title="$1"
    shift
    show_info "$title"
    "$@"
    show_success "${title%...}"
}

# ────────────────────────────────────────────────────────────────────────────────
# 1. INSTALLER LANGUAGE
# ────────────────────────────────────────────────────────────────────────────────

select_installer_language() {
    show_header
    show_submenu_header "🌐 Installer Language"
    echo ""
    show_info "Select the language for this installer interface"
    echo ""

    local languages=(
        "English"
        "Deutsch (German)"
        "Español (Spanish)"
        "Français (French)"
        "Italiano (Italian)"
        "Português (Portuguese)"
        "Русский (Russian)"
        "日本語 (Japanese)"
        "中文 (Chinese)"
        "한국어 (Korean)"
        "العربية (Arabic)"
        "Polski (Polish)"
        "Nederlands (Dutch)"
        "Türkçe (Turkish)"
    )

    local selection=""
    selection=$(printf '%s\n' "${languages[@]}" | gum choose --height 15 --header "Choose language:") || true

    if [[ -n "$selection" ]]; then
        CONFIG[installer_lang]="$selection"
        show_success "Language set to: $selection"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 2. LOCALES (System Language + Keyboard)
# ────────────────────────────────────────────────────────────────────────────────

select_locales() {
    show_header
    show_submenu_header "🗺️ System Locales"
    echo ""

    show_info "Select your system locale (language & encoding)"
    echo ""

    local locales=(
        "en_US.UTF-8"
        "en_GB.UTF-8"
        "de_DE.UTF-8"
        "fr_FR.UTF-8"
        "es_ES.UTF-8"
        "it_IT.UTF-8"
        "pt_BR.UTF-8"
        "pt_PT.UTF-8"
        "ru_RU.UTF-8"
        "ja_JP.UTF-8"
        "ko_KR.UTF-8"
        "zh_CN.UTF-8"
        "zh_TW.UTF-8"
        "ar_SA.UTF-8"
        "pl_PL.UTF-8"
        "nl_NL.UTF-8"
        "tr_TR.UTF-8"
        "vi_VN.UTF-8"
        "sv_SE.UTF-8"
        "da_DK.UTF-8"
        "fi_FI.UTF-8"
        "nb_NO.UTF-8"
        "cs_CZ.UTF-8"
        "hu_HU.UTF-8"
        "el_GR.UTF-8"
        "he_IL.UTF-8"
        "th_TH.UTF-8"
        "id_ID.UTF-8"
        "uk_UA.UTF-8"
        "ro_RO.UTF-8"
    )

    local locale_selection=""
    locale_selection=$(printf '%s\n' "${locales[@]}" | gum filter --placeholder "Search locale..." --height 12) || true

    if [[ -n "$locale_selection" ]]; then
        CONFIG[locale]="$locale_selection"
        show_success "System locale: $locale_selection"
    fi

    echo ""

    show_info "Select your keyboard layout"
    echo ""

    local keyboards=(
        "us"
        "uk"
        "de"
        "fr"
        "es"
        "it"
        "pt-latin9"
        "br-abnt2"
        "ru"
        "pl"
        "cz"
        "hu"
        "se"
        "no"
        "dk"
        "fi"
        "nl"
        "be"
        "ch"
        "at"
        "jp106"
        "kr"
        "ara"
        "tr"
        "gr"
        "il"
        "latam"
        "dvorak"
        "colemak"
    )

    local kb_selection=""
    kb_selection=$(printf '%s\n' "${keyboards[@]}" | gum filter --placeholder "Search keyboard layout..." --height 12) || true

    if [[ -n "$kb_selection" ]]; then
        CONFIG[keyboard]="$kb_selection"
        loadkeys "$kb_selection" 2>/dev/null || true
        show_success "Keyboard layout: $kb_selection"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 3. DISK CONFIGURATION
# ────────────────────────────────────────────────────────────────────────────────

# ────────────────────────────────────────────────────────────────────────────────
# 3a. PARTITIONING MODE SELECTION
# ────────────────────────────────────────────────────────────────────────────────

select_partitioning_mode() {
    show_header
    show_submenu_header "💾 Disk Configuration"
    echo ""

    local mode_options=(
        "Auto    │ Wipe entire disk and partition automatically (Recommended)"
        "Manual  │ Choose existing partitions (dual-boot, custom layouts)"
    )

    local mode_sel=""
    mode_sel=$(printf '%s\n' "${mode_options[@]}" | gum choose --height 4 \
        --header "Select partitioning mode:") || true

    if [[ "$mode_sel" == "Manual"* ]]; then
        CONFIG[partition_mode]="manual"
        manual_partitioning
    else
        CONFIG[partition_mode]="auto"
        select_disk
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# 3b. MANUAL PARTITIONING
# ────────────────────────────────────────────────────────────────────────────────

manual_partitioning() {
    show_header
    show_submenu_header "💾 Manual Partitioning"
    echo ""

    gum style --foreground 226 --bold --margin "0 2" \
        "ℹ️  Your partitions will not be wiped — only the ones you assign will be formatted."
    echo ""

    # Show current layout
    gum style --foreground 245 --margin "0 2" \
        "$(lsblk -o NAME,SIZE,FSTYPE,LABEL,TYPE,MOUNTPOINT 2>/dev/null)"
    echo ""

    # Optionally launch cfdisk so the user can create partitions first
    if confirm_action "Launch cfdisk to create or modify partitions first?"; then
        local disks=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && disks+=("$line")
        done < <(lsblk -dpno NAME,SIZE,MODEL 2>/dev/null \
            | { grep -E '^/dev/(sd|nvme|vd|mmcblk)' || true; } | sed 's/  */ /g')

        if [[ ${#disks[@]} -gt 0 ]]; then
            local disk_sel=""
            disk_sel=$(printf '%s\n' "${disks[@]}" | gum choose --height 10 \
                --header "Select disk to open in cfdisk:") || true
            if [[ -n "$disk_sel" ]]; then
                local target_disk
                target_disk=$(echo "$disk_sel" | awk '{print $1}')
                cfdisk "$target_disk" || true
                partprobe "$target_disk" || true
                udevadm settle
            fi
        fi

        # Refresh view after cfdisk
        show_header
        show_submenu_header "💾 Manual Partitioning"
        echo ""
        gum style --foreground 245 --margin "0 2" "Updated disk layout:"
        echo ""
        gum style --foreground 245 --margin "0 2" \
            "$(lsblk -o NAME,SIZE,FSTYPE,LABEL,TYPE,MOUNTPOINT 2>/dev/null)"
        echo ""
    fi

    # Build list of all available partitions
    local partitions=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && partitions+=("$line")
    done < <(lsblk -lpno NAME,SIZE,FSTYPE,LABEL 2>/dev/null \
        | { grep -E '^/dev/(sd|nvme|vd|mmcblk)[^ ]*[0-9]' || true; } \
        | sed 's/  */ /g')

    if [[ ${#partitions[@]} -eq 0 ]]; then
        show_error "No partitions found. Create partitions first and try again."
        gum input --placeholder "Press Enter to continue..."
        return
    fi

    # ── Boot / EFI partition ──────────────────────────────────────────────────
    echo ""
    if [[ "${CONFIG[uefi]}" == "yes" ]]; then
        show_info "Select EFI System Partition (ESP)"
    else
        show_info "Select boot partition  (or skip to keep /boot on the root partition)"
    fi
    echo ""

    local boot_options=("-- Skip (no separate boot partition) --")
    for p in "${partitions[@]}"; do boot_options+=("$p"); done

    local boot_sel=""
    boot_sel=$(printf '%s\n' "${boot_options[@]}" | gum choose --height 14 \
        --header "Boot / EFI partition:") || true

    if [[ "$boot_sel" == "-- Skip"* ]]; then
        CONFIG[boot_part]=""
        CONFIG[reuse_efi]="no"
        show_info "No separate boot partition — /boot will live on the root partition"
    else
        CONFIG[boot_part]=$(echo "$boot_sel" | awk '{print $1}')
        show_success "Boot/EFI partition: ${CONFIG[boot_part]}"

        if [[ "${CONFIG[uefi]}" == "yes" ]]; then
            echo ""
            gum style --foreground 226 --bold --margin "0 2" \
                "Dual-boot tip: If this ESP already contains Windows boot files, choose 'Reuse'." \
                "Choosing 'Format' will wipe the ESP and break the Windows boot entry."
            echo ""

            local efi_action=""
            efi_action=$(printf '%s\n' \
                "Format  │ Wipe and format as FAT32  (single-OS or new ESP)" \
                "Reuse   │ Mount without formatting   (Windows dual-boot)" \
                | gum choose --height 4 --header "What to do with this EFI partition:") || true

            if [[ "$efi_action" == "Reuse"* ]]; then
                CONFIG[reuse_efi]="yes"
                show_success "EFI partition will be reused — dual-boot safe"
            else
                CONFIG[reuse_efi]="no"
                show_success "EFI partition will be formatted as FAT32"
            fi
        fi
    fi

    # ── Root partition ────────────────────────────────────────────────────────
    echo ""
    show_info "Select root partition"
    echo ""

    local root_sel=""
    root_sel=$(printf '%s\n' "${partitions[@]}" | gum choose --height 14 \
        --header "Root ( / ) partition:") || true

    if [[ -z "$root_sel" ]]; then
        show_error "No root partition selected."
        gum input --placeholder "Press Enter to continue..."
        return
    fi

    CONFIG[root_part]=$(echo "$root_sel" | awk '{print $1}')
    show_success "Root partition: ${CONFIG[root_part]}"

    # Derive parent disk for GRUB install
    local parent_disk
    parent_disk=$(lsblk -no PKNAME "${CONFIG[root_part]}" 2>/dev/null | head -1)
    if [[ -n "$parent_disk" ]]; then
        CONFIG[disk]="/dev/$parent_disk"
    else
        CONFIG[disk]="${CONFIG[root_part]}"
    fi

    # ── Filesystem ───────────────────────────────────────────────────────────
    echo ""
    show_info "Select filesystem for root partition"
    echo ""

    local filesystems=(
        "btrfs    │ Modern CoW filesystem with snapshots (Recommended)"
        "ext4     │ Traditional reliable filesystem"
        "xfs      │ High-performance filesystem"
    )

    local fs_selection=""
    fs_selection=$(printf '%s\n' "${filesystems[@]}" | gum choose --height 5 \
        --header "Filesystem:") || true

    if [[ -z "$fs_selection" ]]; then
        show_error "No filesystem selected."
        gum input --placeholder "Press Enter to continue..."
        return
    fi

    CONFIG[filesystem]=$(echo "$fs_selection" | awk '{print $1}')
    show_success "Filesystem: ${CONFIG[filesystem]}"

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 3c. AUTO DISK SELECTION (original select_disk)
# ────────────────────────────────────────────────────────────────────────────────

select_disk() {
    show_header
    show_submenu_header "💾 Disk Configuration"
    echo ""

    gum style --foreground 196 --bold --margin "0 2" \
        "⚠️  WARNING: The selected disk will be COMPLETELY ERASED!"
    echo ""

    show_info "Select the target disk for installation"
    echo ""

    local disks=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && disks+=("$line")
    done < <(lsblk -dpno NAME,SIZE,MODEL 2>/dev/null | { grep -E '^/dev/(sd|nvme|vd|mmcblk)' || true; } | sed 's/  */ /g')

    if [[ ${#disks[@]} -eq 0 ]]; then
        show_error "No suitable disks found!"
        gum input --placeholder "Press Enter to exit..."
        exit 1
    fi

    local disk_selection=""
    disk_selection=$(printf '%s\n' "${disks[@]}" | gum choose --height 10 --header "Available disks:") || true

    if [[ -n "$disk_selection" ]]; then
        CONFIG[disk]=$(echo "$disk_selection" | awk '{print $1}')
        show_success "Selected disk: ${CONFIG[disk]}"

        echo ""
        gum style --foreground 245 --margin "0 2" \
            "$(lsblk "${CONFIG[disk]}" 2>/dev/null)"
    fi

    echo ""

    show_info "Select filesystem type"
    echo ""

    local filesystems=(
        "btrfs    │ Modern CoW filesystem with snapshots (Recommended)"
        "ext4     │ Traditional reliable filesystem"
        "xfs      │ High-performance filesystem"
    )

    local fs_selection=""
    fs_selection=$(printf '%s\n' "${filesystems[@]}" | gum choose --height 5 --header "Filesystem:") || true

    if [[ -n "$fs_selection" ]]; then
        CONFIG[filesystem]=$(echo "$fs_selection" | awk '{print $1}')
        show_success "Filesystem: ${CONFIG[filesystem]}"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 4. SWAP CONFIGURATION
# ────────────────────────────────────────────────────────────────────────────────

configure_swap() {
    show_header
    show_submenu_header "🔄 Swap Configuration"
    echo ""

    show_info "Select swap type for your system"
    echo ""

    local swap_options=(
        "zram     │ Compressed RAM swap (Recommended, fast)"
        "file     │ Traditional swap file on disk"
        "none     │ No swap (not recommended)"
    )

    local swap_selection=""
    swap_selection=$(printf '%s\n' "${swap_options[@]}" | gum choose --height 5 --header "Swap type:") || true

    if [[ -n "$swap_selection" ]]; then
        CONFIG[swap]=$(echo "$swap_selection" | awk '{print $1}')
        show_success "Swap type: ${CONFIG[swap]}"

        if [[ "${CONFIG[swap]}" == "zram" ]]; then
            echo ""
            show_info "Select zram compression algorithm"
            echo ""

            local algos=(
                "zstd     │ Best compression ratio (Recommended)"
                "lz4      │ Fastest compression"
                "lzo      │ Balanced speed/ratio"
            )

            local algo_selection=""
            algo_selection=$(printf '%s\n' "${algos[@]}" | gum choose --height 5 --header "Algorithm:") || true

            if [[ -n "$algo_selection" ]]; then
                CONFIG[swap_algo]=$(echo "$algo_selection" | awk '{print $1}')
                show_success "Compression: ${CONFIG[swap_algo]}"
            fi
        fi
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 5. HOSTNAME
# ────────────────────────────────────────────────────────────────────────────────

configure_hostname() {
    show_header
    show_submenu_header "💻 Hostname"
    echo ""

    show_info "Enter a hostname for your system"
    show_info "(lowercase letters, numbers, and hyphens only)"
    echo ""

    local hostname=""
    hostname=$(gum input --placeholder "xerolinux" --value "${CONFIG[hostname]}" --width 40 --header "Hostname:") || true

    if [[ "$hostname" =~ ^[a-z][a-z0-9-]*$ && ${#hostname} -le 63 ]]; then
        CONFIG[hostname]="$hostname"
        show_success "Hostname: ${CONFIG[hostname]}"
    else
        show_warning "Invalid hostname, using default: xerolinux"
        CONFIG[hostname]="xerolinux"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 6. AUTHENTICATION (Users & Root)
# ────────────────────────────────────────────────────────────────────────────────

configure_authentication() {
    show_header
    show_submenu_header "👤 User Account Setup"
    echo ""

    show_info "Create your user account"
    echo ""

    local username=""
    username=$(gum input --placeholder "username" --width 40 --header "Username (lowercase):") || true

    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ || ${#username} -gt 32 || -z "$username" ]]; then
        show_warning "Invalid username. Using 'user'"
        username="user"
    fi
    CONFIG[username]="$username"
    show_success "Username: ${CONFIG[username]}"

    echo ""

    local user_pass1="" user_pass2=""
    user_pass1=$(gum input --password --placeholder "Password for $username" --width 50) || true
    user_pass2=$(gum input --password --placeholder "Confirm password" --width 50) || true

    if [[ "$user_pass1" == "$user_pass2" && ${#user_pass1} -ge 1 ]]; then
        CONFIG[user_password]="$user_pass1"
        show_success "User password set"
    else
        show_error "Passwords don't match. Please reconfigure."
        sleep 1
        configure_authentication
        return
    fi

    echo ""
    show_submenu_header "🔐 Root Password"
    echo ""

    if confirm_action "Use same password for root?"; then
        CONFIG[root_password]="${CONFIG[user_password]}"
        show_success "Root password set (same as user)"
    else
        local root_pass1="" root_pass2=""
        root_pass1=$(gum input --password --placeholder "Root password" --width 50) || true
        root_pass2=$(gum input --password --placeholder "Confirm root password" --width 50) || true

        if [[ "$root_pass1" == "$root_pass2" && -n "$root_pass1" ]]; then
            CONFIG[root_password]="$root_pass1"
            show_success "Root password set"
        else
            show_warning "Passwords don't match. Using user password for root."
            CONFIG[root_password]="${CONFIG[user_password]}"
        fi
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 8. TIMEZONE
# ────────────────────────────────────────────────────────────────────────────────

select_timezone() {
    show_header
    show_submenu_header "🕐 Timezone"
    echo ""

    show_info "Select your timezone"
    echo ""

    local regions=""
    regions=$(find /usr/share/zoneinfo -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | \
              grep -vE '^(\+|posix|right|zoneinfo)$' | sort) || true

    local region=""
    region=$(echo "$regions" | gum filter --placeholder "Search region..." --height 12 --header "Select region:") || true

    if [[ -n "$region" ]]; then
        local cities=""
        cities=$(find "/usr/share/zoneinfo/$region" -type f -printf '%f\n' 2>/dev/null | sort) || true

        if [[ -n "$cities" ]]; then
            echo ""
            local city=""
            city=$(echo "$cities" | gum filter --placeholder "Search city..." --height 12 --header "Select city:") || true

            if [[ -n "$city" ]]; then
                CONFIG[timezone]="$region/$city"
            else
                CONFIG[timezone]="$region"
            fi
        else
            CONFIG[timezone]="$region"
        fi

        show_success "Timezone: ${CONFIG[timezone]}"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 9. PARALLEL DOWNLOADS
# ────────────────────────────────────────────────────────────────────────────────

configure_parallel_downloads() {
    show_header
    show_submenu_header "⚡ Parallel Downloads"
    echo ""

    show_info "Set number of parallel package downloads (speeds up installation)"
    echo ""

    local options=(
        "3      │ Conservative (slow connections)"
        "5      │ Default (recommended)"
        "10     │ Fast (good connections)"
        "15     │ Maximum (excellent connections)"
    )

    local selection=""
    selection=$(printf '%s\n' "${options[@]}" | gum choose --height 6 --header "Parallel downloads:") || true

    if [[ -n "$selection" ]]; then
        CONFIG[parallel_downloads]=$(echo "$selection" | awk '{print $1}')
        show_success "Parallel downloads: ${CONFIG[parallel_downloads]}"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 10. ADDITIONAL KERNEL
# ────────────────────────────────────────────────────────────────────────────────

select_extra_kernel() {
    show_header
    show_submenu_header "🐧 Additional Kernel"
    echo ""

    gum style --foreground 220 --bold --border normal --border-foreground 220 \
        --align left --margin "0 2" --padding "0 1" \
        "These kernels install ALONGSIDE the default linux kernel." \
        "Do NOT select too many — each takes ~100 MB on the boot partition."
    echo ""

    local options=(
        "None"
        "linux-cachyos   │ CachyOS optimized kernel  (Chaotic-AUR)"
        "linux-lts       │ Long Term Support kernel   (official repos)"
    )

    local selections=""
    selections=$(printf '%s\n' "${options[@]}" | gum choose --no-limit \
        --header "Additional kernels (Space to toggle, Enter to confirm):") || true

    CONFIG[extra_kernel]=""
    if [[ -z "$selections" ]] || echo "$selections" | grep -q "^None$"; then
        show_success "No additional kernel selected"
        sleep 0.5
        return
    fi

    while IFS= read -r line; do
        case "$line" in
            "linux-cachyos"*) CONFIG[extra_kernel]+="linux-cachyos linux-cachyos-headers " ;;
            "linux-lts"*)     CONFIG[extra_kernel]+="linux-lts linux-lts-headers " ;;
        esac
    done <<< "$selections"

    CONFIG[extra_kernel]="${CONFIG[extra_kernel]% }"
    show_success "Extra kernels queued: ${CONFIG[extra_kernel]}"
    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# PACMAN HELPERS
# ────────────────────────────────────────────────────────────────────────────────

apply_parallel_downloads() {
    local conf="$1"
    local count="${CONFIG[parallel_downloads]}"
    if grep -q '^#*ParallelDownloads' "$conf"; then
        sed -i "s/^#*ParallelDownloads.*/ParallelDownloads = $count/" "$conf"
    else
        sed -i '/^\[options\]/a ParallelDownloads = '"$count" "$conf"
    fi
}

configure_pacman_options() {
    local conf="$1"
    local simple_opts=(Color ILoveCandy VerbosePkgLists DisableDownloadTimeout)

    for opt in "${simple_opts[@]}"; do
        if grep -q "^#\s*${opt}" "$conf"; then
            sed -i "s/^#\s*${opt}.*/${opt}/" "$conf"
        elif ! grep -q "^${opt}" "$conf"; then
            sed -i '/^\[options\]/a '"${opt}" "$conf"
        fi
    done

    if grep -q '^#*DownloadUser' "$conf"; then
        sed -i 's/^#*DownloadUser.*/DownloadUser = alpm/' "$conf"
    elif ! grep -q '^DownloadUser' "$conf"; then
        sed -i '/^\[options\]/a DownloadUser = alpm' "$conf"
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# MAIN MENU
# ────────────────────────────────────────────────────────────────────────────────

show_main_menu() {
    while true; do
        show_header

        local boot_mode="BIOS"
        [[ "${CONFIG[uefi]}" == "yes" ]] && boot_mode="UEFI"

        gum style --foreground 245 --margin "0 2" \
            "Boot Mode: $boot_mode"
        echo ""

        # Build disk info line for menu display
        local disk_info=""
        if [[ "${CONFIG[partition_mode]}" == "manual" ]]; then
            if [[ -n "${CONFIG[root_part]}" ]]; then
                disk_info="Manual: root=${CONFIG[root_part]}"
                [[ -n "${CONFIG[boot_part]}" ]] && disk_info+=" boot=${CONFIG[boot_part]}"
                disk_info+=" (${CONFIG[filesystem]})"
            else
                disk_info="Manual: Not configured"
            fi
        else
            disk_info="${CONFIG[disk]:-Not configured}"
            if [[ -n "${CONFIG[disk]}" ]]; then
                disk_info+=" (${CONFIG[filesystem]})"
            fi
        fi

        local kernel_label="None"
        if [[ "${CONFIG[extra_kernel]}" == *"linux-cachyos"* && "${CONFIG[extra_kernel]}" == *"linux-lts"* ]]; then
            kernel_label="CachyOS + LTS"
        elif [[ "${CONFIG[extra_kernel]}" == *"linux-cachyos"* ]]; then
            kernel_label="CachyOS"
        elif [[ "${CONFIG[extra_kernel]}" == *"linux-lts"* ]]; then
            kernel_label="LTS"
        fi

        local menu_items=(
            ""
            "1.  Installer Language    │ ${CONFIG[installer_lang]}"
            "2.  Locales               │ ${CONFIG[locale]} / ${CONFIG[keyboard]}"
            "3.  Disk Configuration    │ $disk_info"
            "4.  Swap                  │ ${CONFIG[swap]}"
            "5.  Hostname              │ ${CONFIG[hostname]}"
            "6.  Authentication        │ ${CONFIG[username]:-Not configured}"
            "7.  Timezone              │ ${CONFIG[timezone]}"
            "8.  Parallel Downloads    │ ${CONFIG[parallel_downloads]}"
            "9.  Additional Kernel     │ $kernel_label"
            "──────────────────────────────────────────────"
            "10. Start Installation"
            "0.  Exit"
        )

        local selection=""
        selection=$(printf '%s\n' "${menu_items[@]}" | gum choose --height 20 --header $'Configure your installation:\n') || true

        case "$selection" in
            "1."*)  select_installer_language ;;
            "2."*)  select_locales ;;
            "3."*)  select_partitioning_mode ;;
            "4."*)  configure_swap ;;
            "5."*)  configure_hostname ;;
            "6."*)  configure_authentication ;;
            "7."*)  select_timezone ;;
            "8."*)  configure_parallel_downloads ;;
            "9."*)  select_extra_kernel ;;
            "10."*)
                if validate_config; then
                    show_summary
                    local confirm_msg=""
                    if [[ "${CONFIG[partition_mode]}" == "manual" ]]; then
                        confirm_msg="Start installation? ${CONFIG[root_part]} will be formatted as root"
                    else
                        confirm_msg="Start installation? THIS WILL ERASE ${CONFIG[disk]}"
                    fi
                    if confirm_action "$confirm_msg"; then
                        perform_installation
                        break
                    fi
                fi
                ;;
            "0."*)
                if confirm_action "Exit installer?"; then
                    echo "Installation cancelled."
                    exit 0
                fi
                ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────────────────────
# VALIDATION
# ────────────────────────────────────────────────────────────────────────────────

validate_config() {
    local errors=()

    if [[ "${CONFIG[partition_mode]}" == "manual" ]]; then
        [[ -z "${CONFIG[root_part]}" ]] && errors+=("Root partition not configured (Manual mode)")
        [[ -n "${CONFIG[root_part]}" && ! -b "${CONFIG[root_part]}" ]] && \
            errors+=("Root partition '${CONFIG[root_part]}' is not a valid block device")
        [[ -n "${CONFIG[boot_part]}" && ! -b "${CONFIG[boot_part]}" ]] && \
            errors+=("Boot partition '${CONFIG[boot_part]}' is not a valid block device")
    else
        [[ -z "${CONFIG[disk]}" ]] && errors+=("Disk not configured")
    fi

    [[ -z "${CONFIG[username]}" ]] && errors+=("User account not configured")
    [[ -z "${CONFIG[user_password]}" ]] && errors+=("User password not set")
    [[ -z "${CONFIG[root_password]}" ]] && errors+=("Root password not set")

    if [[ ${#errors[@]} -gt 0 ]]; then
        show_header
        gum style --foreground 196 --bold --margin "1 2" \
            "❌ Configuration Incomplete"
        echo ""
        for error in "${errors[@]}"; do
            show_error "$error"
        done
        echo ""
        gum input --placeholder "Press Enter to continue..."
        return 1
    fi

    return 0
}

# ────────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ────────────────────────────────────────────────────────────────────────────────

show_summary() {
    show_header
    show_submenu_header "📋 Installation Summary"
    echo ""

    local boot_mode="BIOS/Legacy"
    [[ "${CONFIG[uefi]}" == "yes" ]] && boot_mode="UEFI"

    if [[ "${CONFIG[partition_mode]}" == "manual" ]]; then
        local efi_note=""
        [[ "${CONFIG[reuse_efi]}" == "yes" ]] && efi_note=" (reused, not formatted)"
        local boot_line="None (boot on root)"
        [[ -n "${CONFIG[boot_part]}" ]] && boot_line="${CONFIG[boot_part]}$efi_note"

        gum style --border rounded --border-foreground 212 --padding "1 2" --margin "0 2" \
            "Locale:           ${CONFIG[locale]}" \
            "Keyboard:         ${CONFIG[keyboard]}" \
            "Timezone:         ${CONFIG[timezone]}" \
            "Hostname:         ${CONFIG[hostname]}" \
            "" \
            "Username:         ${CONFIG[username]}" \
            "" \
            "Partition mode:   Manual" \
            "Root partition:   ${CONFIG[root_part]}" \
            "Boot partition:   $boot_line" \
            "Filesystem:       ${CONFIG[filesystem]}" \
            "Swap:             ${CONFIG[swap]}" \
            "" \
            "Profile:          HomeLab (headless, no DE/WM)" \
            "Boot Mode:        $boot_mode" \
            "Bootloader:       GRUB (on ${CONFIG[disk]})" \
            "Downloads:        ${CONFIG[parallel_downloads]} parallel"

        echo ""
        gum style --foreground 196 --bold --margin "0 2" \
            "⚠️  ${CONFIG[root_part]} will be FORMATTED as the root partition!"
        [[ "${CONFIG[reuse_efi]}" != "yes" && -n "${CONFIG[boot_part]}" ]] && \
            gum style --foreground 196 --bold --margin "0 2" \
                "⚠️  ${CONFIG[boot_part]} will be FORMATTED as the boot/EFI partition!"
    else
        gum style --border rounded --border-foreground 212 --padding "1 2" --margin "0 2" \
            "Locale:           ${CONFIG[locale]}" \
            "Keyboard:         ${CONFIG[keyboard]}" \
            "Timezone:         ${CONFIG[timezone]}" \
            "Hostname:         ${CONFIG[hostname]}" \
            "" \
            "Username:         ${CONFIG[username]}" \
            "" \
            "Partition mode:   Auto (whole disk)" \
            "Target Disk:      ${CONFIG[disk]}" \
            "Filesystem:       ${CONFIG[filesystem]}" \
            "Swap:             ${CONFIG[swap]}" \
            "" \
            "Profile:          HomeLab (headless, no DE/WM)" \
            "Boot Mode:        $boot_mode" \
            "Bootloader:       GRUB" \
            "Downloads:        ${CONFIG[parallel_downloads]} parallel"

        echo ""
        gum style --foreground 196 --bold --margin "0 2" \
            "⚠️  ALL DATA ON ${CONFIG[disk]} WILL BE PERMANENTLY ERASED!"
    fi
    echo ""
}

# ────────────────────────────────────────────────────────────────────────────────
# INSTALLATION
# ────────────────────────────────────────────────────────────────────────────────

perform_installation() {
    show_header
    gum style --foreground 212 --bold --margin "1 2" \
        "🚀 Starting Installation..."
    echo ""

    # IMPORTANT: run stateful functions in THIS shell (no gum spin subshell).
    run_step "Partitioning disk..." partition_disk
    run_step "Formatting partitions..." format_partitions
    run_step "Mounting filesystems..." mount_filesystems

    show_info "Installing base system (this may take a while)..."
    install_base_system
    show_success "Base system installed"

    show_info "Adding XeroLinux and Chaotic-AUR repositories..."
    add_repos
    show_success "Repositories configured"

    if [[ -n "${CONFIG[extra_kernel]}" ]]; then
        show_info "Installing additional kernels: ${CONFIG[extra_kernel]}..."
        # shellcheck disable=SC2086
        arch-chroot "$MOUNTPOINT" pacman -S --needed --noconfirm ${CONFIG[extra_kernel]} \
            || show_warning "Some extra kernel packages failed — continuing"
        arch-chroot "$MOUNTPOINT" grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
        show_success "Additional kernels installed"
    fi

    run_step "Configuring system..." configure_system
    run_step "Installing GRUB bootloader..." install_bootloader
    run_step "Configuring Btrfs snapshots..." setup_snapper
    run_step "Creating user account..." create_user
    run_step "Installing base graphics (mesa)..." install_graphics
    run_step "Configuring swap..." setup_swap_system

    show_info "Preparing HomeLab tooling installer..."
    prepare_tools_installer
    show_success "HomeLab tooling installer ready"

    echo ""
    gum style --foreground 82 --bold --border double --border-foreground 82 \
        --align center --width 66 --margin "1 2" --padding "1 2" \
        "🎉 Base Installation Complete! 🎉" \
        "" \
        "The system will now chroot into your new installation" \
        "to run the XeroHomeLab tooling setup script."

    echo ""
    gum input --placeholder "Press Enter to continue to HomeLab tooling installation..."

    run_tools_installer

    show_header
    gum style --foreground 82 --bold --border double --border-foreground 82 \
        --align center --width 60 --margin "1 2" --padding "1 2" \
        "✨ Installation Complete! ✨" \
        "" \
        "Your XeroHomeLab system is ready!" \
        "" \
        "Remove the installation media and reboot:" \
        "  sudo reboot"
    echo ""
}

# ────────────────────────────────────────────────────────────────────────────────
# DISK OPERATIONS
# ────────────────────────────────────────────────────────────────────────────────

partition_disk() {
    # Manual mode: user already selected partitions — nothing to partition
    [[ "${CONFIG[partition_mode]}" == "manual" ]] && return 0

    local disk="${CONFIG[disk]}"

    [[ -n "$disk" ]] || { echo "ERROR: CONFIG[disk] is empty"; exit 1; }

    wipefs -af "$disk" 2>/dev/null || true
    sgdisk -Z "$disk" &>/dev/null || true

    if [[ "${CONFIG[uefi]}" == "yes" ]]; then
        parted -s "$disk" mklabel gpt
        parted -s "$disk" mkpart ESP fat32 1MiB 2049MiB
        parted -s "$disk" set 1 esp on
        parted -s "$disk" mkpart primary 2049MiB 100%
    else
        parted -s "$disk" mklabel msdos
        parted -s "$disk" mkpart primary ext4 1MiB 2049MiB
        parted -s "$disk" set 1 boot on
        parted -s "$disk" mkpart primary 2049MiB 100%
    fi

    # Make sure kernel/udev creates partition nodes (common VM timing issue)
    partprobe "$disk" || true
    udevadm settle
    sleep 1

    if [[ "$disk" == *"nvme"* || "$disk" == *"mmcblk"* || "$disk" == *"loop"* ]]; then
        CONFIG[boot_part]="${disk}p1"
        CONFIG[root_part]="${disk}p2"
    else
        CONFIG[boot_part]="${disk}1"
        CONFIG[root_part]="${disk}2"
    fi

    # Validate partitions exist as block devices BEFORE formatting
    if [[ -n "${CONFIG[boot_part]}" && ! -b "${CONFIG[boot_part]}" ]]; then
        echo "ERROR: Boot partition not ready after partitioning."
        echo "  boot_part='${CONFIG[boot_part]}' block? no"
        lsblk -f "$disk" || true
        exit 1
    fi
    if [[ ! -b "${CONFIG[root_part]}" ]]; then
        echo "ERROR: Root partition not ready after partitioning."
        echo "  root_part='${CONFIG[root_part]}' block? no"
        lsblk -f "$disk" || true
        exit 1
    fi
}

format_partitions() {
    local root_device="${CONFIG[root_part]}"

    [[ -b "$root_device" ]] || { echo "ERROR: root device '$root_device' is not a block device"; exit 1; }

    # Format boot partition (skipped when reusing an existing EFI partition)
    if [[ -n "${CONFIG[boot_part]}" ]]; then
        [[ -b "${CONFIG[boot_part]}" ]] || { echo "ERROR: boot_part '${CONFIG[boot_part]}' is not a block device"; exit 1; }

        if [[ "${CONFIG[reuse_efi]}" == "yes" ]]; then
            echo "Reusing existing EFI partition ${CONFIG[boot_part]} — skipping format"
        elif [[ "${CONFIG[uefi]}" == "yes" ]]; then
            wipefs -af "${CONFIG[boot_part]}" &>/dev/null
            mkfs.fat -F32 "${CONFIG[boot_part]}"
        else
            wipefs -af "${CONFIG[boot_part]}" &>/dev/null
            mkfs.ext4 -F "${CONFIG[boot_part]}"
        fi
    fi

    wipefs -af "$root_device" &>/dev/null
    case "${CONFIG[filesystem]}" in
        btrfs) mkfs.btrfs -f "$root_device" ;;
        ext4)  mkfs.ext4 -F "$root_device" ;;
        xfs)   mkfs.xfs -f "$root_device" ;;
        *)     echo "ERROR: Unknown filesystem '${CONFIG[filesystem]}'"; exit 1 ;;
    esac
}

mount_filesystems() {
    local root_device="${CONFIG[root_part]}"

    [[ -b "$root_device" ]] || { echo "ERROR: root device '$root_device' is not a block device"; exit 1; }

    if [[ "${CONFIG[filesystem]}" == "btrfs" ]]; then
        mount "$root_device" "$MOUNTPOINT"
        btrfs subvolume create "$MOUNTPOINT/@"
        btrfs subvolume create "$MOUNTPOINT/@home"
        btrfs subvolume create "$MOUNTPOINT/@var"
        btrfs subvolume create "$MOUNTPOINT/@tmp"
        # @snapshots NOT created here — snapper creates /.snapshots as a nested
        # child subvolume of @ in setup_snapper(). A top-level sibling subvolume
        # breaks snapper's subvolume relationship check and prevents snapshot creation.
        umount "$MOUNTPOINT"

        mount -o noatime,compress=zstd,subvol=@ "$root_device" "$MOUNTPOINT"
        mkdir -p "$MOUNTPOINT"/{home,var,tmp,boot}
        mount -o noatime,compress=zstd,subvol=@home "$root_device" "$MOUNTPOINT/home"
        mount -o noatime,compress=zstd,subvol=@var "$root_device" "$MOUNTPOINT/var"
        mount -o noatime,compress=zstd,subvol=@tmp "$root_device" "$MOUNTPOINT/tmp"
    else
        mount "$root_device" "$MOUNTPOINT"
        mkdir -p "$MOUNTPOINT/boot"
    fi

    if [[ "${CONFIG[uefi]}" == "yes" ]]; then
        # UEFI: ESP mounted at /boot/efi
        mkdir -p "$MOUNTPOINT/boot/efi"
        mount "${CONFIG[boot_part]}" "$MOUNTPOINT/boot/efi"
    elif [[ -n "${CONFIG[boot_part]}" ]]; then
        # BIOS with separate boot partition
        mount "${CONFIG[boot_part]}" "$MOUNTPOINT/boot"
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# SYSTEM INSTALLATION
# ────────────────────────────────────────────────────────────────────────────────

# Import chaotic-aur key with fallback keyservers and retries
import_chaotic_key() {
    local keyid="3056513887B78AEB"
    local keyservers=(
        "keyserver.ubuntu.com"
        "keys.openpgp.org"
        "pgp.mit.edu"
    )
    local imported=0

    for ks in "${keyservers[@]}"; do
        if pacman-key --recv-key "$keyid" --keyserver "$ks" 2>/dev/null; then
            imported=1
            break
        fi
        show_warning "Keyserver $ks failed, trying next..."
    done

    if [[ $imported -eq 0 ]]; then
        show_warning "All keyservers failed — trying hkps fallback..."
        pacman-key --recv-key "$keyid" \
            --keyserver hkps://keyserver.ubuntu.com 2>/dev/null || true
    fi

    pacman-key --lsign-key "$keyid" || true
}

add_temp_repo() {
    sed -i '/^#\[multilib\]/{N;s/#\[multilib\]\n#Include/[multilib]\nInclude/}' /etc/pacman.conf

    if ! grep -q "\[xerolinux\]" /etc/pacman.conf; then
        echo -e '\n[xerolinux]\nSigLevel = Optional TrustAll\nServer = https://repos.xerolinux.xyz/$repo/$arch' >> /etc/pacman.conf
    fi

    if ! grep -q "\[chaotic-aur\]" /etc/pacman.conf; then
        import_chaotic_key
        pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
            || show_warning "chaotic-keyring install failed — repo may not work fully"
        pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' \
            || show_warning "chaotic-mirrorlist install failed"
        echo -e '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf
    fi

    apply_parallel_downloads /etc/pacman.conf
    configure_pacman_options /etc/pacman.conf
    pacman -Sy
}

install_base_system() {
    add_temp_repo

    # ── Critical base (pacstrap aborts if these fail) ─────────────────────────
    # Headless lab: NO display server, audio, gstreamer, printing or bluetooth.
    local critical="base base-devel linux linux-headers mkinitcpio-fw"

    # Microcode (auto-detect)
    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        critical+=" intel-ucode"
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        critical+=" amd-ucode"
    fi

    # Boot & filesystems
    critical+=" grub efibootmgr os-prober grub-hooks update-grub"
    critical+=" btrfs-progs dosfstools e2fsprogs xfsprogs gptfdisk"

    # Base utilities
    critical+=" sudo nano vim git wget curl"

    # Network stack (headless essentials only)
    critical+=" networkmanager openssh dhcpcd iw wpa_supplicant wireless-regdb"
    critical+=" avahi nss-mdns reflector net-tools traceroute"

    # Install critical packages — abort on failure
    # shellcheck disable=SC2086
    pacstrap -K "$MOUNTPOINT" $critical

    # Btrfs snapshot support — only when btrfs is selected
    if [[ "${CONFIG[filesystem]}" == "btrfs" ]]; then
        show_info "Installing Btrfs snapshot support..."
        # snap-pac omitted here — its pacman hooks would fire on every package install
        # during the chroot setup phase, creating unwanted snapshots before first login.
        # It gets installed by xero-snapper-init on first boot instead.
        pacstrap -K "$MOUNTPOINT" snapper grub-btrfs inotify-tools 2>/dev/null || \
            show_warning "Some Btrfs snapshot packages failed — continuing"
    fi

    genfstab -U "$MOUNTPOINT" >> "$MOUNTPOINT/etc/fstab"
}

add_repos() {
    sed -i '/^#\[multilib\]/{N;s/#\[multilib\]\n#Include/[multilib]\nInclude/}' "$MOUNTPOINT/etc/pacman.conf"

    if ! grep -q "\[xerolinux\]" "$MOUNTPOINT/etc/pacman.conf"; then
        echo -e '\n[xerolinux]\nSigLevel = Optional TrustAll\nServer = https://repos.xerolinux.xyz/$repo/$arch' >> "$MOUNTPOINT/etc/pacman.conf"
    fi

    if ! grep -q "\[chaotic-aur\]" "$MOUNTPOINT/etc/pacman.conf"; then
        local keyid="3056513887B78AEB"
        local keyservers=("keyserver.ubuntu.com" "keys.openpgp.org" "pgp.mit.edu")
        local imported=0

        for ks in "${keyservers[@]}"; do
            if arch-chroot "$MOUNTPOINT" pacman-key --recv-key "$keyid" --keyserver "$ks" 2>/dev/null; then
                imported=1
                break
            fi
            show_warning "Keyserver $ks failed, trying next..."
        done

        [[ $imported -eq 0 ]] && \
            arch-chroot "$MOUNTPOINT" pacman-key --recv-key "$keyid" \
                --keyserver hkps://keyserver.ubuntu.com 2>/dev/null || true

        arch-chroot "$MOUNTPOINT" pacman-key --lsign-key "$keyid" || true

        arch-chroot "$MOUNTPOINT" pacman -U --noconfirm \
            'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
            || show_warning "chaotic-keyring install failed — repo may not work fully"

        arch-chroot "$MOUNTPOINT" pacman -U --noconfirm \
            'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' \
            || show_warning "chaotic-mirrorlist install failed"

        echo -e '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' >> "$MOUNTPOINT/etc/pacman.conf"
    fi

    apply_parallel_downloads "$MOUNTPOINT/etc/pacman.conf"
    configure_pacman_options "$MOUNTPOINT/etc/pacman.conf"
    arch-chroot "$MOUNTPOINT" pacman -Sy
}

configure_system() {
    arch-chroot "$MOUNTPOINT" ln -sf "/usr/share/zoneinfo/${CONFIG[timezone]}" /etc/localtime
    arch-chroot "$MOUNTPOINT" hwclock --systohc

    echo "${CONFIG[locale]} UTF-8" >> "$MOUNTPOINT/etc/locale.gen"
    echo "en_US.UTF-8 UTF-8" >> "$MOUNTPOINT/etc/locale.gen"
    arch-chroot "$MOUNTPOINT" locale-gen
    echo "LANG=${CONFIG[locale]}" > "$MOUNTPOINT/etc/locale.conf"

    # Headless: console keymap via /etc/vconsole.conf only — no X11/Wayland
    # keyboard config (no display server installed).
    echo "KEYMAP=${CONFIG[keyboard]}" > "$MOUNTPOINT/etc/vconsole.conf"

    echo "${CONFIG[hostname]}" > "$MOUNTPOINT/etc/hostname"
    cat > "$MOUNTPOINT/etc/hosts" << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${CONFIG[hostname]}.localdomain ${CONFIG[hostname]}
EOF

    arch-chroot "$MOUNTPOINT" systemctl enable NetworkManager

    # Force NetworkManager to use wpa_supplicant for WiFi (not iwd)
    mkdir -p "$MOUNTPOINT/etc/NetworkManager/conf.d"
    cat > "$MOUNTPOINT/etc/NetworkManager/conf.d/wifi-backend.conf" << EOF
[device]
wifi.backend=wpa_supplicant
EOF
}

install_bootloader() {
    if [[ "${CONFIG[uefi]}" == "yes" ]]; then
        local efi_dir="/boot/efi"
        mkdir -p "$MOUNTPOINT$efi_dir"

        if ! mountpoint -q "$MOUNTPOINT$efi_dir"; then
            mount "${CONFIG[boot_part]}" "$MOUNTPOINT$efi_dir"
        fi

        arch-chroot "$MOUNTPOINT" grub-install \
            --target=x86_64-efi \
            --efi-directory="$efi_dir" \
            --bootloader-id=XeroLinux \
            --recheck
    else
        # BIOS install
        arch-chroot "$MOUNTPOINT" grub-install --target=i386-pc "${CONFIG[disk]}"
    fi

    # Set default kernel parameters
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 nvme_load=yes"/' \
        "$MOUNTPOINT/etc/default/grub"

    # Set distributor and enable os-prober
    sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="XeroLinux"/' "$MOUNTPOINT/etc/default/grub"
    sed -i 's/^#*GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$MOUNTPOINT/etc/default/grub"

    arch-chroot "$MOUNTPOINT" grub-mkconfig -o /boot/grub/grub.cfg
}

setup_snapper() {
    [[ "${CONFIG[filesystem]}" != "btrfs" ]] && return 0

    show_info "Configuring Snapper for Btrfs..."

    # snapper create-config requires dbus/PolicyKit — not available in a bare chroot.
    # Write the config file and create the subvolume directly instead; functionally
    # identical to what snapper create-config produces.

    # 1. Write snapper config file directly into the mounted system
    mkdir -p "$MOUNTPOINT/etc/snapper/configs"
    cat > "$MOUNTPOINT/etc/snapper/configs/root" << 'SNAPCFG'
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="50"
NUMBER_LIMIT_IMPORTANT="10"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_QUARTERLY="0"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
SNAPCFG

    # 2. Register config name with snapper's conf.d so it knows it exists
    mkdir -p "$MOUNTPOINT/etc/conf.d"
    if [[ -f "$MOUNTPOINT/etc/conf.d/snapper" ]]; then
        sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root"/' "$MOUNTPOINT/etc/conf.d/snapper"
    else
        echo 'SNAPPER_CONFIGS="root"' > "$MOUNTPOINT/etc/conf.d/snapper"
    fi

    # 3. Create /.snapshots as a btrfs subvolume nested inside @ from the host side —
    #    no dbus needed, no chroot needed, just a direct btrfs command on the mountpoint.
    if ! btrfs subvolume create "$MOUNTPOINT/.snapshots" 2>/dev/null; then
        show_warning "Could not create /.snapshots subvolume — snapshot support may not work"
        return 0
    fi
    chmod 750 "$MOUNTPOINT/.snapshots"

    # 4. Add /.snapshots to fstab so rollbacks don't swallow the snapshots dir.
    #    The subvolume path inside the btrfs pool is @/.snapshots.
    local root_uuid=""
    root_uuid=$(blkid -s UUID -o value "${CONFIG[root_part]}" 2>/dev/null)
    if [[ -n "$root_uuid" ]]; then
        echo "UUID=$root_uuid  /.snapshots  btrfs  noatime,compress=zstd,subvol=@/.snapshots  0  0" \
            >> "$MOUNTPOINT/etc/fstab"
    fi

    # 5. Defer snapper timers + grub-btrfsd to first boot via a oneshot service.
    #    Enabling them here (in a bare chroot) causes them to fire before the user's
    #    filesystem is fully settled and before btrfs-assistant is available.
    mkdir -p "$MOUNTPOINT/usr/local/bin"
    cat > "$MOUNTPOINT/usr/local/bin/xero-snapper-init" << 'SNAPINIT'
#!/bin/bash
# Install snap-pac now — its pacman hooks will fire on the NEXT package operation,
# which is the first real user-initiated install, not during system setup.
pacman -S --needed --noconfirm snap-pac
systemctl enable --now snapper-timeline.timer
systemctl enable --now snapper-cleanup.timer
systemctl enable --now grub-btrfsd
touch /var/lib/xero-snapper-initialized
systemctl disable xero-snapper-init.service
SNAPINIT
    chmod +x "$MOUNTPOINT/usr/local/bin/xero-snapper-init"

    cat > "$MOUNTPOINT/etc/systemd/system/xero-snapper-init.service" << 'SVCEOF'
[Unit]
Description=Initialize Snapper timers on first boot (XeroLinux)
ConditionPathExists=!/var/lib/xero-snapper-initialized
After=sysinit.target local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/xero-snapper-init

[Install]
WantedBy=multi-user.target
SVCEOF

    arch-chroot "$MOUNTPOINT" systemctl enable xero-snapper-init.service 2>/dev/null || true

    show_success "Snapper configured — timers activate on first boot."
}

create_user() {
    echo "root:${CONFIG[root_password]}" | arch-chroot "$MOUNTPOINT" chpasswd

    local groups_to_create="sys network scanner power cups realtime sambashare rfkill lp users video storage kvm optical audio wheel adm falcond"
    for grp in $groups_to_create; do
        arch-chroot "$MOUNTPOINT" groupadd -f "$grp" 2>/dev/null || true
    done

    arch-chroot "$MOUNTPOINT" useradd -m -G sys,network,scanner,power,cups,realtime,sambashare,rfkill,lp,users,video,storage,kvm,optical,audio,wheel,adm,falcond -s /bin/bash "${CONFIG[username]}"
    echo "${CONFIG[username]}:${CONFIG[user_password]}" | arch-chroot "$MOUNTPOINT" chpasswd

    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' "$MOUNTPOINT/etc/sudoers"
}

install_graphics() {
    # Headless lab: no display server. Install only mesa (kernel DRM / VAAPI /
    # GL userspace — enough for the console and for container GPU acceleration),
    # plus VM guest agents when running virtualized.
    local packages="mesa mesa-utils"

    local vm_type=""
    vm_type=$(systemd-detect-virt 2>/dev/null || echo "none")
    case "$vm_type" in
        "qemu"|"kvm") packages+=" qemu-guest-agent" ;;
        "vmware")     packages+=" open-vm-tools" ;;
        "oracle")     packages+=" virtualbox-guest-utils" ;;
    esac

    # shellcheck disable=SC2086
    arch-chroot "$MOUNTPOINT" pacman -S --noconfirm --needed $packages \
        || show_warning "Some base graphics packages failed — continuing"
}

setup_swap_system() {
    case "${CONFIG[swap]}" in
        "zram")
            arch-chroot "$MOUNTPOINT" pacman -S --noconfirm zram-generator
            cat > "$MOUNTPOINT/etc/systemd/zram-generator.conf" << EOF
[zram0]
zram-size = ram / 2
compression-algorithm = ${CONFIG[swap_algo]}
EOF
            ;;
        "file")
            if [[ "${CONFIG[filesystem]}" == "btrfs" ]]; then
                arch-chroot "$MOUNTPOINT" truncate -s 0 /swapfile
                arch-chroot "$MOUNTPOINT" chattr +C /swapfile
                arch-chroot "$MOUNTPOINT" fallocate -l 4G /swapfile
            else
                arch-chroot "$MOUNTPOINT" dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
            fi
            arch-chroot "$MOUNTPOINT" chmod 600 /swapfile
            arch-chroot "$MOUNTPOINT" mkswap /swapfile
            echo "/swapfile none swap defaults 0 0" >> "$MOUNTPOINT/etc/fstab"
            ;;
        "none")
            ;;
    esac
}

# ────────────────────────────────────────────────────────────────────────────────
# HOMELAB TOOLING INSTALLER
# ────────────────────────────────────────────────────────────────────────────────

prepare_tools_installer() {
    local user="${CONFIG[username]}"
    local user_home="$MOUNTPOINT/home/${user}"

    if [[ -f "/root/xerohomelab-tools.sh" ]]; then
        cp /root/xerohomelab-tools.sh "${user_home}/xerohomelab-tools.sh"
    else
        curl -fsSL "$XERO_TOOLS_URL" -o "${user_home}/xerohomelab-tools.sh" || {
            cat > "${user_home}/xerohomelab-tools.sh" << 'TOOLSSCRIPT'
#!/bin/bash
echo "XeroHomeLab tooling installer placeholder"
echo "Please download the actual script from: https://github.com/xerolinux/xero-scripts"
TOOLSSCRIPT
        }
    fi
    chmod +x "${user_home}/xerohomelab-tools.sh"
    arch-chroot "$MOUNTPOINT" chown "${user}:${user}" "/home/${user}/xerohomelab-tools.sh"
}

run_tools_installer() {
    local user="${CONFIG[username]}"
    local user_home="/home/${user}"
    local script_path="${user_home}/xerohomelab-tools.sh"

    show_header
    gum style --foreground 212 --bold --margin "1 2" \
        "🧰 Running XeroHomeLab Tooling Setup (as ${user})..."
    echo ""

    if [[ ! -f "${MOUNTPOINT}${script_path}" ]]; then
        show_error "HomeLab tooling script not found at ${script_path}"
        return 1
    fi

    if ! arch-chroot "$MOUNTPOINT" id "$user" &>/dev/null; then
        show_error "User '${user}' does not exist in target system yet."
        return 1
    fi

    arch-chroot "$MOUNTPOINT" chown -R "${user}:${user}" "${user_home}"

    echo "${user} ALL=(ALL:ALL) NOPASSWD: ALL" > "$MOUNTPOINT/etc/sudoers.d/99-xero-installer"
    chmod 0440 "$MOUNTPOINT/etc/sudoers.d/99-xero-installer"

    arch-chroot "$MOUNTPOINT" su -l "$user" -c "bash '${script_path}' '${CONFIG[filesystem]}'"

    rm -f "$MOUNTPOINT/etc/sudoers.d/99-xero-installer"
}

# ────────────────────────────────────────────────────────────────────────────────
# MAIN ENTRY POINT
# ────────────────────────────────────────────────────────────────────────────────

main() {
    check_root
    check_uefi
    # Skip internet/deps check if launched from install.sh (deps already installed)
    if ! command -v gum &>/dev/null; then
        check_internet
        ensure_dependencies
    fi
    show_main_menu
}

# Only auto-run when executed directly; allows sourcing for tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
