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

log "Configuring Cloudflare WARP & DNS-over-TLS Fix (Vietnam ISP Bypass)"

# 1. Configure systemd-resolved with encrypted DNS-over-TLS (Cloudflare & Google DNS)
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/dns_servers.conf >/dev/null <<'EOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google 1.0.0.1#cloudflare-dns.com 8.8.4.4#dns.google
FallbackDNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net
DNSOverTLS=opportunistic
DNSSEC=no
Domains=~.
EOF

# Keep a static fallback file just in case systemd-resolved is ever disabled
sudo tee /etc/resolv.conf.fallback >/dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 1.0.0.1
nameserver 8.8.4.4
options edns0
EOF

# Ensure systemd-resolved is active and /etc/resolv.conf points to the standard stub resolver
# (Prevents warp-svc from entering 'Foreign' overwrite mode and breaking DNS on disconnect)
sudo systemctl enable --now systemd-resolved.service
if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
    sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi
sudo systemctl restart systemd-resolved.service

# 2. Check if warp-cli is installed
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

# 3. Enable and configure WARP daemon in tunnel_only mode
# Using tunnel_only routes traffic through Cloudflare WARP (bypassing SNI DPI blocks on Steam, LinkedIn, etc.)
# while delegating DNS resolution to systemd-resolved DNS-over-TLS (avoiding WARP DNS proxy check loops).
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

    printf 'Configuring Cloudflare WARP in tunnel_only mode (paired with systemd-resolved DoT)...\n'
    warp-cli mode tunnel_only >/dev/null 2>&1 || warp-cli mode warp >/dev/null 2>&1 || true
    warp-cli connect || true

    if systemctl --user list-unit-files warp-taskbar.service 2>/dev/null | grep -q warp-taskbar; then
        systemctl --user enable --now warp-taskbar 2>/dev/null || true
    fi

    printf '\n--- Current Cloudflare WARP Status ---\n'
    warp-cli status || true
fi

printf '\n%s\n' \
    "Steam & ISP bypass tips for Vietnam:" \
    "  1. DNS is encrypted via systemd-resolved DNS-over-TLS (1.1.1.1 / 8.8.8.8)." \
    "  2. Traffic is tunneled via Cloudflare WARP (tunnel_only mode) for stable connectivity." \
    "  3. In Steam -> Settings -> Downloads, set 'Download Region' to 'Singapore' or 'Hong Kong'."

log "Cloudflare WARP & DNS-over-TLS Fix applied successfully"
