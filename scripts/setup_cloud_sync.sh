#!/usr/bin/env bash
# ==============================================================================
# Module: Cloud Storage Sync & Virtual Drive Setup (OneDrive & Google Drive)
# Description: Turns SteamOS into a full PC with seamless Cloud Storage:
#   - Microsoft OneDrive: OneDrive (abraunegg) + OneDriveGUI (AppImage) + OneDriver (FUSE)
#   - Google Drive: KIO-GDrive (KDE Dolphin Native) + Rclone + Rclone Browser Qt6
#   - Auto-mount systemd user template (rclone-mount@.service) for ~/OneDrive & ~/GoogleDrive
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

GREEN='\033[1;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RED='\033[1;31m'
NC='\033[0m'

readonly_changed=0

log_info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$1"; }
log_ok()   { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$1"; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1"; }
log_err()  { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1" >&2; }

restore_readonly() {
    if (( readonly_changed )); then
        log_info "Restoring SteamOS readonly mode..."
        sudo steamos-readonly enable
        readonly_changed=0
    fi
}

cleanup() {
    local exit_code=$?
    trap - EXIT
    set +e

    if (( readonly_changed )); then
        printf '\nRestoring SteamOS readonly mode after exit...\n' >&2
        if ! sudo steamos-readonly enable && (( exit_code == 0 )); then
            exit_code=1
        fi
    fi

    exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

disable_readonly_if_needed() {
    if command -v steamos-readonly >/dev/null 2>&1; then
        local readonly_status
        readonly_status="$(sudo steamos-readonly status 2>&1 || true)"
        if grep -qi 'enabled' <<< "$readonly_status"; then
            log_info "Temporarily disabling SteamOS readonly mode..."
            sudo steamos-readonly disable
            readonly_changed=1
        fi
    fi
}

install_cloud_packages() {
    log_info "Installing Cloud Sync tools (Rclone, Rclone Browser Qt6, OneDrive, OneDriver, KIO-GDrive)..."
    disable_readonly_if_needed
    sudo pacman -S --noconfirm --needed \
        rclone \
        rclone-browser-qt6 \
        kio-gdrive \
        kaccounts-providers \
        onedrive-abraunegg \
        onedriver \
        fuse3 || log_warn "Some packages encountered warnings, continuing..."
    restore_readonly

    log_info "Installing OneDriveGUI (AppImage in ~/Applications to save rootfs space)..."
    mkdir -p "$HOME/Applications" "$HOME/.local/share/applications"
    if [[ ! -f "$HOME/Applications/OneDriveGUI.AppImage" ]]; then
        local appimage_url
        appimage_url="$(curl -fsSL https://api.github.com/repos/bpozdena/OneDriveGUI/releases/latest 2>/dev/null \
            | grep -o 'https://github.com/bpozdena/OneDriveGUI/releases/download/[^"]*x86_64\.AppImage' | head -n1 || true)"
        if [[ -z "$appimage_url" ]]; then
            appimage_url="https://github.com/bpozdena/OneDriveGUI/releases/download/v2.4.0/OneDriveGUI-2.4.0-x86_64.AppImage"
        fi
        curl -fL "$appimage_url" -o "$HOME/Applications/OneDriveGUI.AppImage" || log_warn "Could not download OneDriveGUI AppImage."
    fi
    if [[ -f "$HOME/Applications/OneDriveGUI.AppImage" ]]; then
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

    cat <<'EOF' > "$HOME/.config/systemd/user/rclone-mount@.service"
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
    cat <<'EOF' > "$HOME/.local/bin/isteamos-cloud-mount"
#!/usr/bin/env bash
# Helper script to configure and auto-mount OneDrive or GoogleDrive via Rclone
set -Eeuo pipefail
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
    printf '\n'
    printf '%b======================================================================%b\n' "$CYAN" "$NC"
    printf '%b   ONEDRIVE & GOOGLE DRIVE USAGE GUIDE ON STEAMOS                     %b\n' "$GREEN" "$NC"
    printf '%b======================================================================%b\n' "$CYAN" "$NC"
    printf '1. %bMicrosoft OneDrive (On-Demand Virtual Drive like Windows 11):%b\n' "$YELLOW" "$NC"
    printf '   - Open %bOneDriver%b from the Application Menu -> Click "+" -> Choose %b~/OneDrive%b\n' "$GREEN" "$NC" "$CYAN" "$NC"
    printf '   - Sign in with your Microsoft account. Files appear in Dolphin without consuming disk space until opened.\n\n'
    printf '2. %bMicrosoft OneDrive (2-Way Offline Folder Sync):%b\n' "$YELLOW" "$NC"
    printf '   - Open %bOneDriveGUI%b from the Application Menu to create a profile and enable automatic 2-way sync.\n\n' "$GREEN" "$NC"
    printf '3. %bGoogle Drive & OneDrive Auto-Mount (Rclone VFS / Rclone Browser):%b\n' "$YELLOW" "$NC"
    printf '   - Option 1 (Fastest CLI): Run in Konsole:\n'
    printf '       %b~/.local/bin/isteamos-cloud-mount gdrive%b   (Mount Google Drive at ~/GoogleDrive)\n' "$GREEN" "$NC"
    printf '       %b~/.local/bin/isteamos-cloud-mount onedrive%b (Mount OneDrive at ~/OneDrive)\n' "$GREEN" "$NC"
    printf '   - Option 2 (GUI): Launch %bRclone Browser%b from the Application Menu.\n' "$GREEN" "$NC"
    printf '   - Option 3 (Dolphin Native): Open %bDolphin -> Network -> Google Drive%b (KIO-GDrive).\n' "$GREEN" "$NC"
    printf '%b======================================================================%b\n' "$CYAN" "$NC"
}

printf '%b======================================================================%b\n' "$CYAN" "$NC"
printf '%b   [Cloud Sync] OneDrive & Google Drive PC Integration for SteamOS    %b\n' "$GREEN" "$NC"
printf '%b======================================================================%b\n\n' "$CYAN" "$NC"

if [[ "${1:-}" == "--all" || "${1:-}" == "--auto" ]]; then
    install_cloud_packages
    setup_rclone_systemd_template
    create_cloud_helper_cli
    print_cloud_usage_guide
    exit 0
fi

printf '  %b[1]%b Install All Cloud Sync Tools & Auto-Mount Services (Recommended)\n' "$GREEN" "$NC"
printf '  %b[2]%b Configure & Mount Google Drive now (Interactive Browser Login)\n' "$GREEN" "$NC"
printf '  %b[3]%b Configure & Mount Microsoft OneDrive now (Interactive Browser Login)\n' "$GREEN" "$NC"
printf '  %b[4]%b Launch OneDriver GUI (OneDrive On-Demand Mount)\n' "$GREEN" "$NC"
printf '  %b[5]%b Launch OneDriveGUI (OneDrive 2-Way Sync Manager)\n' "$GREEN" "$NC"
printf '  %b[6]%b Check Cloud Sync Status\n' "$GREEN" "$NC"
printf '  %b[0]%b Back / Exit\n\n' "$GREEN" "$NC"
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
        if [[ -x "$HOME/Applications/OneDriveGUI.AppImage" ]]; then
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
