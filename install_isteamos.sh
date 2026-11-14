#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly REPO_URL="${ISTEAMOS_REPO_URL:-https://github.com/LamPPKK/iSteamOS}"
readonly REPO_BRANCH="${ISTEAMOS_REPO_BRANCH:-main}"
readonly LOG_FILE="/tmp/isteamos_install.log"

readonly_changed=0
temp_dir=""
SCRIPT_DIR=""

log() {
    printf '\n=== %s ===\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

show_usage() {
    local prog="install_isteamos.sh"
    if [[ -n "${BASH_SOURCE[0]:-}" && -e "${BASH_SOURCE[0]}" ]]; then
        prog="$(basename "${0:-install_isteamos.sh}")"
    fi
    printf 'Usage: %s [--core | --steam-fix | --unikey | --decky | --tools | --uninstall | --pc-mode | --cloud-sync | --doctor | --all]\n' "$prog"
}

restore_readonly() {
    if (( readonly_changed )); then
        log "Restoring SteamOS readonly mode"
        sudo steamos-readonly enable
        readonly_changed=0
    fi
}

cleanup() {
    local exit_code=$?
    trap - EXIT
    set +e

    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf -- "$temp_dir"
    fi

    if (( readonly_changed )); then
        printf '\nRestoring SteamOS readonly mode after an error...\n' >&2
        if ! sudo steamos-readonly enable && (( exit_code == 0 )); then
            exit_code=1
        fi
    fi

    exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

disable_readonly_if_needed() {
    local readonly_status

    readonly_status="$(sudo steamos-readonly status 2>&1 || true)"
    if grep -qi 'enabled' <<< "$readonly_status"; then
        log "Temporarily disabling SteamOS readonly mode"
        sudo steamos-readonly disable
        readonly_changed=1
    elif ! grep -qi 'disabled' <<< "$readonly_status"; then
        die "Could not determine SteamOS readonly status: $readonly_status"
    fi
}

ensure_repo_files() {
    local self_dir=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -e "${BASH_SOURCE[0]}" ]]; then
        self_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -d "$self_dir/scripts" && -f "$self_dir/scripts/setup_tools.sh" ]]; then
            SCRIPT_DIR="$self_dir"
            readonly SCRIPT_DIR
            return 0
        fi
    fi

    log "Bootstrapping iSteamOS repository from $REPO_URL ($REPO_BRANCH)"
    local repo_dir="$temp_dir/repo"
    if command -v git >/dev/null 2>&1; then
        git clone --depth 1 --branch "$REPO_BRANCH" "${REPO_URL}.git" "$repo_dir"
        SCRIPT_DIR="$repo_dir"
    else
        require_command tar
        local archive="$temp_dir/iSteamOS.tar.gz"
        curl -fsSL "${REPO_URL}/archive/refs/heads/${REPO_BRANCH}.tar.gz" -o "$archive"
        tar -xzf "$archive" -C "$temp_dir"
        SCRIPT_DIR="$temp_dir/iSteamOS-${REPO_BRANCH}"
        if [[ ! -d "$SCRIPT_DIR" ]]; then
            local extracted
            for extracted in "$temp_dir"/iSteamOS-*; do
                if [[ -d "$extracted" ]]; then
                    SCRIPT_DIR="$extracted"
                    break
                fi
            done
        fi
    fi

    [[ -d "$SCRIPT_DIR/scripts" && -f "$SCRIPT_DIR/scripts/setup_tools.sh" ]] || \
        die "Failed to bootstrap iSteamOS helper scripts."

    chmod +x "$SCRIPT_DIR/install_isteamos.sh" "$SCRIPT_DIR"/scripts/*.sh
    readonly SCRIPT_DIR
}

setup_tools() {
    local helper="$SCRIPT_DIR/scripts/setup_tools.sh"
    [[ -x "$helper" ]] || die "Missing executable helper: $helper"
    "$helper" "$@"
}

setup_fcitx5_unikey() {
    local helper="$SCRIPT_DIR/scripts/setup_unikey.sh"
    [[ -x "$helper" ]] || die "Missing executable helper: $helper"
    "$helper"
}

setup_decky_components() {
    local helper="$SCRIPT_DIR/scripts/install_decky_components.sh"
    [[ -x "$helper" ]] || die "Missing executable helper: $helper"
    "$helper"

    local gamescope_config="$HOME/.config/environment.d/gamescope.conf"
    local legacy_gamescope_config="$temp_dir/gamescope.conf.legacy"
    printf 'GAMESCOPE_FORCE_HDR=0\n' > "$legacy_gamescope_config"
    if [[ -f "$gamescope_config" ]] && cmp -s "$gamescope_config" "$legacy_gamescope_config"; then
        local gamescope_backup
        gamescope_backup="${gamescope_config}.bak.$(date +%Y%m%d-%H%M%S)"
        mv -- "$gamescope_config" "$gamescope_backup"
        printf 'Moved unsupported legacy Gamescope setting to %s\n' "$gamescope_backup"
    fi
}

setup_cloudflare_warp_and_dns() {
    local helper="$SCRIPT_DIR/scripts/fix_steam_vietnam.sh"
    [[ -x "$helper" ]] || die "Missing executable helper: $helper"
    "$helper"
}

setup_pc_workstation_mode() {
    local helper="$SCRIPT_DIR/scripts/optimize_pc_mode.sh"
    [[ -x "$helper" ]] || die "Missing executable helper: $helper"
    "$helper" "$@"
}

setup_cloud_sync() {
    local helper="$SCRIPT_DIR/scripts/setup_cloud_sync.sh"
    [[ -x "$helper" ]] || die "Missing executable helper: $helper"
    "$helper" "$@"
}

run_system_doctor() {
    local helper="$SCRIPT_DIR/scripts/system_doctor.sh"
    [[ -x "$helper" ]] || die "Missing executable helper: $helper"
    "$helper"
}

run_core_handheld_setup() {
    log "STARTING CORE HANDHELD SETUP (WARP/DoT + Unikey + Decky)"

    setup_cloudflare_warp_and_dns
    setup_fcitx5_unikey
    setup_decky_components

    log "CORE HANDHELD SETUP COMPLETED"
    printf '%s\n' \
        "Core handheld components installed and configured:" \
        "  • Network & ISP Bypass (DNS-over-TLS + Cloudflare WARP WireGuard + Meta Split-Tunnel)" \
        "  • Fcitx5-Unikey Vietnamese Input (Telex Unicode + Wayland autostart)" \
        "  • Decky Loader + SimpleDeckyTDP + DeckyWARP"
}

show_menu() {
    clear 2>/dev/null || true
    cat <<'EOF'
===================================================================
       iSteamOS – Post Install Toolbox All in One
===================================================================
  [1] Core Handheld Setup (Network Fix + Unikey + Decky ONLY)
      • Cloudflare WARP (WireGuard + Meta Split-Tunnel) & DNS-over-TLS
      • Fcitx5-Unikey Vietnamese Input (Autostart & Preconfigured)
      • Decky Loader + SimpleDeckyTDP (Ryzen Z1 / Handhelds) + DeckyWARP

  [2] Network, DNS-over-TLS & Cloudflare WARP Split-Tunnel Only
      • systemd-resolved DoT (1.1.1.1 / 8.8.8.8) + Valid Symlink
      • WARP WireGuard tunnel_only + Direct Meta/Facebook Split-Tunnel

  [3] Install Vietnamese Input Method Only (Fcitx5 + Unikey)
      • Install packages, autostart on boot, Telex Unicode & KWin integration

  [4] Install Decky Components & TDP Control Only
      • Decky Loader v3.3.1 + SimpleDeckyTDP v1.0.7 + DeckyWARP

  [5] App Toolbox: Install & Uninstall Applications (Ghost Spectre Style 1..55)
      • Live [✓] / [ ] status badges, install or uninstall single apps/ranges:
        Chrome, Edge, Brave, Antigravity IDE/CLI, VS Code, Android Studio,
        GitHub Desktop, Postman, Insomnia, Wireshark, draw.io, FileZilla,
        LibreOffice, Distrobox/Podman, Zalo, LinuxViewer, Beeper, Discord,
        Telegram, Viber, Signal, Slack, Zoom, OpenBubbles, Proton Mail,
        Thunderbird, KDE Connect, Spotify, VLC, mpv, OBS, Parsec, NoiseTorch,
        LocalSend, Nextcloud, Proton VPN, WireGuard, OpenVPN, Wallpaper Engine,
        KDE Apps, Homebrew, CLI Suite, OneDrive & Google Drive Sync, Teams,
        Rocket.Chat, WhatsApp/ZapZap, Remmina RDP, GitKraken/Gittyup,
        Motrix/Varia, Ente Auth 2FA, CopyQ, Switcheroo HEIC, Warehouse/Flatseal,
        Gemini CLI/App

  [6] PC Workstation & System Optimizer (Use SteamOS Like a Full PC)
      • Kernel, ZRAM Swappiness, IDE File-Watchers (inotify) & TCP BBR Network
      • SteamOS 5GB Rootfs (/) Space Cleaner & Pacman ParallelDownloads=10
      • Rootless Podman & Distrobox on /home (~300GB+ partition)
      • Boot Mode Switcher (Desktop PC vs Gaming Mode), KWallet6 & CUPS Printer

  [7] Setup Cloud Storage Sync (Microsoft OneDrive & Google Drive)
      • OneDrive: OneDriver (On-Demand FUSE), OneDriveGUI & OneDrive CLI
      • Google Drive: KIO-GDrive (Dolphin Native), Rclone & Rclone Browser Qt6

  [8] System Doctor & PC Mode Health Check (Diagnostics Dashboard)
      • Check CPU/RAM/ZRAM, Disk (/ vs /home), TCP BBR, WARP/DNS/Connectivity,
        Cloud Sync, Dev Containers, Fcitx5, Decky & Printer Services

  [9] Full SteamOS-to-PC Transformation (Core + PC Optimizer + Cloud + All Apps)

  [0] Exit
===================================================================
EOF
    printf 'Please enter your choice [0-9]: '
}

dispatch_action() {
    local action="${1:-}"
    case "$action" in
        --core|-1)
            run_core_handheld_setup
            ;;
        --all|--full-pc|-9)
            run_core_handheld_setup
            setup_pc_workstation_mode --all
            setup_cloud_sync --all
            setup_tools --all
            run_system_doctor
            ;;
        --steam-fix|--warp|-2)
            setup_cloudflare_warp_and_dns
            ;;
        --unikey|-3)
            setup_fcitx5_unikey
            ;;
        --decky|-4)
            setup_decky_components
            ;;
        --tools|--apps|-5)
            shift || true
            setup_tools "$@"
            ;;
        --uninstall|--remove)
            shift || true
            setup_tools --uninstall "$@"
            ;;
        --pc-mode|--pc|--optimize|-6)
            shift || true
            setup_pc_workstation_mode "$@"
            ;;
        --cloud-sync|--cloud|-7)
            shift || true
            setup_cloud_sync "$@"
            ;;
        --doctor|--status|-8)
            run_system_doctor
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$action" >&2
            show_usage
            exit 1
            ;;
    esac
}

main() {
    local had_cli_args=$#
    local action="${1:-}"

    if [[ "$action" == "--help" || "$action" == "-h" ]]; then
        show_usage
        exit 0
    fi

    if [[ ! -t 0 ]] && (: </dev/tty) 2>/dev/null; then
        exec </dev/tty
    fi

    exec > >(tee -a "$LOG_FILE") 2>&1

    (( EUID != 0 )) || die "Run this script as your normal SteamOS user, not as root."

    for required_command in sudo steamos-devmode steamos-readonly pacman flatpak curl mktemp grep sha256sum; do
        require_command "$required_command"
    done

    if [[ "$action" != "--doctor" && "$action" != "--status" && "$action" != "-8" ]]; then
        sudo -v
    fi

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/isteamos.XXXXXX")"
    ensure_repo_files

    if (( had_cli_args > 0 )); then
        dispatch_action "$@"
        return 0
    fi

    local choice
    while true; do
        show_menu
        IFS= read -r choice || break
        case "$choice" in
            1) action="--core" ;;
            2) action="--steam-fix" ;;
            3) action="--unikey" ;;
            4) action="--decky" ;;
            5) action="--tools" ;;
            6) action="--pc-mode" ;;
            7) action="--cloud-sync" ;;
            8) action="--doctor" ;;
            9) action="--all" ;;
            0|q|Q)
                printf '\nExiting without further changes.\n'
                break
                ;;
            *)
                printf '\nInvalid choice: %s\n' "$choice" >&2
                sleep 1
                continue
                ;;
        esac

        dispatch_action "$action"

        if [[ -t 0 && "$action" != "--tools" ]]; then
            printf '\nOperation finished. Press Enter to return to main menu...'
            IFS= read -r || true
        fi
    done
}

main "$@"
