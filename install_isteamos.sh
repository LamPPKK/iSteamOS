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

run_core_handheld_setup() {
    log "STARTING CORE HANDHELD SETUP (Fix Steam VN + Unikey + Decky)"

    setup_cloudflare_warp_and_dns
    setup_fcitx5_unikey
    setup_decky_components

    log "CORE HANDHELD SETUP COMPLETED"
    printf '%s\n' \
        "Core handheld components installed and configured:" \
        "  • Fix Steam Vietnam (DNS-over-TLS + Cloudflare WARP tunnel_only)" \
        "  • Fcitx5-Unikey Vietnamese Input (Telex Unicode + Wayland autostart)" \
        "  • Decky Loader + SimpleDeckyTDP + DeckyWARP"
}

show_menu() {
    clear 2>/dev/null || true
    cat <<'EOF'
===================================================================
                 SteamOS Post Install – All in One
===================================================================
  [1] Core Handheld Setup (Fix Steam VN + Unikey + Decky - Recommended)
      • Cloudflare WARP & DNS-over-TLS Fix (Bypass Vietnam ISP Block)
      • Fcitx5-Unikey Vietnamese Input (Autostart & Preconfigured)
      • Decky Loader + SimpleDeckyTDP (Ryzen Z1 / Handhelds) + DeckyWARP

  [2] Fix Steam in Vietnam Only (Cloudflare WARP & DNS-over-TLS)
      • Configure systemd-resolved DoT (1.1.1.1 / 8.8.8.8)
      • Enable, register & connect Cloudflare WARP (tunnel_only mode)
      • Bypass ISP blocks on Steam, LinkedIn, etc.

  [3] Install Vietnamese IME Only (Fcitx5 + Unikey)
      • Install packages, autostart on boot, Telex Unicode & KWin integration

  [4] Install Decky Components & TDP Control Only
      • Decky Loader v3.3.1 + SimpleDeckyTDP v1.0.7 + DeckyWARP

  [5] Install Applications, Browsers & Developer Tools (Interactive Menu)
      • Select individual apps (1..32) or install all at once:
        Chrome, Edge (KWallet6 Sync), Brave, Antigravity IDE/CLI, VS Code,
        Android Studio, Zalo, LinuxViewer, Wallpaper Engine KDE6, Discord,
        Telegram, Viber, Spotify, VLC, OBS, Parsec, LocalSend, Homebrew...

  [0] Exit
===================================================================
EOF
    printf 'Please enter your choice [0-5]: '
}

# --- Main Entrypoint ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    printf 'Usage: %s [--core | --steam-fix | --unikey | --decky | --tools | --all]\n' "$(basename "$0")"
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
        1) action="--core" ;;
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
    --core|-1)
        run_core_handheld_setup
        ;;
    --all)
        run_core_handheld_setup
        setup_tools --all
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
    --help|-h)
        printf 'Usage: %s [--core | --steam-fix | --unikey | --decky | --tools | --all]\n' "$(basename "$0")"
        exit 0
        ;;
    *)
        printf 'Unknown option: %s\n' "$action" >&2
        printf 'Usage: %s [--core | --steam-fix | --unikey | --decky | --tools | --all]\n' "$(basename "$0")"
        exit 1
        ;;
esac

printf '\nOperation finished successfully. Press Enter to close...\n'
read -r
