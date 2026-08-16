# SteamOS Post Install – All in One

Script cài đặt và cập nhật môi trường SteamOS sau khi cài lại hệ thống.

Hỗ trợ các máy x86_64 chạy SteamOS, gồm Steam Deck và một số handheld như ROG Ally.

## Cài đặt

Mở Konsole trong Desktop Mode rồi chạy:

```bash
git clone https://github.com/LamPPKK/iSteamOS.git
cd iSteamOS
./install_isteamos.sh
```

Không chạy script bằng `sudo`. Script sẽ tự yêu cầu quyền quản trị ở những bước cần thiết.

Sau khi hoàn tất, khởi động lại máy.

## Script sẽ làm gì

- Ghi nhớ trạng thái readonly hiện tại, tạm tắt khi cần và khôi phục trước khi thoát, kể cả khi gặp lỗi.
- Bật SteamOS developer mode và khởi tạo môi trường phát triển.
- Cập nhật đầy đủ gói hệ thống bằng `pacman -Syu` và cài các dependency cần thiết.
- Cài hoặc cập nhật Homebrew và `fastfetch`.
- Cài hoặc cập nhật Visual Studio Code và Microsoft Edge từ Flathub.
- Cấu hình `password-store=basic` trong `~/.vscode/argv.json` cho VS Code vì SteamOS không cung cấp KWallet đầy đủ.
- Cài Fcitx5 cùng bộ gõ tiếng Việt Unikey và bật Fcitx5 khi đăng nhập.
- Cài Decky Loader v3.2.6, SimpleDeckyTDP v1.0.5 và DeckyWARP v1.6.1 từ fork được duy trì tại `LamPPKK/DeckyWARP`.

Homebrew bootstrap entrypoint được ghim theo commit và SHA-256. Với các thành phần Decky, binary, service file, archive và installer đều được ghim theo phiên bản/commit và kiểm tra SHA-256 trước khi dùng. Decky Loader và SimpleDeckyTDP được cài qua staging có rollback, không xóa bản đang hoạt động trước khi tải và kiểm tra bản mới.

## Những thay đổi so với bản cũ

- `neofetch` được thay bằng `fastfetch` vì công thức Homebrew của `neofetch` không còn tồn tại.
- DeckyWARP được chuyển sang fork `LamPPKK/DeckyWARP`, dùng API Decky hiện hành, Cloudflare WARP 2026.6.880-1 và không thêm Chaotic-AUR vào `pacman.conf`.
- Không còn chạy trực tiếp installer Decky/SimpleDeckyTDP có tải lồng từ `latest`; script ghim và kiểm tra chính payload được cài, đồng thời phục hồi bản cũ nếu cài hoặc restart dịch vụ thất bại.
- Trình cập nhật OTA không xác minh TLS/checksum của SimpleDeckyTDP v1.0.5 bị vô hiệu hóa ở cả backend và kiểm tra phiên bản; hãy chạy lại iSteamOS khi muốn nâng plugin này bằng payload đã xác minh.
- Không còn tạo `GAMESCOPE_FORCE_HDR=0` vì đây không phải thiết lập Gamescope hiện hành được hỗ trợ.
- Nếu script tìm thấy đúng file Gamescope cũ do phiên bản trước tạo, file đó sẽ được đổi tên thành bản sao lưu thay vì bị xóa.
- Không xóa cache Gamescope.

## Sau khi khởi động lại

Mở **Fcitx5 Configuration**, thêm **Unikey**, rồi kiểm tra:

```bash
fastfetch
fcitx5-remote
flatpak list
```

Trong Gaming Mode, kiểm tra Decky Loader, SimpleDeckyTDP và DeckyWARP từ menu Quick Access. Lần đầu mở DeckyWARP, chọn **Install Cloudflare WARP**; plugin cũng có nút **Update / repair Cloudflare WARP**.

## Lưu ý

- Các gói cài trực tiếp bằng `pacman` có thể bị SteamOS thay thế sau một bản cập nhật hệ điều hành lớn; khi đó hãy chạy lại script.
- Cloudflare không hỗ trợ SteamOS/Arch chính thức. DeckyWARP đóng gói binary Ubuntu chính thức bằng recipe được ghim từ AUR, vì vậy nên kiểm tra kết nối thực tế sau khi cài.
- Visual Studio Code và Microsoft Edge trên Flathub là các gói do cộng đồng đóng gói, không phải bản Flatpak được Microsoft hỗ trợ chính thức.
- `password-store=basic` chỉ dùng cơ chế che giấu có thể đảo ngược, không phải mã hóa an toàn. Script sẽ cảnh báo và không sửa `argv.json` nếu file hiện có chứa comment hoặc JSON không hợp lệ.
- Khi nâng phiên bản Homebrew installer hoặc các pin trong `scripts/install_decky_components.sh`, phải cập nhật đồng thời checksum SHA-256 tương ứng.

## License

MIT – Use at your own risk.
