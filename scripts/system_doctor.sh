#!/bin/bash
# ==============================================================================
# Module: iSteamOS System Doctor & PC Workstation Health Check (system_doctor.sh)
# Description: Comprehensive diagnostics for SteamOS running as a full PC & Handheld
# ==============================================================================

set -e

GREEN='\033[1;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RED='\033[1;31m'
NC='\033[0m'

ok_badge()   { echo -e "  ${GREEN}[PASS]${NC} $1"; }
warn_badge() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail_badge() { echo -e "  ${RED}[FAIL]${NC} $1"; }
info_badge() { echo -e "  ${BLUE}[INFO]${NC} $1"; }

echo -e "${CYAN}======================================================================${NC}"
echo -e "${GREEN}   [System Doctor] iSteamOS PC Workstation & Handheld Diagnostics     ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo ""

# 1. Hardware & OS Overview
echo -e "${YELLOW}1. Hardware & Operating System:${NC}"
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d':' -f2 | xargs || echo "Unknown CPU")
KERNEL_VER=$(uname -r)
MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
ZRAM_TOTAL=$(free -h | awk '/^Swap:/ {print $2}')
info_badge "CPU: ${CPU_MODEL} | Kernel: ${KERNEL_VER}"
info_badge "Memory: ${MEM_TOTAL} RAM | Swap/ZRAM: ${ZRAM_TOTAL}"

ROOT_FREE=$(df -h / | awk 'NR==2 {print $4 " free (" $5 " used)"}')
HOME_FREE=$(df -h /home | awk 'NR==2 {print $4 " free (" $5 " used)"}')
info_badge "Disk Space -> Root (/): ${ROOT_FREE} | Home (/home): ${HOME_FREE}"
echo ""

# 2. PC Workstation Kernel & Network Tuning
echo -e "${YELLOW}2. PC Workstation Kernel & Performance Tuning:${NC}"
TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [[ "$TCP_CC" == "bbr" ]]; then
    ok_badge "TCP Congestion Control: BBR active (High-speed & low-latency network)"
else
    warn_badge "TCP Congestion Control: ${TCP_CC} (Run option [6] to enable BBR)"
fi

INOTIFY_WATCHES=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo "0")
if [ "$INOTIFY_WATCHES" -ge 524288 ] 2>/dev/null; then
    ok_badge "IDE & Cloud File Watchers (inotify): ${INOTIFY_WATCHES}"
else
    warn_badge "IDE & Cloud File Watchers (inotify): ${INOTIFY_WATCHES} (Low for VSCode/OneDrive)"
fi

SWAPPINESS=$(sysctl -n vm.swappiness 2>/dev/null || echo "60")
info_badge "VM Swappiness (ZRAM optimized): ${SWAPPINESS}"
echo ""

# 3. Network, DNS-over-TLS & Vietnam ISP Bypass
echo -e "${YELLOW}3. Network Stability, DNS-over-TLS & ISP Bypass (Steam / LinkedIn / FB):${NC}"
if [ -L /etc/resolv.conf ]; then
    ok_badge "/etc/resolv.conf is a valid systemd-resolved symlink (prevents WARP reconnect loop)"
else
    warn_badge "/etc/resolv.conf is a static file (may cause WARP DNSLookupFailed loop)"
fi

if command -v warp-cli &>/dev/null; then
    WARP_STATUS=$(warp-cli status 2>/dev/null | awk -F': ' '/Status update/ {print $2}' | xargs || echo "Unknown")
    WARP_PROTO=$(warp-cli settings 2>/dev/null | awk -F': ' '/tunnel protocol/ {print $2}' | xargs || echo "WireGuard")
    if [[ "$WARP_STATUS" == "Connected" ]]; then
        ok_badge "Cloudflare WARP: ${WARP_STATUS} (Protocol: ${WARP_PROTO})"
    else
        warn_badge "Cloudflare WARP: ${WARP_STATUS} (Protocol: ${WARP_PROTO})"
    fi
else
    warn_badge "Cloudflare WARP (warp-cli) is not installed"
fi

# Live HTTP Checks
STEAM_CODE=$(curl -4 -s -o /dev/null -w "%{http_code}" --max-time 6 https://store.steampowered.com || echo "000")
LINKEDIN_CODE=$(curl -4 -s -o /dev/null -w "%{http_code}" --max-time 6 https://www.linkedin.com || echo "000")
FB_CODE=$(curl -4 -s -o /dev/null -w "%{http_code}" --max-time 6 https://www.facebook.com || echo "000")

if [[ "$STEAM_CODE" =~ ^(200|301|302)$ ]]; then
    ok_badge "Steam Store Connectivity: HTTP ${STEAM_CODE}"
else
    fail_badge "Steam Store Connectivity: HTTP ${STEAM_CODE}"
fi

if [[ "$LINKEDIN_CODE" =~ ^(200|301|302)$ ]]; then
    ok_badge "LinkedIn Connectivity: HTTP ${LINKEDIN_CODE}"
else
    fail_badge "LinkedIn Connectivity: HTTP ${LINKEDIN_CODE}"
fi

if [[ "$FB_CODE" =~ ^(200|301|302)$ ]]; then
    ok_badge "Facebook & Messenger Direct Route: HTTP ${FB_CODE}"
else
    fail_badge "Facebook & Messenger Direct Route: HTTP ${FB_CODE}"
fi
echo ""

# 4. Cloud Storage Sync (OneDrive & Google Drive)
echo -e "${YELLOW}4. Cloud Storage Sync (OneDrive & Google Drive):${NC}"
for cmd_pair in "rclone:Rclone Cloud Engine" "rclone-browser:Rclone Browser Qt6 GUI" "onedrive:OneDrive CLI Engine (abraunegg)" "onedriver:OneDriver Native On-Demand FUSE"; do
    cmd_bin="${cmd_pair%%:*}"
    cmd_label="${cmd_pair#*:}"
    if command -v "$cmd_bin" &>/dev/null; then
        ok_badge "${cmd_label} (${cmd_bin}) installed"
    else
        warn_badge "${cmd_label} (${cmd_bin}) not installed"
    fi
done

if [ -x "$HOME/Applications/OneDriveGUI.AppImage" ] || command -v onedrivegui &>/dev/null; then
    ok_badge "OneDriveGUI Manager installed"
else
    warn_badge "OneDriveGUI Manager not installed"
fi

if pacman -Q kio-gdrive &>/dev/null; then
    ok_badge "KDE Dolphin Native Google Drive (kio-gdrive) installed"
else
    warn_badge "KDE Dolphin Native Google Drive (kio-gdrive) not installed"
fi
echo ""

# 5. Vietnamese Input, Dev Containers & Desktop Services
echo -e "${YELLOW}5. Vietnamese Input, Dev Containers & PC Services:${NC}"
if command -v fcitx5 &>/dev/null && pacman -Q fcitx5-unikey &>/dev/null; then
    ok_badge "Vietnamese IME: Fcitx5 + Unikey installed"
else
    warn_badge "Vietnamese IME: Fcitx5 + Unikey missing"
fi

if command -v distrobox &>/dev/null && command -v podman &>/dev/null; then
    ok_badge "Rootless Containers: Podman + Distrobox ready"
else
    warn_badge "Rootless Containers: Podman / Distrobox missing"
fi

if systemctl is-active --quiet plugin_loader.service 2>/dev/null; then
    ok_badge "Decky Loader (plugin_loader.service): Active & Running"
else
    warn_badge "Decky Loader (plugin_loader.service): Inactive"
fi

if systemctl is-active --quiet cups.service 2>/dev/null; then
    ok_badge "CUPS Office Printing Service: Active & Running"
else
    info_badge "CUPS Office Printing Service: Inactive"
fi

echo ""
echo -e "${CYAN}======================================================================${NC}"
echo -e "${GREEN}   System Doctor check completed!                                     ${NC}"
echo -e "${CYAN}======================================================================${NC}"
