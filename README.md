# ✨ XeroHomeLab Installer v0.1

A headless Arch Linux installer for HomeLab / server boxes. Installs a clean Arch
base and a **curated HomeLab toolset** — **no desktop environment, no window
manager, no display server**. Forked from the XeroLinux Arch Installer with all
DE/WM logic stripped out.

## Architecture

Three stages, same flow as the upstream Xero Arch Installer:

| Stage | File | Context | Role |
|-------|------|---------|------|
| 1. Bootstrap | `install.sh` | live ISO, root | preflight, deps, fetch + launch stage 2 |
| 2. Base install | `xerohomelab-install.sh` | live ISO, root | gum TUI: disk/snapper/GRUB/user — **no DE choice, no AUR helper, no encryption** |
| 3. Tooling | `xerohomelab-tools.sh` | target chroot, user | docker stack + Portainer + netdata + host tools |

Stage 2 chroots into the new system and runs stage 3 as the created user with
temporary passwordless sudo, passing `<filesystem>` as `$1`.

**No AUR helper (paru/yay).** Stage 2 enables the **xerolinux** and **chaotic-aur**
binary repos, so plain `pacman` installs every tool — including ones that would
otherwise need the AUR (lazydocker, ctop, cloudflared, mergerfs, …).

## Quick Start

Boot the Arch live ISO and run:

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/DarkXero-dev/HomeLabTest/main/install.sh)
```

## What Gets Installed

### Base System (stage 2)

- Linux kernel + headers, optional extra kernels (CachyOS / LTS)
- GRUB bootloader
- BTRFS / EXT4 / XFS (no disk encryption — removed for headless lab use)
- Snapper + grub-btrfs (BTRFS), ZRAM or swapfile
- **mesa only** (console/VAAPI/container GPU accel) + auto VM guest agents — no
  display server, no GPU driver menu
- NetworkManager + openssh + dhcpcd + wifi essentials, **xerolinux + chaotic-aur** repos
- User account, locale, timezone, hostname

**Headless base** — the desktop package set inherited from the upstream installer
was stripped: no Xorg/Wayland, no PipeWire/ALSA/GStreamer, no CUPS/printing/scanning,
no Bluetooth, no legacy dialup/VPN clients, and no auto-installed "optional" GUI
packages (orca, onboard, xf86-input-*, etc.).

### HomeLab Tooling (stage 3)

- **Baseline** (always): vim, git, tmux, htop/btop, openssh (enabled), rsync, zsh,
  fastfetch + utils (jq, yq, fzf, ripgrep, fd, bat, eza, ncdu, tree, lsof, age, sops)
- **Docker core** (always): `docker` + `docker-compose` + `docker-buildx` +
  `containerd`. User added to `docker` group; `docker.service` enabled.
- **Portainer**: compose stack written to `~/homelab/portainer/`, auto-started on
  **first boot** via a oneshot systemd unit → `https://<host>:9443`. Deploy all
  other apps (Jellyfin, *arr, Vaultwarden, …) from its web UI.
- **netdata**: host metrics dashboard on `:19999`.
- **Host groups**: Docker TUI/CLI (lazydocker, ctop, dive) · Networking (tailscale,
  cloudflared, wireguard-tools) · Storage/NAS (smartmontools, nfs-utils, samba,
  mergerfs, hdparm) · Backup (restic, rclone, borg).

> Docker isn't running inside the chroot, so Portainer can't be brought up during
> install — the first-boot unit handles it once `docker.service` is live, then
> disables itself.

## Customization

Edit `xerohomelab-tools.sh`:

- Add a host-package group: write an `install_<name>()` calling
  `install_group "<Label>" pkg1 pkg2 …`, then call it from `main()`.
- Enable a daemon: `enable_if_installed <pkg> [<unit>]`.
- Ship more compose stacks: follow the `write_portainer_stack` /
  `install_portainer_firstboot` pattern (write to `~/homelab/<app>/`, first-boot
  unit brings it up). Or just deploy via the Portainer UI post-boot.

## Differences from the upstream Xero Arch Installer

- No `select_desktop_env`, no KDE/Hyprland scripts, no `CONFIG[desktop]`.
- No AUR helper: `select_aur_helper` / `CONFIG[aur_helper]` removed; chaotic-aur
  binary repo covers former-AUR packages via pacman.
- No disk encryption: all LUKS2 logic (`setup_encryption`, encrypt prompts,
  crypttab/cryptdevice, sd-encrypt hook, GRUB cryptodisk) removed. Partitioning
  collapsed to the plain 2-partition layout (boot + root) for UEFI and BIOS.
- No GPU driver menu / `select_graphics_driver` / `CONFIG[gfx_driver]`: graphics
  reduced to mesa + VM guest agents.
- Desktop base packages stripped (Xorg, audio, gstreamer, printing, bluetooth,
  legacy networking) + X11/Wayland keyboard config removed (console keymap only).
- Main menu trimmed: Desktop Environment, AUR Helper, and Graphics Driver items
  gone. Final menu: 1 Lang · 2 Locales · 3 Disk · 4 Swap · 5 Hostname ·
  6 Authentication · 7 Timezone · 8 Parallel Downloads · 9 Additional Kernel ·
  10 Start.
- DE chroot stage replaced by the HomeLab tooling stage.

## License

GPL-3.0 — see [LICENSE](LICENSE).
