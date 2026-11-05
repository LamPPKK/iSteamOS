# 🎮💻 iSteamOS – Bộ Công Cụ Biến & Tối Ưu SteamOS Thành PC Thực Thụ

Bộ công cụ tự động hóa toàn diện giúp biến **SteamOS 3.x** (trên Steam Deck, ROG Ally, Legion Go, Mini PC / Handheld chạy Ryzen Z1 / Z1 Extreme) thành một **máy tính cá nhân (PC Workstation) hoàn chỉnh** kết hợp máy chơi game cầm tay tối ưu nhất tại Việt Nam.

---

## ✨ Điểm Nổi Bật Của iSteamOS

### 1. Chế Độ Cốt Lõi Handheld (`[1] Core Handheld Setup`)
Khi chọn phím **`1`** (`./install_isteamos.sh --core`), script **chỉ cài đặt 3 thành phần cốt lõi** gọn nhẹ nhất:
1. **Fix Steam, LinkedIn & Facebook Messenger tại Việt Nam (`scripts/fix_steam_vietnam.sh`):**
   - Cấu hình `systemd-resolved` **DNS-over-TLS** (`1.1.1.1#cloudflare-dns.com` & `8.8.8.8#dns.google`) và giữ nguyên symlink chuẩn `/etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf` (chống lỗi tự ngắt mạng mỗi 10 giây của `warp-svc`).
   - Chặn rò rỉ DNS `192.168.1.1` từ cục phát Wi-Fi/Modem nhà mạng trên NetworkManager.
   - Bật **Cloudflare WARP** ở chế độ `WireGuard` + `tunnel_only` giúp vượt tường lửa DPI truy cập **Steam Store, Steam Community, LinkedIn** tốc độ cao.
   - **Split-Tunneling thông minh cho Facebook & Messenger:** Tự động loại trừ toàn bộ dải IPv4 & IPv6 của Meta/Facebook/Messenger khỏi đường hầm WARP để tin nhắn Messenger và Facebook luôn đi trực tiếp qua mạng nội địa (độ trễ ~0.2s, không bao giờ bị treo khung chat).
2. **Gõ Tiếng Việt Chuẩn Wayland & X11 (`scripts/setup_unikey.sh`):**
   - Cài đặt và cấu hình sẵn `fcitx5`, `fcitx5-unikey`, `fcitx5-configtool` (kiểu gõ **Telex**, bảng mã **Unicode**), tự khởi động cùng KDE Plasma.
3. **Decky Loader + SimpleDeckyTDP + DeckyWARP (`scripts/install_decky_components.sh`):**
   - Quản lý TDP (4W – 30W+) cho dòng chip Ryzen Z1/Z1 Extreme và bật/tắt WARP ngay trong Game Mode, kèm bản vá chống văng plugin `Emuchievements` (`Symbol to string`).

---

### 2. Tối Ưu Hóa SteamOS Thành PC Workstation (`[6] PC Workstation Optimizer`)
Module [`scripts/optimize_pc_mode.sh`](scripts/optimize_pc_mode.sh) giải quyết triệt để các giới hạn của SteamOS khi dùng làm máy tính làm việc hàng ngày:
- **Tối ưu Kernel, RAM/ZRAM & Mạng TCP BBR (`/etc/sysctl.d/99-isteamos-pc.conf`):**
  - Bật thuật toán chống nghẽn mạng **Google TCP BBR** + `fq` + `tcp_mtu_probing=1` giúp tăng tốc độ tải file, xem video 4K và ổn định kết nối VPN/WARP.
  - Tinh chỉnh `vm.swappiness=100`, `vm.vfs_cache_pressure=50`, `vm.page-cluster=0` tối ưu hóa tốc độ nén RAM (ZRAM) khi mở hàng chục tab trình duyệt + IDE.
  - Nâng giới hạn `fs.inotify.max_user_watches=524288` để **VS Code, Google Antigravity, Android Studio** và **OneDrive/Google Drive** theo dõi file mượt mà không báo lỗi `ENOSPC`.
- **Bảo Vệ Phân Vùng Hệ Thống `/` 5GB Của SteamOS:**
  - Tự động dọn dẹp journal logs và gói đệm thừa trên `/var` & `/`, đồng thời kích hoạt `ParallelDownloads = 10` và `Color` cho `pacman`.
- **Rootless Containers (`Podman` + `Distrobox`) Lưu Trên `/home` (~300GB+):**
  - Cấu hình sẵn `/etc/subuid`, `/etc/subgid` và ánh xạ thư mục chứa container vào `~/.local/share/containers/storage` trên phân vùng `/home` rộng rãi, giúp cài mọi phần mềm Ubuntu/Fedora/Arch mà không tốn dung lượng ổ `/` và không mất dữ liệu khi cập nhật SteamOS.
- **Chuyển Đổi Chế Độ Khởi Động (`isteamos-boot-mode`):**
  - Gõ `isteamos-boot-mode desktop` để máy khởi động thẳng vào giao diện **KDE Plasma Desktop** như một chiếc PC thực thụ, hoặc `isteamos-boot-mode gaming` để quay về **Steam Gaming Mode**.
- **Dịch Vụ Máy In Văn Phòng (`CUPS`) & Mạng Nội Bộ (`Avahi mDNS`):**
  - Kích hoạt sẵn dịch vụ in ấn `cups.service` (hỗ trợ máy in USB/Wi-Fi/AirPrint và xuất file PDF) cùng `avahi-daemon.service`.

---

### 3. Đồng Bộ Đám Mây Microsoft OneDrive & Google Drive (`[7] Cloud Storage Sync`)
Module [`scripts/setup_cloud_sync.sh`](scripts/setup_cloud_sync.sh) tích hợp đầy đủ các giải pháp đồng bộ đám mây cho môi trường PC:
- **Microsoft OneDrive:**
  - **OneDriver (On-Demand Virtual Drive):** Gắn trực tiếp OneDrive vào `~/OneDrive` qua FUSE; chỉ tải file khi nhấn mở (tiết kiệm ổ cứng giống hệt OneDrive trên Windows 11).
  - **OneDriveGUI (`~/Applications/OneDriveGUI.AppImage`) & `onedrive-abraunegg`:** Đồng bộ 2 chiều tự động để làm việc offline, lưu trên `/home` để không chiếm phân vùng `/`.
- **Google Drive & Rclone VFS Auto-Mount:**
  - **KIO-GDrive:** Truy cập trực tiếp Google Drive trong trình quản lý file **KDE Dolphin** (`Network -> Google Drive`).
  - **Rclone + Rclone Browser Qt6 + Công cụ `isteamos-cloud-mount`:**
    - Chạy `isteamos-cloud-mount gdrive` để đăng nhập và tự động gắn Google Drive vào `~/GoogleDrive` mỗi khi bật máy.
    - Chạy `isteamos-cloud-mount onedrive` để đăng nhập và tự động gắn OneDrive vào `~/OneDrive` mỗi khi bật máy.

---

### 4. Kho 44 Ứng Dụng, Trình Duyệt & Công Cụ Lập Trình (`[5] Interactive Selector`)
Khi chọn phím **`5`** (`./install_isteamos.sh --tools`), bạn có thể **nhập số thứ tự từng phần mềm muốn cài** (ví dụ: `2, 15, 37, 43`) hoặc nhấn **`A`** để cài đặt toàn bộ 44 công cụ:
- **Trình duyệt (KWallet6 Sync):** `1)` Google Chrome, `2)` Microsoft Edge, `3)` Brave Browser.
- **Lập trình & Văn phòng:** `4)` Google Antigravity (IDE & CLI), `5)` VS Code, `6)` Android Studio, `7)` GitHub Desktop, `8)` Postman, `9)` Insomnia, `10)` Wireshark, `11)` draw.io, `12)` FileZilla, `13)` LibreOffice, `14)` Distrobox & Podman.
- **Liên lạc & Điều khiển từ xa:** `15)` Zalo Desktop (AppImage), `16)` LinuxViewer (UltraViewer), `17)` Beeper, `18)` Discord, `19)` Telegram, `20)` Viber, `21)` Signal, `22)` Slack, `23)` Zoom, `24)` OpenBubbles (iMessage), `25)` Proton Mail, `26)` Thunderbird, `27)` KDE Connect.
- **Giải trí & Streaming:** `28)` Spotify, `29)` VLC, `30)` mpv & GStreamer, `31)` OBS Studio, `32)` Parsec, `33)` NoiseTorch & Pavucontrol.
- **Mạng, VPN & Đám mây:** `34)` LocalSend, `35)` Nextcloud, `36)` Proton VPN, `37)` WireGuard VPN (`wireguard-tools`, `wgcf`, `vortix`, `wireproxy`), `38)` OpenVPN, `43)` Bộ công cụ đồng bộ OneDrive & Google Drive.
- **Tùy biến Desktop & Hệ thống:** `39)` Wallpaper Engine KDE Plasma 6, `40)` KDE Apps (Kate, Okular, Ark, Partition Manager), `41)` Homebrew (`fastfetch`, `gh`), `42)` CLI Suite (`paru`, `btop`, `ripgrep`, `fd`, `fzf`, `jq`, `tmux`, `zsh`, `neovim`, `docker`), `44)` PC Workstation Optimizer.

---

### 5. Chẩn Đoán Hệ Thống Toàn Diện (`[8] System Doctor`)
Chạy `./install_isteamos.sh --doctor` (hoặc chọn phím **`8`**) để kiểm tra tức thì:
- Thông số CPU, RAM/ZRAM, dung lượng trống trên `/` và `/home`.
- Trạng thái Kernel **TCP BBR**, **inotify watches**, và **ZRAM swappiness**.
- Trạng thái **DNS-over-TLS**, **Cloudflare WARP (WireGuard)** và kiểm tra kết nối HTTP trực tiếp tới **Steam Store, LinkedIn, Facebook Messenger**.
- Trạng thái các công cụ **OneDrive / Google Drive**, **Unikey**, **Podman/Distrobox**, **Decky Loader** và **Máy in CUPS**.

---

## 🚀 Hướng Dẫn Cài Đặt & Sử Dụng

Mở **Konsole (Terminal)** ở chế độ Desktop Mode và chạy:

```bash
git clone https://github.com/t2502/iSteamOS.git
cd iSteamOS
chmod +x install_isteamos.sh scripts/*.sh
./install_isteamos.sh
```

### Các Tham Số Chạy Nhanh (CLI Flags)
- `./install_isteamos.sh --core` : Cài đặt 3 thành phần cốt lõi (Fix Steam VN + Unikey + Decky).
- `./install_isteamos.sh --tools` : Mở bảng chọn cài đặt từng ứng dụng (`1..44` hoặc `A`).
- `./install_isteamos.sh --pc-mode --all` : Tối ưu hóa SteamOS thành PC Workstation.
- `./install_isteamos.sh --cloud-sync --all` : Cài đặt bộ đồng bộ OneDrive & Google Drive.
- `./install_isteamos.sh --doctor` : Chạy bảng kiểm tra sức khỏe hệ thống System Doctor.
- `./install_isteamos.sh --all` : Cài đặt và tối ưu hóa toàn diện từ A-Z.
