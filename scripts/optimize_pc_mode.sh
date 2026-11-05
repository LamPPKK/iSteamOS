#!/bin/bash
# ==============================================================================
# Module: SteamOS to Full PC Workstation Optimizer (optimize_pc_mode.sh)
# Description: Transforms SteamOS into a high-performance daily-driver PC:
#   1. Kernel, RAM/ZRAM, File Watchers (inotify for IDEs/Cloud) & TCP BBR Network
#   2. SteamOS 5GB Rootfs (/) Space Optimizer & Pacman ParallelDownloads Tuning
#   3. Rootless Dev Containers (Podman + Distrobox on /home partition)
#   4. Desktop Ergonomics: Boot Mode Switcher (Desktop vs Game Mode), KWallet6,
#      and Decky Plugin Crash Auto-Patcher
#   5. Office Printing (CUPS + PDF Printer) & LAN Discovery (Avahi mDNS / SSH)
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
echo -e "${GREEN}   [PC Workstation] SteamOS to Full PC Optimizer & System Tuner       ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo ""

unlock_steamos() {
    if command -v steamos-readonly &>/dev/null; then
        sudo steamos-readonly disable 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 1. Kernel, RAM/ZRAM, File Watchers (IDEs/Cloud Sync) & TCP BBR Networking
# ------------------------------------------------------------------------------
tune_kernel_ram_network() {
    log_info "Applying PC Workstation Kernel, ZRAM, IDE File-Watcher & TCP BBR tuning..."
    unlock_steamos

    sudo mkdir -p /etc/modules-load.d /etc/sysctl.d
    echo "tcp_bbr" | sudo tee /etc/modules-load.d/isteamos-bbr.conf >/dev/null
    sudo modprobe tcp_bbr 2>/dev/null || true

    sudo tee /etc/sysctl.d/99-isteamos-pc.conf >/dev/null << 'EOF'
# ==============================================================================
# iSteamOS PC Workstation & Gaming Optimization Profile
# ==============================================================================

# --- Memory & ZRAM Optimization ---
vm.swappiness = 100
vm.vfs_cache_pressure = 50
vm.page-cluster = 0
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
vm.max_map_count = 2147483642

# --- IDE (VS Code / Antigravity / JetBrains) & Cloud Sync (OneDrive/GDrive) ---
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
fs.file-max = 2097152

# --- Network Performance (TCP BBR + Fast Queue + PMTU Probing for WARP/VPN) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

    sudo sysctl --system >/dev/null 2>&1 || true
    log_ok "Kernel parameters applied (TCP BBR, ZRAM swappiness=100, inotify=524288)."
}

# ------------------------------------------------------------------------------
# 2. SteamOS 5GB Rootfs (/) Space Optimizer & Pacman Speed Tuning
# ------------------------------------------------------------------------------
optimize_rootfs_and_pacman() {
    log_info "Optimizing SteamOS 5GB Root (/) partition space & Pacman configuration..."
    unlock_steamos

    # Enable Color and ParallelDownloads = 10 in /etc/pacman.conf
    if [ -f /etc/pacman.conf ]; then
        sudo sed -i 's/^#Color/Color/' /etc/pacman.conf
        if grep -q "^#ParallelDownloads" /etc/pacman.conf; then
            sudo sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
        elif grep -q "^ParallelDownloads" /etc/pacman.conf; then
            sudo sed -i 's/^ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
        fi
    fi

    # Vacuum systemd journals to free /var space
    sudo journalctl --vacuum-size=50M >/dev/null 2>&1 || true

    # Clean cached package downloads & temp build dirs
    sudo pacman -Sc --noconfirm >/dev/null 2>&1 || true
    rm -rf /tmp/yay-* /tmp/pamac-* 2>/dev/null || true

    local root_avail home_avail
    root_avail=$(df -h / | awk 'NR==2 {print $4 " free (" $5 " used)"}')
    home_avail=$(df -h /home | awk 'NR==2 {print $4 " free (" $5 " used)"}')
    log_ok "Storage optimized -> Root (/): ${root_avail} | Home (/home): ${home_avail}"
}

# ------------------------------------------------------------------------------
# 3. Rootless Containers & Dev Workstation (Podman + Distrobox on /home)
# ------------------------------------------------------------------------------
setup_distrobox_podman() {
    log_info "Configuring Rootless Podman & Distrobox (stored on /home to save / space)..."
    unlock_steamos

    local current_user="${SUDO_USER:-$USER}"
    sudo touch /etc/subuid /etc/subgid
    if ! grep -q "^${current_user}:" /etc/subuid 2>/dev/null; then
        echo "${current_user}:100000:65536" | sudo tee -a /etc/subuid >/dev/null
    fi
    if ! grep -q "^${current_user}:" /etc/subgid 2>/dev/null; then
        echo "${current_user}:100000:65536" | sudo tee -a /etc/subgid >/dev/null
    fi

    mkdir -p "$HOME/.config/containers" "$HOME/.local/share/containers/storage"
    cat << EOF > "$HOME/.config/containers/storage.conf"
[storage]
driver = "overlay"
graphroot = "$HOME/.local/share/containers/storage"
runroot = "/run/user/$(id -u)/containers"
EOF

    cat << 'EOF' > "$HOME/.distroboxrc"
# iSteamOS Distrobox Configuration - Uses Rootless Podman on /home
container_manager="podman"
EOF

    if command -v podman &>/dev/null; then
        podman system migrate 2>/dev/null || true
    fi
    log_ok "Rootless Podman & Distrobox configured on ~/.local/share/containers."
}

# ------------------------------------------------------------------------------
# 4. Desktop PC Ergonomics, Boot Mode Switcher & Decky Plugin Auto-Fix
# ------------------------------------------------------------------------------
optimize_desktop_ergonomics() {
    log_info "Setting up Desktop PC Ergonomics, Boot Mode Switcher & KWallet6..."

    mkdir -p "$HOME/.local/bin"
    cat << 'EOF' > "$HOME/.local/bin/isteamos-boot-mode"
#!/bin/bash
# Switch SteamOS Default Boot Mode between Desktop PC Mode and Handheld Gaming Mode
set -e
MODE="${1:-status}"
case "$MODE" in
    desktop|pc)
        if command -v steamos-session-select &>/dev/null; then
            echo "Switching current session / boot default to KDE Plasma Desktop Mode..."
            steamos-session-select plasma-x11-persistent 2>/dev/null || steamos-session-select plasma 2>/dev/null || true
            echo "[OK] Configured to boot directly into KDE Plasma Desktop Mode!"
        else
            echo "[WARN] steamos-session-select not found on this OS."
        fi
        ;;
    gaming|gamescope|deck)
        if command -v steamos-session-select &>/dev/null; then
            echo "Switching session / boot default back to Steam Gaming Mode..."
            steamos-session-select gamescope 2>/dev/null || true
            echo "[OK] Configured to boot into Steam Gaming Mode!"
        else
            echo "[WARN] steamos-session-select not found on this OS."
        fi
        ;;
    status|*)
        echo "=== iSteamOS Boot Mode Switcher ==="
        if [ -f /etc/sddm.conf.d/zz-steamos-autologin.conf ]; then
            grep -E "Session=" /etc/sddm.conf.d/zz-steamos-autologin.conf || true
        fi
        echo "Usage:"
        echo "  isteamos-boot-mode desktop  -> Boot directly into KDE Plasma PC Mode"
        echo "  isteamos-boot-mode gaming   -> Boot into Steam Handheld Gaming Mode"
        ;;
esac
EOF
    chmod +x "$HOME/.local/bin/isteamos-boot-mode"

    # Ensure ~/.local/bin is in PATH inside ~/.bashrc
    if [ -f "$HOME/.bashrc" ] && ! grep -q '\.local/bin' "$HOME/.bashrc"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    fi

    # KWallet6 Flatpak integration so browsers persist passwords across reboots
    if command -v flatpak &>/dev/null; then
        sudo flatpak override --filesystem=xdg-run/kwalletd:ro 2>/dev/null || true
        flatpak override --user --filesystem=xdg-run/kwalletd:ro 2>/dev/null || true
    fi

    # Auto-patch Emuchievements Decky Plugin Symbol crash if present
    local emu_js="/home/deck/homebrew/plugins/Emuchievements/dist/index.js"
    if [ -f "$emu_js" ] && grep -q 'm\[prop\]\.toString()' "$emu_js" 2>/dev/null; then
        log_info "Applying stability patch to Decky Emuchievements plugin..."
        sudo cp "$emu_js" "${emu_js}.bak" 2>/dev/null || true
        sudo python3 - "$emu_js" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    c = f.read()
old1 = "if (m[prop]?.toString && /\\.createPlayer\\(|\\.getAchievementProgress\\(/.test(m[prop].toString()))"
new1 = "if (typeof m[prop] === 'function' && (() => { try { return /\\.createPlayer\\(|\\.getAchievementProgress\\(/.test(Function.prototype.toString.call(m[prop])); } catch (e) { return false; } })())"
c = c.replace(old1, new1)
old2 = "WrappedComponent.displayName = `wrapStyled(${WrappedComponent.name})`;"
new2 = "WrappedComponent.displayName = `wrapStyled(${String(WrappedComponent?.name ?? 'Component')})`;"
c = c.replace(old2, new2)
with open(path, "w", encoding="utf-8") as f:
    f.write(c)
PYEOF
        sudo systemctl restart plugin_loader.service 2>/dev/null || true
        log_ok "Patched Emuchievements plugin Symbol crash."
    fi

    log_ok "Desktop PC Ergonomics & KWallet6 persistence configured."
}

# ------------------------------------------------------------------------------
# 5. Office Printing (CUPS + PDF) & Local Network Discovery (Avahi / SSH)
# ------------------------------------------------------------------------------
setup_printer_and_lan() {
    log_info "Enabling Office Printing (CUPS) & Local Network mDNS Discovery (Avahi)..."
    unlock_steamos

    if systemctl list-unit-files cups.service &>/dev/null; then
        sudo systemctl enable --now cups.service 2>/dev/null || true
        log_ok "CUPS Printing Service enabled (ready for USB/Wi-Fi printers & PDF printing)."
    fi

    if systemctl list-unit-files avahi-daemon.service &>/dev/null; then
        sudo systemctl enable --now avahi-daemon.service 2>/dev/null || true
        log_ok "Avahi mDNS Local Network Discovery enabled (.local devices & AirPrint)."
    fi
}

run_all_pc_optimizations() {
    tune_kernel_ram_network
    optimize_rootfs_and_pacman
    setup_distrobox_podman
    optimize_desktop_ergonomics
    setup_printer_and_lan
    echo ""
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${GREEN}   HOÀN TẤT TỐI ƯU HÓA STEAMOS THÀNH PC WORKSTATION!                 ${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    echo -e " - ${GREEN}Kernel & Network:${NC} TCP BBR + FastQueue + ZRAM Swappiness=100 + IDE Watchers (524,288)"
    echo -e " - ${GREEN}Rootfs & Pacman:${NC}  ParallelDownloads=10 + Dọn rác journal/cache bảo vệ ổ / 5GB"
    echo -e " - ${GREEN}Dev Containers:${NC}   Rootless Podman & Distrobox lưu trên /home (~300GB trống)"
    echo -e " - ${GREEN}Chuyển chế độ Boot:${NC} Gõ ${YELLOW}isteamos-boot-mode desktop${NC} (vào thẳng PC) hoặc ${YELLOW}gaming${NC}"
    echo -e " - ${GREEN}Máy in & LAN:${NC}     Dịch vụ máy in CUPS & tìm kiếm mạng nội bộ Avahi đã bật"
    echo -e "${CYAN}======================================================================${NC}"
}

if [[ "$1" == "--all" || "$1" == "--auto" ]]; then
    run_all_pc_optimizations
    exit 0
fi

echo -e "  ${GREEN}[1]${NC} Run All PC Workstation Optimizations (Recommended)"
echo -e "  ${GREEN}[2]${NC} Tune Kernel, RAM/ZRAM, IDE Watchers & TCP BBR Network Only"
echo -e "  ${GREEN}[3]${NC} Optimize 5GB Rootfs (/) Space & Pacman ParallelDownloads Only"
echo -e "  ${GREEN}[4]${NC} Configure Rootless Podman & Distrobox on /home Only"
echo -e "  ${GREEN}[5]${NC} Enable Office Printing (CUPS) & Local LAN Discovery (Avahi) Only"
echo -e "  ${GREEN}[6]${NC} Switch Default Boot Mode: Boot directly into KDE Desktop PC Mode"
echo -e "  ${GREEN}[7]${NC} Switch Default Boot Mode: Boot into Steam Handheld Gaming Mode"
echo -e "  ${GREEN}[8]${NC} Enable SSH Server (sshd) for Remote PC Access"
echo -e "  ${GREEN}[0]${NC} Back / Exit"
echo ""
read -rp "Select option [0-8]: " PC_OPT

case "$PC_OPT" in
    1) run_all_pc_optimizations ;;
    2) tune_kernel_ram_network ;;
    3) optimize_rootfs_and_pacman ;;
    4) setup_distrobox_podman ;;
    5) setup_printer_and_lan ;;
    6)
        optimize_desktop_ergonomics
        "$HOME/.local/bin/isteamos-boot-mode" desktop
        ;;
    7)
        optimize_desktop_ergonomics
        "$HOME/.local/bin/isteamos-boot-mode" gaming
        ;;
    8)
        sudo systemctl enable --now sshd.service
        log_ok "SSH Server (sshd) enabled and started."
        ;;
    *)
        log_info "Exiting PC Workstation Optimizer."
        ;;
esac
