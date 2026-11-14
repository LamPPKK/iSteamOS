#!/usr/bin/env bash
# ==============================================================================
# Module: iSteamOS System Doctor & PC Workstation Health Check (system_doctor.sh)
# Description: Comprehensive diagnostics for SteamOS running as a full PC & Handheld
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

GREEN='\033[1;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RED='\033[1;31m'
NC='\033[0m'

ok_badge()   { printf '  %b[PASS]%b %s\n' "$GREEN" "$NC" "$1"; }
warn_badge() { printf '  %b[WARN]%b %s\n' "$YELLOW" "$NC" "$1"; }
fail_badge() { printf '  %b[FAIL]%b %s\n' "$RED" "$NC" "$1"; }
info_badge() { printf '  %b[INFO]%b %s\n' "$BLUE" "$NC" "$1"; }

printf '%b======================================================================%b\n' "$CYAN" "$NC"
printf '%b   [System Doctor] iSteamOS PC Workstation & Handheld Diagnostics     %b\n' "$GREEN" "$NC"
printf '%b======================================================================%b\n\n' "$CYAN" "$NC"

# 1. Hardware & OS Overview
printf '%b1. Hardware & Operating System:%b\n' "$YELLOW" "$NC"
CPU_MODEL="$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | xargs || true)"
CPU_MODEL="${CPU_MODEL:-Unknown CPU}"
KERNEL_VER="$(uname -r)"
MEM_TOTAL="$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}' || true)"
MEM_TOTAL="${MEM_TOTAL:-Unknown}"
ZRAM_TOTAL="$(free -h 2>/dev/null | awk '/^Swap:/ {print $2}' || true)"
ZRAM_TOTAL="${ZRAM_TOTAL:-0B}"
info_badge "CPU: ${CPU_MODEL} | Kernel: ${KERNEL_VER}"
info_badge "Memory: ${MEM_TOTAL} RAM | Swap/ZRAM: ${ZRAM_TOTAL}"

ROOT_FREE="$(df -h / | awk 'NR==2 {print $4 " free (" $5 " used)"}' || true)"
HOME_FREE="$(df -h /home | awk 'NR==2 {print $4 " free (" $5 " used)"}' || true)"
info_badge "Disk Space -> Root (/): ${ROOT_FREE:-Unknown} | Home (/home): ${HOME_FREE:-Unknown}"
printf '\n'

# 2. PC Workstation Kernel & Network Tuning
printf '%b2. PC Workstation Kernel & Performance Tuning:%b\n' "$YELLOW" "$NC"
TCP_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")"
if [[ "$TCP_CC" == "bbr" ]]; then
    ok_badge "TCP Congestion Control: BBR active (High-speed & low-latency network)"
else
    warn_badge "TCP Congestion Control: ${TCP_CC} (Run option [6] to enable BBR)"
fi

INOTIFY_WATCHES="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo "0")"
if [[ "$INOTIFY_WATCHES" =~ ^[0-9]+$ ]] && (( INOTIFY_WATCHES >= 524288 )); then
    ok_badge "IDE & Cloud File Watchers (inotify): ${INOTIFY_WATCHES}"
else
    warn_badge "IDE & Cloud File Watchers (inotify): ${INOTIFY_WATCHES} (Low for VS Code/OneDrive)"
fi

SWAPPINESS="$(sysctl -n vm.swappiness 2>/dev/null || echo "60")"
info_badge "VM Swappiness (ZRAM optimized): ${SWAPPINESS}"
printf '\n'

# 3. Network, DNS-over-TLS & ISP Bypass
printf '%b3. Network Stability, DNS-over-TLS & ISP Bypass (Steam / LinkedIn / FB):%b\n' "$YELLOW" "$NC"
if [[ -L /etc/resolv.conf ]]; then
    ok_badge "/etc/resolv.conf is a valid systemd-resolved symlink (prevents WARP reconnect loop)"
else
    warn_badge "/etc/resolv.conf is a static file (may cause WARP DNSLookupFailed loop)"
fi

if command -v warp-cli >/dev/null 2>&1; then
    WARP_STATUS="$(warp-cli status 2>/dev/null | awk -F': ' '/Status update/ {print $2}' | xargs || true)"
    WARP_STATUS="${WARP_STATUS:-Unknown}"
    WARP_PROTO="$(warp-cli settings 2>/dev/null | awk -F': ' '/tunnel protocol/ {print $2}' | xargs || true)"
    WARP_PROTO="${WARP_PROTO:-WireGuard}"
    if [[ "$WARP_STATUS" == "Connected" ]]; then
        ok_badge "Cloudflare WARP: ${WARP_STATUS} (Protocol: ${WARP_PROTO})"
    else
        warn_badge "Cloudflare WARP: ${WARP_STATUS} (Protocol: ${WARP_PROTO})"
    fi
else
    warn_badge "Cloudflare WARP (warp-cli) is not installed"
fi

# Live HTTP Checks
STEAM_CODE="$(curl -4 -s -o /dev/null -w "%{http_code}" --max-time 6 https://store.steampowered.com || true)"
STEAM_CODE="${STEAM_CODE:-000}"
LINKEDIN_CODE="$(curl -4 -s -o /dev/null -w "%{http_code}" --max-time 6 https://www.linkedin.com || true)"
LINKEDIN_CODE="${LINKEDIN_CODE:-000}"
FB_CODE="$(curl -4 -s -o /dev/null -w "%{http_code}" --max-time 6 https://www.facebook.com || true)"
FB_CODE="${FB_CODE:-000}"

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
printf '\n'

# 4. Cloud Storage Sync (OneDrive & Google Drive)
printf '%b4. Cloud Storage Sync (OneDrive & Google Drive):%b\n' "$YELLOW" "$NC"
for cmd_pair in \
    "rclone:Rclone Cloud Engine" \
    "rclone-browser:Rclone Browser Qt6 GUI" \
    "onedrive:OneDrive CLI Engine (abraunegg)" \
    "onedriver:OneDriver Native On-Demand FUSE"; do
    cmd_bin="${cmd_pair%%:*}"
    cmd_label="${cmd_pair#*:}"
    if command -v "$cmd_bin" >/dev/null 2>&1; then
        ok_badge "${cmd_label} (${cmd_bin}) installed"
    else
        warn_badge "${cmd_label} (${cmd_bin}) not installed"
    fi
done

if [[ -x "$HOME/Applications/OneDriveGUI.AppImage" ]] || command -v onedrivegui >/dev/null 2>&1; then
    ok_badge "OneDriveGUI Manager installed"
else
    warn_badge "OneDriveGUI Manager not installed"
fi

if command -v pacman >/dev/null 2>&1 && pacman -Q kio-gdrive >/dev/null 2>&1; then
    ok_badge "KDE Dolphin Native Google Drive (kio-gdrive) installed"
else
    warn_badge "KDE Dolphin Native Google Drive (kio-gdrive) not installed"
fi
printf '\n'

# 5. Vietnamese Input, Dev Containers & Desktop Services
printf '%b5. Vietnamese Input, Dev Containers & PC Services:%b\n' "$YELLOW" "$NC"
if command -v fcitx5 >/dev/null 2>&1 && command -v pacman >/dev/null 2>&1 && pacman -Q fcitx5-unikey >/dev/null 2>&1; then
    ok_badge "Vietnamese IME: Fcitx5 + Unikey installed"
else
    warn_badge "Vietnamese IME: Fcitx5 + Unikey missing"
fi

if command -v distrobox >/dev/null 2>&1 && command -v podman >/dev/null 2>&1; then
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

printf '\n'
printf '%b======================================================================%b\n' "$CYAN" "$NC"
printf '%b   System Doctor check completed!                                     %b\n' "$GREEN" "$NC"
printf '%b======================================================================%b\n' "$CYAN" "$NC"
