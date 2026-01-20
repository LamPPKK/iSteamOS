# SteamOS Post Install – All in One

Cài lại SteamOS → clone repo → chạy 1 lệnh là xong.

Hỗ trợ:

* Steam Deck
* ROG Ally
* SteamOS + màn hình rời

---

## 🚀 Cài FULL

```bash
git clone https://github.com/YOUR_USERNAME/steamos-postinstall.git
cd steamos-postinstall
chmod +x install_steamos.sh
./install_steamos.sh
```

➡️ **Reboot sau khi cài**

---

## 📦 CÀI RIÊNG TỪNG PHẦN

### 🍺 Homebrew + neofetch

```bash
sudo steamos-readonly disable
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install neofetch
```

---

### 📦 Flatpak (VS Code + Edge)

```bash
flatpak install -y flathub com.visualstudio.code
flatpak install -y flathub com.microsoft.Edge
```

---

### ⌨️ fcitx5 + Unikey (fix không gõ được GUI)

```bash
sudo pacman -S fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt fcitx5-unikey

mkdir -p ~/.config/environment.d
cat <<EOF > ~/.config/environment.d/fcitx5.conf
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF

mkdir -p ~/.config/autostart
cp /usr/share/applications/org.fcitx.Fcitx5.desktop ~/.config/autostart/

reboot
```

---

### 🎮 Decky Loader

```bash
curl -L https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh | sh
```

---

### ⚡ SimpleDeckyTDP

```bash
curl -L https://github.com/aarron-lee/SimpleDeckyTDP/raw/main/install.sh | sh
```

---

### ☁️ DeckyWARP (Cloudflare WARP)

```bash
bash <(curl -s https://raw.githubusercontent.com/Kit1112/DeckyWARP/main/InstallPlugin.sh)
```

⚠️ Có thể **không hoạt động trên Wi-Fi enterprise**.

---

### 🎨 Fix màn hình rời bị tối ở Gaming Mode

```bash
mkdir -p ~/.config/environment.d
cat <<EOF > ~/.config/environment.d/gamescope.conf
GAMESCOPE_FORCE_HDR=0
EOF

rm -rf ~/.cache/gamescope
reboot
```

---

## ❌ KHÔNG BAO GỒM

* Set DNS 1.1.1.1
* Cloudflare WARP hệ thống
* VPN bắt buộc

---

## 🧪 CHECK SAU CÀI

```bash
neofetch
fcitx5-remote
flatpak list
```

Gaming Mode:

* Decky Loader hoạt động
* SimpleDeckyTDP OK
* DeckyWARP (nếu dùng)
* Không bị ngả màu

---

## 📜 LICENSE

MIT – Use at your own risk
