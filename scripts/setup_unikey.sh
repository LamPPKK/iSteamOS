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

log "Configuring Fcitx5 and Unikey"

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
cat > "$fcitx_env" <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
EOF

# Autostart configuration
mkdir -p "$HOME/.config/autostart"
fcitx_autostart="$HOME/.config/autostart/org.fcitx.Fcitx5.desktop"
cat > "$fcitx_autostart" <<'EOF'
[Desktop Entry]
Name=Fcitx 5
GenericName=Input Method
Comment=Start Input Method
Exec=/usr/bin/fcitx5 -d
Icon=fcitx
Terminal=false
Type=Application
Categories=System;Utility;
StartupNotify=false
X-GNOME-AutoRestart=true
X-GNOME-Autostart-Notify=false
X-KDE-autostart-after=panel
X-KDE-StartupNotify=false
X-KDE-Wayland-VirtualKeyboard=true
EOF
chmod +x "$fcitx_autostart"

# KDE Plasma 6 Wayland Input Method integration
if command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig6 --file kwinrc --group Wayland --key InputMethod /usr/share/applications/org.fcitx.Fcitx5.desktop || true
fi

# Profile configuration (Unikey as DefaultIM)
mkdir -p "$HOME/.config/fcitx5"
fcitx_profile="$HOME/.config/fcitx5/profile"
cat > "$fcitx_profile" <<'EOF'
[Groups/0]
# Group Name
Name=Default
# Layout
Default Layout=us
# Default Input Method
DefaultIM=unikey

[Groups/0/Items/0]
# Name
Name=unikey
# Layout
Layout=

[Groups/0/Items/1]
# Name
Name=keyboard-us
# Layout
Layout=

[GroupOrder]
0=Default
EOF

# Fcitx5 Global Configuration (Active by default, shared input state)
fcitx_config="$HOME/.config/fcitx5/config"
cat > "$fcitx_config" <<'EOF'
[Hotkey]
EnumerateWithTriggerKeys=True
EnumerateForwardKeys=
EnumerateBackwardKeys=
EnumerateSkipFirst=False

[Hotkey/TriggerKeys]
0=Control+Shift+Shift_L
1=Control+space

[Hotkey/AltTriggerKeys]
0=Shift_L

[Hotkey/EnumerateGroupForwardKeys]
0=Super+space

[Behavior]
ActiveByDefault=True
ShareInputState=All
PreeditEnabledByDefault=True
ShowInputMethodInformation=True
CompactInputMethodInformation=True
ShowFirstInputMethodInformation=True
DefaultPageSize=5
PreloadInputMethod=True
AutoSavePeriod=30
EOF

# Unikey specific configuration
mkdir -p "$HOME/.config/fcitx5/conf"
cat > "$HOME/.config/fcitx5/conf/unikey.conf" <<'EOF'
InputMethod=Telex
OutputCharset=Unicode
SpellCheck=False
AutoRestoreKeys=True
ModernStyle=True
EOF

# Start/Reload Fcitx5 daemon if in a desktop session
if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    if ! pgrep -x fcitx5 >/dev/null 2>&1; then
        printf 'Starting Fcitx5 daemon...\n'
        fcitx5 -d >/dev/null 2>&1 || true
    else
        fcitx5-remote -r >/dev/null 2>&1 || true
        fcitx5-remote -s unikey >/dev/null 2>&1 || true
    fi
fi

log "Fcitx5 and Unikey configuration verified and set to active by default"

