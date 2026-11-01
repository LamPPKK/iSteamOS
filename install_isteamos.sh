#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly_changed=0
temp_dir=""
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

LOG_FILE="/tmp/isteamos_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    printf '\n=== %s ===\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
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
        sudo steamos-readonly enable
        if (( $? != 0 && exit_code == 0 )); then
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
        log "Disabling SteamOS readonly mode temporarily"
        sudo steamos-readonly disable
        readonly_changed=1
    elif ! grep -qi 'disabled' <<< "$readonly_status"; then
        die "Could not determine SteamOS readonly status: $readonly_status"
    fi
}

setup_base_system() {
    log "Enabling SteamOS developer mode"
    sudo steamos-devmode enable --no-prompt

    if command -v steamos-unminimize >/dev/null 2>&1; then
        log "Restoring development files removed from the SteamOS image"
        sudo steamos-unminimize --dev --noconfirm
    fi

    log "Updating system packages and installing prerequisites"
    sudo pacman -Syu --needed --noconfirm \
        base-devel \
        procps-ng \
        curl \
        file \
        git \
        jq \
        7zip \
        unzip \
        fcitx5 \
        fcitx5-configtool \
        fcitx5-gtk \
        fcitx5-qt \
        fcitx5-unikey \
        kwallet \
        kwallet-pam \
        kwalletmanager \
        libsecret
}

setup_tools() {
    local helper="$SCRIPT_DIR/scripts/setup_tools.sh"
    [[ -x "$helper" ]] || die "Missing executable helper: $helper"
    "$helper"
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
        local gamescope_backup="${gamescope_config}.bak.$(date +%Y%m%d-%H%M%S)"
        mv -- "$gamescope_config" "$gamescope_backup"
        printf 'Moved unsupported legacy Gamescope setting to %s\n' "$gamescope_backup"
    fi
}

setup_cloudflare_warp_and_dns() {
    local helper="$SCRIPT_DIR/scripts/fix_steam_vietnam.sh"
    [[ -x "$helper" ]] || die "Missing executable helper: $helper"
    "$helper"
}

run_full_installation() {
    log "STARTING FULL INSTALLATION (SteamOS Post Install – All in One)"
    disable_readonly_if_needed
    setup_base_system
    restore_readonly

    setup_tools
    setup_fcitx5_unikey
    setup_decky_components
    setup_cloudflare_warp_and_dns

    log "FULL INSTALLATION COMPLETED"
    printf '%s\n' \
        "Please reboot the system, and open KWalletManager once to create or unlock kdewallet." \
        "Fcitx5 Unikey, Decky Loader, SimpleDeckyTDP, and Cloudflare WARP are preconfigured."
}

show_menu() {
    clear 2>/dev/null || true
    cat <<'EOF'
===================================================================
                 SteamOS Post Install – All in One
===================================================================
  [1] Full Installation (All-in-One - Recommended)
      • Dev Mode, Base Packages, Brave, Homebrew (fastfetch, gh)
      • Google Antigravity (IDE & CLI), VS Code, Android Studio, Edge, Chrome
      • GitHub Desktop, Postman, Insomnia, draw.io, FileZilla, LibreOffice
      • Zalo for Linux, LinuxViewer (UltraViewer), Discord, Telegram, Viber, Signal, Slack, Zoom
      • Spotify, VLC, OBS Studio, Parsec, LocalSend, Nextcloud, Proton VPN, OpenBubbles, Proton Mail
      • Fcitx5-Unikey Vietnamese Input (Autostart & Preconfigured)
      • Decky Loader + SimpleDeckyTDP (Ryzen Z1 / Handhelds) + DeckyWARP
      • Cloudflare WARP & DNS Fix (Bypass Vietnam Steam Block)

  [2] Fix Steam in Vietnam (Cloudflare WARP & DNS Fix)
      • Set fallback DNS to 1.1.1.1 / 8.8.8.8
      • Enable, register & connect Cloudflare WARP
      • Fix "Content Servers Unreachable" error in Steam

  [3] Install Vietnamese IME (Fcitx5 + Unikey Only)
      • Install packages, autostart on boot, Telex Unicode & KWin integration

  [4] Install Decky Components & TDP Control
      • Decky Loader v3.3.1 + SimpleDeckyTDP v1.0.7 + DeckyWARP

  [5] Install Apps, Browsers & Developer Tools Only
      • Complete application suite (Flatpaks, Browsers, Dev Tools & Keyrings)

  [0] Exit
===================================================================
EOF
    printf 'Please enter your choice [0-5]: '
}

# --- Main Entrypoint ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    printf 'Usage: %s [--all | --steam-fix | --unikey | --decky | --tools]\n' "$(basename "$0")"
    exit 0
fi

(( EUID != 0 )) || die "Run this script as your normal SteamOS user, not as root."

for required_command in sudo steamos-devmode steamos-readonly pacman flatpak curl mktemp grep sha256sum; do
    require_command "$required_command"
done

sudo -v
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/isteamos.XXXXXX")"

action="${1:-}"

if [[ -z "$action" ]]; then
    show_menu
    read -r choice
    case "$choice" in
        1) action="--all" ;;
        2) action="--steam-fix" ;;
        3) action="--unikey" ;;
        4) action="--decky" ;;
        5) action="--tools" ;;
        0|q|Q)
            printf '\nExiting without changes.\n'
            exit 0
            ;;
        *)
            printf '\nInvalid choice: %s\n' "$choice" >&2
            exit 1
            ;;
    esac
fi

case "$action" in
    --all|-1)
        run_full_installation
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
        setup_tools
        ;;
    --help|-h)
        printf 'Usage: %s [--all | --steam-fix | --unikey | --decky | --tools]\n' "$(basename "$0")"
        exit 0
        ;;
    *)
        printf 'Unknown option: %s\n' "$action" >&2
        printf 'Usage: %s [--all | --steam-fix | --unikey | --decky | --tools]\n' "$(basename "$0")"
        exit 1
        ;;
esac

printf '\nOperation finished successfully. Press Enter to close...\n'
read -r
