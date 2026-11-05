#!/bin/bash
# ==============================================================================
# Module: Cloud Storage Sync & Virtual Drive Setup (OneDrive & Google Drive)
# Description: Turns SteamOS into a full PC with seamless Cloud Storage:
#   - Microsoft OneDrive: OneDrive Abraunegg + OneDriveGUI (AppImage) + OneDriver (FUSE)
#   - Google Drive: KIO-GDrive (KDE Dolphin Native) + Rclone + Rclone Browser Qt6
#   - Auto-mount systemd user template (rclone-mount@.service) for ~/OneDrive & ~/GoogleDrive
# ==============================================================================

set -e

GREEN='\033[1;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RED='\033[1;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

echo -e "${CYAN}======================================================================${NC}"
echo -e "${GREEN}   [Cloud Sync] OneDrive & Google Drive PC Integration for SteamOS    ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo ""

unlock_steamos() {
    if command -v steamos-readonly &>/dev/null; then
        sudo steamos-readonly disable 2>/dev/null || true
    fi
}

install_cloud_packages() {
    log_info "Installing Cloud Sync tools (Rclone, Rclone Browser Qt6, OneDrive, OneDriver, KIO-GDrive)..."
    unlock_steamos
    sudo pacman -S --noconfirm --needed \
        rclone \
        rclone-browser-qt6 \
        kio-gdrive \
        kaccounts-providers \
        onedrive-abraunegg \
        onedriver \
        fuse3 || log_warn "Some packages encountered warnings, continuing..."

    log_info "Installing OneDriveGUI (AppImage in ~/Applications to save rootfs space)..."
    mkdir -p "$HOME/Applications" "$HOME/.local/share/applications"
    if [ ! -f "$HOME/Applications/OneDriveGUI.AppImage" ]; then
        local appimage_url
        appimage_url=$(curl -s https://api.github.com/repos/bpozdena/OneDriveGUI/releases/latest \
            | grep -o 'https://github.com/bpozdena/OneDriveGUI/releases/download/[^"]*x86_64\.AppImage' | head -n1 || true)
        if [ -z "$appimage_url" ]; then
            appimage_url="https://github.com/bpozdena/OneDriveGUI/releases/download/v2.4.0/OneDriveGUI-2.4.0-x86_64.AppImage"
        fi
        curl -fL "$appimage_url" -o "$HOME/Applications/OneDriveGUI.AppImage" || log_warn "Could not download OneDriveGUI AppImage."
    fi
    if [ -f "$HOME/Applications/OneDriveGUI.AppImage" ]; then
        chmod +x "$HOME/Applications/OneDriveGUI.AppImage"
        cat <<EOF > "$HOME/.local/share/applications/onedrivegui.desktop"
[Desktop Entry]
Name=OneDriveGUI
Comment=A simple GUI for OneDrive Linux client with multi-account support
Exec=$HOME/Applications/OneDriveGUI.AppImage
Icon=cloud-folder
Terminal=false
Type=Application
Categories=Network;FileTransfer;Utility;
StartupNotify=true
EOF
        chmod +x "$HOME/.local/share/applications/onedrivegui.desktop"
    fi
    log_ok "All OneDrive & Google Drive sync packages installed."
}

setup_rclone_systemd_template() {
    log_info "Creating Rclone VFS Auto-Mount Systemd User Service template..."
    mkdir -p "$HOME/.config/systemd/user"
    mkdir -p "$HOME/OneDrive" "$HOME/GoogleDrive" "$HOME/.cache/rclone-vfs"

    cat << 'EOF' > "$HOME/.config/systemd/user/rclone-mount@.service"
[Unit]
Description=Rclone VFS Mount for %i Cloud Storage (iSteamOS PC Mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=/usr/bin/mkdir -p %h/%i %h/.cache/rclone-vfs/%i
ExecStart=/usr/bin/rclone mount %i: %h/%i \
    --vfs-cache-mode full \
    --vfs-cache-max-size 15G \
    --vfs-cache-max-age 72h \
    --vfs-read-chunk-size 32M \
    --vfs-read-chunk-size-limit 256M \
    --dir-cache-time 72h \
    --poll-interval 30s \
    --cache-dir %h/.cache/rclone-vfs/%i \
    --volname %i
ExecStop=/bin/fusermount3 -uz %h/%i
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload 2>/dev/null || true
    log_ok "Systemd template created: ~/.config/systemd/user/rclone-mount@.service"
}

create_cloud_helper_cli() {
    log_info "Creating quick helper launcher: ~/.local/bin/isteamos-cloud-mount..."
    mkdir -p "$HOME/.local/bin"
    cat << 'EOF' > "$HOME/.local/bin/isteamos-cloud-mount"
#!/bin/bash
# Helper script to configure and auto-mount OneDrive or GoogleDrive via Rclone
set -e
MODE="${1:-help}"
case "$MODE" in
    gdrive|GoogleDrive)
        echo "=== Configuring Google Drive in Rclone (Remote name: GoogleDrive) ==="
        echo "Follow the browser prompt to sign in to Google Drive."
        rclone config create GoogleDrive drive scope=drive
        systemctl --user enable --now rclone-mount@GoogleDrive.service
        echo "[OK] Google Drive is now mounted at ~/GoogleDrive and will auto-mount on boot!"
        ;;
    onedrive|OneDrive)
        echo "=== Configuring Microsoft OneDrive in Rclone (Remote name: OneDrive) ==="
        echo "Follow the browser prompt to sign in to Microsoft OneDrive."
        rclone config create OneDrive onedrive
        systemctl --user enable --now rclone-mount@OneDrive.service
        echo "[OK] Microsoft OneDrive is now mounted at ~/OneDrive and will auto-mount on boot!"
        ;;
    status)
        echo "=== Configured Rclone Remotes ==="
        rclone listremotes || true
        echo ""
        echo "=== Active Cloud Mount Services ==="
        systemctl --user list-units "rclone-mount@*" "onedriver@*" "onedrive*" --no-pager || true
        ;;
    *)
        echo "Usage: isteamos-cloud-mount [gdrive | onedrive | status]"
        echo "  isteamos-cloud-mount gdrive   -> Sign in & auto-mount Google Drive at ~/GoogleDrive"
        echo "  isteamos-cloud-mount onedrive -> Sign in & auto-mount OneDrive at ~/OneDrive"
        echo "  isteamos-cloud-mount status   -> Check active cloud sync mounts"
        ;;
esac
EOF
    chmod +x "$HOME/.local/bin/isteamos-cloud-mount"
    log_ok "Created helper CLI: isteamos-cloud-mount"
}

print_cloud_usage_guide() {
    echo ""
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${GREEN}   HƯỚNG DẪN SỬ DỤNG ONEDRIVE & GOOGLE DRIVE TRÊN STEAMOS             ${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "1. ${YELLOW}Microsoft OneDrive (On-Demand Virtual Drive như Windows 11):${NC}"
    echo -e "   - Mở ứng dụng ${GREEN}OneDriver${NC} trong Application Menu -> Nhấn dấu '+' -> Chọn thư mục ${CYAN}~/OneDrive${NC}"
    echo -e "   - Đăng nhập tài khoản Microsoft. Toàn bộ file xuất hiện ngay trong Dolphin mà không tốn ổ cứng!"
    echo -e ""
    echo -e "2. ${YELLOW}Microsoft OneDrive (2-Way Offline Folder Sync):${NC}"
    echo -e "   - Mở ứng dụng ${GREEN}OneDriveGUI${NC} trong Application Menu để tạo profile & đồng bộ tự động 2 chiều."
    echo -e ""
    echo -e "3. ${YELLOW}Google Drive & OneDrive Auto-Mount (Rclone VFS / Rclone Browser):${NC}"
    echo -e "   - Cách 1 (Nhanh nhất): Mở Terminal chạy:"
    echo -e "       ${GREEN}~/.local/bin/isteamos-cloud-mount gdrive${NC}   (Gắn Google Drive vào ~/GoogleDrive)"
    echo -e "       ${GREEN}~/.local/bin/isteamos-cloud-mount onedrive${NC} (Gắn OneDrive vào ~/OneDrive)"
    echo -e "   - Cách 2 (Giao diện GUI): Mở ${GREEN}Rclone Browser${NC} trong Application Menu."
    echo -e "   - Cách 3 (Dolphin Native): Mở ${GREEN}Dolphin -> Network -> Google Drive${NC} (KIO-GDrive)."
    echo -e "${CYAN}======================================================================${NC}"
}

if [[ "$1" == "--all" || "$1" == "--auto" ]]; then
    install_cloud_packages
    setup_rclone_systemd_template
    create_cloud_helper_cli
    print_cloud_usage_guide
    exit 0
fi

echo -e "  ${GREEN}[1]${NC} Install All Cloud Sync Tools & Auto-Mount Services (Recommended)"
echo -e "  ${GREEN}[2]${NC} Configure & Mount Google Drive now (Interactive Browser Login)"
echo -e "  ${GREEN}[3]${NC} Configure & Mount Microsoft OneDrive now (Interactive Browser Login)"
echo -e "  ${GREEN}[4]${NC} Launch OneDriver GUI (OneDrive On-Demand Mount)"
echo -e "  ${GREEN}[5]${NC} Launch OneDriveGUI (OneDrive 2-Way Sync Manager)"
echo -e "  ${GREEN}[6]${NC} Check Cloud Sync Status"
echo -e "  ${GREEN}[0]${NC} Back / Exit"
echo ""
read -rp "Select option [0-6]: " CLOUD_OPT

case "$CLOUD_OPT" in
    1)
        install_cloud_packages
        setup_rclone_systemd_template
        create_cloud_helper_cli
        print_cloud_usage_guide
        ;;
    2)
        install_cloud_packages
        setup_rclone_systemd_template
        create_cloud_helper_cli
        "$HOME/.local/bin/isteamos-cloud-mount" gdrive
        ;;
    3)
        install_cloud_packages
        setup_rclone_systemd_template
        create_cloud_helper_cli
        "$HOME/.local/bin/isteamos-cloud-mount" onedrive
        ;;
    4)
        nohup onedriver-launcher >/dev/null 2>&1 &
        log_ok "Launched OneDriver GUI."
        ;;
    5)
        if [ -x "$HOME/Applications/OneDriveGUI.AppImage" ]; then
            nohup "$HOME/Applications/OneDriveGUI.AppImage" >/dev/null 2>&1 &
        else
            nohup onedrivegui >/dev/null 2>&1 &
        fi
        log_ok "Launched OneDriveGUI."
        ;;
    6)
        create_cloud_helper_cli
        "$HOME/.local/bin/isteamos-cloud-mount" status
        ;;
    *)
        log_info "Exiting Cloud Sync setup."
        ;;
esac
