# XeroHomeLab Installer

A headless Arch Linux installer for HomeLab and server boxes. Installs a clean
Arch base plus a curated set of HomeLab tools. No desktop, no window manager, no GUI.

## Quick Start

Boot the Arch live ISO and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DarkXero-dev/HomeLabTest/main/install.sh)
```

## What You Get

**Base system**

- Arch base, Linux kernel (optional CachyOS / LTS kernels)
- GRUB bootloader, BTRFS / EXT4 / XFS (no disk encryption)
- Snapper snapshots on BTRFS, ZRAM or swapfile
- NetworkManager, SSH, WiFi support
- xerolinux + chaotic-aur repos (no AUR helper needed)

**HomeLab tools**

- Docker, docker-compose, buildx (your user is added to the docker group)
- Portainer for managing all your containers, at `https://<host-ip>:9443`
- Beszel for monitoring, at `http://<host-ip>:8090` (free, lightweight)
- CLI tools: lazydocker, ctop, dive
- Networking: tailscale, cloudflared, wireguard
- Storage: smartmontools, nfs-utils, samba, mergerfs
- Backup: restic, rclone, borg

## First Boot

Portainer and Beszel start automatically on the first boot. The box is headless,
so log in on the TTY or over SSH and a banner shows the live IP and both URLs.

1. Open `https://<host-ip>:9443` and create your Portainer admin user.
2. Deploy any other apps (Jellyfin, *arr, Vaultwarden, etc.) from the Portainer UI.
3. Open `http://<host-ip>:8090` to set up Beszel monitoring.

## License

GPL-3.0, see [LICENSE](LICENSE).
