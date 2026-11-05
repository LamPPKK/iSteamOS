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

# Ignore DHCP router DNS (e.g. 192.168.1.1) on active Ethernet/Wi-Fi connections so ISP DNS never leaks
if command -v nmcli >/dev/null 2>&1; then
    while IFS= read -r conn; do
        [[ -n "$conn" ]] || continue
        sudo nmcli connection modify "$conn" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes 2>/dev/null || true
    done < <(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2 ~ /ethernet|wireless/ {print $1}')
fi

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

# 3. Enable and configure WARP daemon (WireGuard + tunnel_only + Split Tunnel Exclude for Facebook/Messenger)
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

    printf 'Configuring Cloudflare WARP (WireGuard + tunnel_only mode)...\n'
    warp-cli tunnel protocol set WireGuard >/dev/null 2>&1 || true
    warp-cli mode tunnel_only >/dev/null 2>&1 || warp-cli mode warp >/dev/null 2>&1 || true

    printf 'Excluding Meta/Facebook/Messenger IP ranges from WARP tunnel for direct native speed...\n'
    fb_cidrs=(
        "157.240.0.0/16"
        "31.13.24.0/21"
        "31.13.64.0/18"
        "66.220.144.0/20"
        "69.63.176.0/20"
        "69.171.224.0/19"
        "173.252.64.0/18"
        "179.60.192.0/22"
        "185.60.216.0/22"
        "129.134.0.0/17"
        "45.64.40.0/22"
        "2a03:2880::/32"
    )
    for cidr in "${fb_cidrs[@]}"; do
        warp-cli tunnel ip add-range "$cidr" >/dev/null 2>&1 || true
    done

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
    "  2. Traffic is tunneled via Cloudflare WARP (WireGuard + tunnel_only) for Steam & LinkedIn." \
    "  3. Facebook & Messenger IPv4/IPv6 ranges are excluded (Split Tunnel) for direct native speed." \
    "  4. In Steam -> Settings -> Downloads, set 'Download Region' to 'Singapore' or 'Hong Kong'."

log "Cloudflare WARP & DNS-over-TLS Fix applied successfully"
