#!/usr/bin/env bash
set -e

echo "=== SteamOS Post-Install Script (FULL) ==="

### 1. Disable SteamOS readonly

sudo steamos-readonly disable

### 2. Sync pacman

sudo pacman -Sy --noconfirm

### 3. Install Homebrew

if ! command -v brew >/dev/null 2>&1; then
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL [https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh](https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh))"
fi

### 4. neofetch via brew

brew install neofetch || true

### 5. Flatpak apps

flatpak install -y flathub com.visualstudio.code
flatpak install -y flathub com.microsoft.Edge

### 6. fcitx5 + Unikey

sudo pacman -S --noconfirm fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt fcitx5-unikey

mkdir -p ~/.config/environment.d
cat <<EOF > ~/.config/environment.d/fcitx5.conf
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF

mkdir -p ~/.config/autostart
cp /usr/share/applications/org.fcitx.Fcitx5.desktop ~/.config/autostart/ || true

### 7. Decky Loader

curl -L [https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh](https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh) | sh

### 8. SimpleDeckyTDP

curl -L [https://github.com/aarron-lee/SimpleDeckyTDP/raw/main/install.sh](https://github.com/aarron-lee/SimpleDeckyTDP/raw/main/install.sh) | sh

### 9. DeckyWARP

bash <(curl -s [https://raw.githubusercontent.com/Kit1112/DeckyWARP/main/InstallPlugin.sh](https://raw.githubusercontent.com/Kit1112/DeckyWARP/main/InstallPlugin.sh))

### 10. Fix Gaming Mode color (force SDR)

cat <<EOF > ~/.config/environment.d/gamescope.conf
GAMESCOPE_FORCE_HDR=0
EOF

rm -rf ~/.cache/gamescope || true

echo "=== DONE ==="
echo "PLEASE REBOOT SYSTEM"
