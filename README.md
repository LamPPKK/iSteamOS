# SteamOS Post Install – All in One

Bộ script cài đặt và cập nhật môi trường bổ sung toàn diện dành cho anh em sử dụng **SteamOS** trên máy chơi game cầm tay như **ASUS ROG Ally Z1 / Z1 Extreme**, **Steam Deck** và các dòng handheld PC x86_64 khác.

---

## Tính năng nổi bật

1. **Quản lý công suất TDP & Xung nhịp cho AMD Ryzen Z1 / Z1 Extreme & Handhelds:**
   - Cài sẵn **Decky Loader v3.3.1** và plugin **SimpleDeckyTDP v1.0.7** với backend `ryzenadj` đã được vá mã an toàn (có hash SHA-256 xác thực).
   - Cho phép anh em chỉnh trực tiếp công suất TDP (W), xung CPU/GPU, giới hạn nhiệt độ ngay trong menu Quick Access (`...`) ở Gaming Mode của SteamOS.

2. **Khắc phục triệt để lỗi Steam bị chặn tại Việt Nam:**
   - Tích hợp **Cloudflare WARP** (`cloudflare-warp-bin` & dịch vụ nền `warp-svc.service`).
   - Cài đặt plugin **DeckyWARP** cho phép bật/tắt WARP trực tiếp trong Gaming Mode.
   - Tự động cấu hình DNS dự phòng chuẩn (`1.1.1.1` & `8.8.8.8`) để loại bỏ hoàn toàn lỗi **"CONTENT SERVERS UNREACHABLE"** hay **"CONTENT UNAVAILABLE"** khi tải game và cập nhật Proton/Runtime.

3. **Bộ gõ Tiếng Việt Unikey (Fcitx5):**
   - Tự động cài đặt đầy đủ bộ gói `fcitx5`, `fcitx5-unikey`, `fcitx5-gtk`, `fcitx5-qt`, `fcitx5-configtool`.
   - Cấu hình sẵn biến môi trường (`GTK_IM_MODULE`, `QT_IM_MODULE`, `XMODIFIERS`) và file profile mặc định nạp sẵn Unikey + Keyboard US.
   - Tự động khởi động cùng hệ thống khi vào Desktop Mode.

4. **Trình duyệt & Bộ công cụ phát triển hiện đại:**
   - **Brave Browser:** Cài đặt trực tiếp qua trình cài đặt chính thức (`curl -fsS https://dl.brave.com/install.sh | FLAVOR=origin sh`).
   - **Google Antigravity CLI (`agy`):** Cài đặt tự động và tích hợp sẵn đường dẫn `$PATH` vào `~/.bashrc` / `~/.zshrc`.
   - **Homebrew:** Tự động cài đặt hoặc cập nhật phiên bản mới nhất từ `HEAD` không cần can thiệp, kèm tiện ích hiển thị cấu hình `fastfetch`.
   - **Visual Studio Code, Microsoft Edge & GitHub Desktop:** Cài đặt từ Flathub kèm cấu hình lưu mật khẩu mã hóa KWallet (thay thế thiết lập `password-store=basic` không bảo mật).

5. **Cơ chế an toàn cho phân vùng hệ điều hành SteamOS:**
   - Tự động ghi nhớ và khôi phục trạng thái `steamos-readonly` (chế độ bảo vệ phân vùng gốc của SteamOS).
   - Tự động sao lưu cấu hình cũ trước khi ghi đè, cơ chế rollback an toàn nếu quá trình tải hoặc cài đặt gặp sự cố.

---

## Cấu trúc thư mục

```text
iSteamOS/
├── install_isteamos.sh            # Trình cài đặt chính duy nhất (kèm menu tương tác)
├── README.md                      # Tài liệu hướng dẫn sử dụng
├── patches/
│   └── simple_decky_tdp/
│       └── plugin_update.py       # Patch an toàn cho SimpleDeckyTDP OTA updater
└── scripts/
    ├── install_decky_components.sh # Cài Decky Loader, SimpleDeckyTDP (Ryzen Z1) & DeckyWARP
    ├── fix_steam_vietnam.sh       # Bật Cloudflare WARP & sửa DNS Steam tại Việt Nam
    ├── setup_unikey.sh            # Cài đặt và cấu hình Fcitx5 + Unikey tiếng Việt (tự bật khi mở máy)
    └── setup_tools.sh             # Cài bộ ứng dụng hoàn chỉnh: Trình duyệt, Dev Tools, Chat & Giải trí
```

---

## Hướng dẫn cài đặt

Chuyển máy sang **Desktop Mode**, mở ứng dụng **Konsole** (Terminal) và chạy:

```bash
git clone https://github.com/LamPPKK/iSteamOS.git
cd iSteamOS
./install_isteamos.sh
```

Script sẽ hiển thị bảng menu tương tác để bạn chọn mục cần cài đặt:

```text
===================================================================
                 SteamOS Post Install – All in One
===================================================================
  [1] Full Installation (All-in-One - Khuyên dùng)
      • Dev Mode, Base Packages, Brave, Homebrew (fastfetch, gh)
      • Google Antigravity (IDE & CLI), VS Code, Android Studio, Edge, Chrome
      • GitHub Desktop, Postman, Insomnia, draw.io, FileZilla, LibreOffice
      • Zalo for Linux, LinuxViewer (UltraViewer), Discord, Telegram, Viber, Signal, Slack, Zoom
      • Spotify, VLC, OBS Studio, Parsec, LocalSend, Nextcloud, Proton VPN, OpenBubbles, Proton Mail
      • Bộ gõ Tiếng Việt Fcitx5-Unikey (Tự động bật khi mở máy, chuẩn Telex Unicode)
      • Decky Loader + SimpleDeckyTDP (Ryzen Z1 / Handhelds) + DeckyWARP
      • Cloudflare WARP & Sửa lỗi Steam bị chặn tại VN

  [2] Fix Steam in Vietnam (Cloudflare WARP & DNS Fix)
      • Sửa DNS fallback (1.1.1.1 / 8.8.8.8)
      • Bật và kết nối Cloudflare WARP tự động
      • Sửa lỗi "Content Servers Unreachable" khi tải game Steam

  [3] Install Vietnamese IME (Fcitx5 + Unikey Only)
      • Cài gói, cấu hình autostart khi bật máy, environment và profile Unikey

  [4] Install Decky Components & TDP Control
      • Decky Loader v3.3.1 + SimpleDeckyTDP v1.0.7 + DeckyWARP

  [5] Install Apps, Browsers & Developer Tools Only
      • Trọn bộ ứng dụng Flatpak, Trình duyệt, Dev Tools & Cấu hình KWallet

  [0] Exit
===================================================================
```

> [!TIP]
> Bạn cũng có thể truyền cờ lệnh trực tiếp nếu không muốn chọn menu:
>
> - `./install_isteamos.sh --all` : Chạy cài đặt trọn gói tất cả.
> - `./install_isteamos.sh --steam-fix` : Chỉ sửa lỗi Steam bị chặn tại Việt Nam.
> - `./install_isteamos.sh --unikey` : Chỉ cài bộ gõ tiếng Việt Unikey.
> - `./install_isteamos.sh --decky` : Chỉ cài Decky Loader & SimpleDeckyTDP.
> - `./install_isteamos.sh --tools` : Chỉ cài Brave, Antigravity, Brew, Flatpaks & GitHub Desktop.

> [!IMPORTANT]
> **Không** chạy script bằng lệnh `sudo ./install_isteamos.sh`. Script được thiết kế để chạy với quyền user `deck` bình thường và sẽ tự yêu cầu mật khẩu `sudo` ở những bước cần thiết.
> Sau khi cài đặt hoàn tất, hãy khởi động lại máy.

---

## Thiết lập tối ưu sau khi cài đặt

1. **Điều khiển TDP trong Gaming Mode:**
   - Nhấn nút **Command Center** hoặc phím tắt mở menu Quick Access (`...`) của SteamOS.
   - Tìm mục **SimpleDeckyTDP** để tùy chỉnh mức tiêu thụ điện (ví dụ: 15W cân bằng, 25W-30W khi cắm sạc cho Z1 Extreme).
2. **Tối ưu tải game Steam không bị nghẽn mạng:**
   - Trong ứng dụng Steam: Vào **Settings** $\rightarrow$ **Downloads**.
   - Chuyển **Download Region** sang **Singapore** hoặc **Hong Kong**.
   - Tắt tùy chọn **Game file transfer over local network** nếu mạng không ổn định.
3. **Mở kho mật khẩu KWallet (Lần đầu mở VS Code / Edge):**
   - Trong Desktop Mode, mở **KWalletManager** và tạo/mở ví mặc định `kdewallet` (khuyến khích đặt trùng mật khẩu đăng nhập `deck`).
4. **Kiểm tra công cụ trong Terminal:**

   ```bash
   fastfetch
   agy --version
   warp-cli status
   ```

---

## License
