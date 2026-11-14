# 🎮💻 iSteamOS – SteamOS to Full PC Workstation & Handheld Toolkit

An automated, modular post-install toolkit that transforms **SteamOS 3.x** (on Steam Deck, ROG Ally, Legion Go, Mini PCs, or Ryzen Z1 / Z1 Extreme handhelds) into a complete **PC Workstation** and optimized handheld gaming system.

---

## ⚡ Quick Start (`curl` One-Liner)

Open **Konsole (Terminal)** in SteamOS **Desktop Mode** and run:

### Interactive Menu
```bash
curl -fsSL https://raw.githubusercontent.com/LamPPKK/iSteamOS/main/install_isteamos.sh | bash
```

### Direct CLI Execution via `curl`
Run any profile directly without cloning the repository manually:

```bash
# 1. Core Handheld Setup (Network/WARP Fix + Unikey + Decky Loader & TDP)
curl -fsSL https://raw.githubusercontent.com/LamPPKK/iSteamOS/main/install_isteamos.sh | bash -s -- --core

# 2. Interactive Application Selector (Choose from 44 Apps & Dev Tools)
curl -fsSL https://raw.githubusercontent.com/LamPPKK/iSteamOS/main/install_isteamos.sh | bash -s -- --tools

# 3. Install Specific Apps by Number (e.g. Edge, Zalo, WireGuard, Cloud Sync)
curl -fsSL https://raw.githubusercontent.com/LamPPKK/iSteamOS/main/install_isteamos.sh | bash -s -- --tools 2 15 37 43

# 4. PC Workstation & Kernel/ZRAM/Rootfs Optimizer
curl -fsSL https://raw.githubusercontent.com/LamPPKK/iSteamOS/main/install_isteamos.sh | bash -s -- --pc-mode --all

# 5. Cloud Storage Sync (Microsoft OneDrive & Google Drive)
curl -fsSL https://raw.githubusercontent.com/LamPPKK/iSteamOS/main/install_isteamos.sh | bash -s -- --cloud-sync --all

# 6. Run System Doctor Diagnostics Dashboard
curl -fsSL https://raw.githubusercontent.com/LamPPKK/iSteamOS/main/install_isteamos.sh | bash -s -- --doctor

# 7. Full SteamOS-to-PC Transformation (Core + PC Optimizer + Cloud + All 44 Apps)
curl -fsSL https://raw.githubusercontent.com/LamPPKK/iSteamOS/main/install_isteamos.sh | bash -s -- --all
```

---

## 📦 Local Clone Installation (Optional)

If you prefer cloning the repository locally:

```bash
git clone https://github.com/LamPPKK/iSteamOS.git
cd iSteamOS
chmod +x install_isteamos.sh scripts/*.sh
./install_isteamos.sh
```

### Local CLI Flags
| Flag | Description |
| :--- | :--- |
| `--core` | Install core handheld components only (Network/WARP + Fcitx5-Unikey + Decky). |
| `--steam-fix` | Configure `systemd-resolved` DoT and Cloudflare WARP WireGuard split-tunnel only. |
| `--unikey` | Install and autostart Fcitx5 + Unikey (Telex Unicode) only. |
| `--decky` | Install Decky Loader `v3.3.1`, SimpleDeckyTDP `v1.0.7`, and DeckyWARP `v1.6.1`. |
| `--tools [IDs...]` | Open the interactive `1..44` app selector or install specified app IDs / `--all`. |
| `--pc-mode [--all]` | Apply PC Workstation optimizations (TCP BBR, ZRAM, `inotify`, Podman, CUPS). |
| `--cloud-sync [--all]` | Install OneDrive & Google Drive sync tools and systemd auto-mount services. |
| `--doctor` | Run the System Doctor health check and live connectivity diagnostics. |
| `--all` | Run the full end-to-end transformation (`--core` + PC Mode + Cloud Sync + All Apps). |

---

## ✨ Key Features & Architecture

### 1. Core Handheld Setup (`[1] --core`)
When selecting **`1`** (`--core`), iSteamOS installs only the 3 lightweight core handheld components:

1. **Network Stability, DNS-over-TLS & Cloudflare WARP Split-Tunnel ([`scripts/fix_steam_vietnam.sh`](scripts/fix_steam_vietnam.sh)):**
   - Configures `systemd-resolved` **DNS-over-TLS** (`1.1.1.1#cloudflare-dns.com` & `8.8.8.8#dns.google`) and preserves the standard `/etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf` symlink (preventing `warp-svc` foreign-DNS reconnect loops).
   - Ignores router/ISP DHCP DNS leaks (`192.168.1.1`) on active NetworkManager Ethernet/Wi-Fi connections.
   - Enables **Cloudflare WARP** in `WireGuard` + `tunnel_only` mode to bypass ISP throttling/DPI for **Steam Store, Steam Community, and LinkedIn**.
   - **Smart Meta/Facebook Split-Tunneling:** Excludes Meta/Facebook/Messenger IPv4 & IPv6 CIDR ranges from the WARP tunnel so Messenger chats and Facebook traffic stay on direct low-latency native routing.
2. **Vietnamese Input for Wayland & X11 ([`scripts/setup_unikey.sh`](scripts/setup_unikey.sh)):**
   - Installs and preconfigures `fcitx5`, `fcitx5-unikey`, `fcitx5-gtk`, `fcitx5-qt`, and `fcitx5-configtool` (**Telex** input method, **Unicode** charset), enabled by default with KDE Plasma Wayland virtual keyboard integration.
3. **Decky Loader + SimpleDeckyTDP + DeckyWARP ([`scripts/install_decky_components.sh`](scripts/install_decky_components.sh)):**
   - SHA-256 verified, atomic rollback-safe installation of **Decky Loader `v3.3.1`**, **SimpleDeckyTDP `v1.0.7`** (for Ryzen Z1 / Z1 Extreme / handheld TDP control), and **DeckyWARP `v1.6.1`**.
   - Includes a safety override ([`patches/simple_decky_tdp/plugin_update.py`](patches/simple_decky_tdp/plugin_update.py)) disabling unverified root OTA self-updates.

---

### 2. PC Workstation & System Optimizer (`[6] --pc-mode`)
Module [`scripts/optimize_pc_mode.sh`](scripts/optimize_pc_mode.sh) resolves SteamOS limitations when used as a daily-driver desktop workstation:

- **Kernel, ZRAM & TCP BBR Networking (`/etc/sysctl.d/99-isteamos-pc.conf`):**
  - Enables **Google TCP BBR** congestion control + `fq` qdisc + `tcp_mtu_probing=1` for faster downloads, smooth 4K streaming, and stable VPN/WARP tunnels.
  - Tunes `vm.swappiness=100`, `vm.vfs_cache_pressure=50`, `vm.page-cluster=0`, and `vm.max_map_count=2147483642` for ZRAM memory compression and modern games/IDEs.
  - Raises `fs.inotify.max_user_watches=524288` so **VS Code, Google Antigravity, Android Studio, JetBrains IDEs, and OneDrive/Google Drive** never hit `ENOSPC` file-watcher limits.
- **SteamOS 5GB Root (`/`) Partition Protection:**
  - Enables `Color` and `ParallelDownloads = 10` in `/etc/pacman.conf`, vacuums `systemd` journal logs (`50M`), and clears stale package/build caches.
- **Rootless Containers (`Podman` + `Distrobox`) Stored on `/home`:**
  - Configures `/etc/subuid`, `/etc/subgid`, `~/.config/containers/storage.conf`, and `~/.distroboxrc` so Ubuntu/Fedora/Arch containers live inside `~/.local/share/containers/storage` on the large `/home` partition and survive SteamOS updates.
- **Boot Mode Switcher Helper (`isteamos-boot-mode`):**
  - `isteamos-boot-mode desktop` — Boot directly into **KDE Plasma Desktop Mode** like a standard PC.
  - `isteamos-boot-mode gaming` — Switch back to **Steam Handheld Gaming Mode**.
  - `isteamos-boot-mode status` — Inspect the active SDDM autologin session.
- **Office Printing (`CUPS`), LAN Discovery (`Avahi mDNS`) & Desktop Fixes:**
  - Enables `cups.service` (USB/Wi-Fi/AirPrint & PDF printing) and `avahi-daemon.service` (`.local` discovery).
  - Applies KWallet6 Flatpak keyring persistence and patches the Decky `Emuchievements` `Symbol` crash if installed.

---

### 3. Cloud Storage Sync — OneDrive & Google Drive (`[7] --cloud-sync`)
Module [`scripts/setup_cloud_sync.sh`](scripts/setup_cloud_sync.sh) integrates native cloud drives without consuming rootfs `/` space:

- **Microsoft OneDrive:**
  - **OneDriver (On-Demand Virtual Drive):** Mounts OneDrive via FUSE so files appear in Dolphin and download only when opened.
  - **OneDriveGUI (`~/Applications/OneDriveGUI.AppImage`) & `onedrive-abraunegg`:** Automatic 2-way offline sync stored on `/home`.
- **Google Drive & Rclone VFS Auto-Mount:**
  - **KIO-GDrive:** Browse Google Drive natively inside **KDE Dolphin** (`Network -> Google Drive`).
  - **Rclone + Rclone Browser Qt6 + `isteamos-cloud-mount` CLI & `rclone-mount@.service`:**
    - `isteamos-cloud-mount gdrive` — Authenticate and auto-mount Google Drive at `~/GoogleDrive` on boot.
    - `isteamos-cloud-mount onedrive` — Authenticate and auto-mount OneDrive at `~/OneDrive` on boot.
    - `isteamos-cloud-mount status` — Check configured remotes and active systemd user mounts.

---

### 4. Interactive Application & Developer Suite (`[5] --tools`)
Select **`5`** (`--tools`) to install apps selectively by number (e.g., `2, 15, 37, 43`) or press **`A`** to install all **44** packages:

- **Browsers (KWallet5/6 Keyring Sync):** `1)` Google Chrome, `2)` Microsoft Edge, `3)` Brave Browser.
- **Development & Productivity:** `4)` Google Antigravity (IDE & CLI), `5)` Visual Studio Code, `6)` Android Studio, `7)` GitHub Desktop, `8)` Postman, `9)` Insomnia, `10)` Wireshark, `11)` draw.io, `12)` FileZilla, `13)` LibreOffice Suite, `14)` Distrobox & Podman.
- **Communication & Remote Access:** `15)` Zalo for Linux (AppImage), `16)` LinuxViewer (UltraViewer compatible), `17)` Beeper Unified Messenger, `18)` Discord, `19)` Telegram Desktop, `20)` Viber, `21)` Signal Desktop, `22)` Slack, `23)` Zoom, `24)` OpenBubbles (iMessage), `25)` Proton Mail, `26)` Mozilla Thunderbird, `27)` KDE Connect.
- **Media, Audio & Streaming:** `28)` Spotify, `29)` VLC Media Player, `30)` mpv & GStreamer Codecs, `31)` OBS Studio, `32)` Parsec Game Streaming, `33)` NoiseTorch & Pavucontrol.
- **Networking, VPN & Cloud:** `34)` LocalSend, `35)` Nextcloud Desktop, `36)` Proton VPN, `37)` WireGuard VPN & Tools (`wireguard-tools`, `wgcf`, `vortix`, `wireproxy`), `38)` OpenVPN & NetworkManager Plugin, `43)` OneDrive & Google Drive Cloud Sync Suite.
- **Desktop Customization, CLI & System:** `39)` Wallpaper Engine KDE 6 Plugin, `40)` KDE Apps (Kate, Okular, Gwenview, Spectacle, Ark, Filelight, PartitionManager, Qrca, Dolphin, Konsole, KWalletManager), `41)` Homebrew (`fastfetch`, `gh`, `neofetch`), `42)` System & Dev CLI Suite (`base-devel`, `paru`, `btop`, `htop`, `ripgrep`, `fd`, `tmux`, `vim`, `fish`, `zsh`, `jq`, `7zip`, `mangohud`, `gamemode`), `44)` PC Workstation Optimizer.

---

### 5. System Doctor & Diagnostics (`[8] --doctor`)
Run `./install_isteamos.sh --doctor` (or option **`8`**) via [`scripts/system_doctor.sh`](scripts/system_doctor.sh) to inspect:

- CPU model, kernel version, RAM/ZRAM capacity, and free space on `/` vs `/home`.
- Kernel **TCP BBR**, **inotify max_user_watches**, and **VM swappiness** values.
- `/etc/resolv.conf` symlink validity, **Cloudflare WARP** status/protocol, and live HTTP checks to **Steam Store, LinkedIn, and Facebook**.
- Installed status of **OneDrive / Google Drive** engines, **Fcitx5-Unikey**, **Podman / Distrobox**, **Decky Loader (`plugin_loader.service`)**, and **CUPS**.
