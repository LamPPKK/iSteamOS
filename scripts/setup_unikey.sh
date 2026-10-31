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

log "Configuring Fcitx5 and Unikey for ASUS ROG Ally Z1"

# Check if Fcitx5 or Unikey packages are missing
if ! command -v fcitx5 >/dev/null 2>&1 || ! pacman -Q fcitx5-unikey >/dev/null 2>&1; then
    printf 'Fcitx5 or Unikey package is missing. Installing via pacman...\n'
    was_readonly=0
    if sudo steamos-readonly status 2>&1 | grep -qi 'enabled'; then
        sudo steamos-readonly disable
        was_readonly=1
    fi

    sudo pacman -S --needed --noconfirm \
        fcitx5 \
        fcitx5-configtool \
        fcitx5-gtk \
        fcitx5-qt \
        fcitx5-unikey

    if (( was_readonly )); then
        sudo steamos-readonly enable
    fi
else
    printf 'Fcitx5 and fcitx5-unikey packages are already installed.\n'
fi

# Environment configuration
mkdir -p "$HOME/.config/environment.d"
fcitx_env="$HOME/.config/environment.d/fcitx5.conf"
if [[ ! -f "$fcitx_env" ]]; then
    printf 'Creating %s...\n' "$fcitx_env"
    cat > "$fcitx_env" <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF
fi

# Autostart configuration
mkdir -p "$HOME/.config/autostart"
fcitx_autostart="$HOME/.config/autostart/org.fcitx.Fcitx5.desktop"
if [[ ! -e "$fcitx_autostart" && -f /usr/share/applications/org.fcitx.Fcitx5.desktop ]]; then
    printf 'Creating autostart entry %s...\n' "$fcitx_autostart"
    install -m 0644 /usr/share/applications/org.fcitx.Fcitx5.desktop "$fcitx_autostart"
fi

# Profile configuration (US + Unikey)
mkdir -p "$HOME/.config/fcitx5"
fcitx_profile="$HOME/.config/fcitx5/profile"
if [[ ! -e "$fcitx_profile" ]]; then
    printf 'Creating default Fcitx5 profile with Unikey...\n'
    cat > "$fcitx_profile" <<'EOF'
[Groups/0]
# Group Name
Name=Default
# Layout
Default Layout=us
# Default Input Method
DefaultIM=keyboard-us

[Groups/0/Items/0]
# Name
Name=keyboard-us
# Layout
Layout=

[Groups/0/Items/1]
# Name
Name=unikey
# Layout
Layout=

[GroupOrder]
0=Default
EOF
fi

# Start Fcitx5 daemon if in a desktop session and not currently running
if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    if ! pgrep -x fcitx5 >/dev/null 2>&1; then
        printf 'Starting Fcitx5 daemon...\n'
        fcitx5 -d >/dev/null 2>&1 || true
    fi
fi

log "Fcitx5 and Unikey configuration verified"
