#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

log() {
    printf '\n=== %s ===\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

(( EUID != 0 )) || die "Run this script as your normal SteamOS user, not as root."

log "Configuring Cloudflare WARP & DNS Fix (Steam Vietnam)"

# Configure Fallback DNS (Cloudflare & Google DNS)
sudo tee /etc/resolv.conf.fallback >/dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 1.0.0.1
nameserver 8.8.4.4
options edns0
EOF

if ! systemctl is-active --quiet warp-svc 2>/dev/null; then
    sudo cp -f /etc/resolv.conf.fallback /etc/resolv.conf
fi

# Check if warp-cli is installed
if ! command -v warp-cli >/dev/null 2>&1; then
    warp_installer="$HOME/homebrew/plugins/DeckyWARP/scripts/install-warp.sh"
    if [[ -x "$warp_installer" ]]; then
        sudo "$warp_installer"
    elif pacman -Si cloudflare-warp-bin >/dev/null 2>&1; then
        was_readonly=0
        if sudo steamos-readonly status 2>&1 | grep -qi 'enabled'; then
            sudo steamos-readonly disable
            was_readonly=1
        fi

        sudo pacman -S --needed --noconfirm cloudflare-warp-bin

        if (( was_readonly )); then
            sudo steamos-readonly enable
        fi
    else
        printf 'WARNING: Could not find cloudflare-warp-bin package or installer.\n'
    fi
fi

# Enable and configure WARP daemon
if command -v warp-cli >/dev/null 2>&1; then
    printf 'Enabling and starting warp-svc.service...\n'
    sudo systemctl enable --now warp-svc.service

    for _ in {1..10}; do
        if warp-cli status >/dev/null 2>&1 || systemctl is-active --quiet warp-svc; then
            break
        fi
        sleep 1
    done

    if ! warp-cli registration show >/dev/null 2>&1; then
        printf 'Registering Cloudflare WARP client...\n'
        warp-cli --accept-tos registration new || true
    fi

    printf 'Connecting to Cloudflare WARP...\n'
    warp-cli mode warp+doh >/dev/null 2>&1 || warp-cli mode warp >/dev/null 2>&1 || true
    warp-cli connect || true

    if systemctl --user list-unit-files warp-taskbar.service 2>/dev/null | grep -q warp-taskbar; then
        systemctl --user enable --now warp-taskbar 2>/dev/null || true
    fi

    printf '\n--- Current Cloudflare WARP Status ---\n'
    warp-cli status || true
fi

printf '\n%s\n' \
    "Steam download tips for Vietnam:" \
    "  1. In Steam, go to Settings -> Downloads." \
    "  2. Change 'Download Region' from Vietnam to 'Singapore' or 'Hong Kong'." \
    "  3. Retry any failed downloads in your download queue."

log "Cloudflare WARP & DNS Fix applied successfully"

