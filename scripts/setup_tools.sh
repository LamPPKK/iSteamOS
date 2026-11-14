#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

temp_dir=""
readonly_changed=0

GREEN='\033[1;32m'
DIM='\033[2m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

FLATPAK_CACHE=""
PACMAN_CACHE=""

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
        if ! sudo steamos-readonly enable && (( exit_code == 0 )); then
            exit_code=1
        fi
    fi

    exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

install_pacman_packages() {
    disable_readonly_if_needed
    sudo pacman -S --needed --noconfirm "$@"
    restore_readonly
}

remove_pacman_packages() {
    local installed_pkgs=()
    local pkg

    for pkg in "$@"; do
        if pacman -Q "$pkg" >/dev/null 2>&1; then
            installed_pkgs+=("$pkg")
        fi
    done

    if (( ${#installed_pkgs[@]} == 0 )); then
        printf 'None of the requested packages are installed.\n'
        return 0
    fi

    disable_readonly_if_needed
    sudo pacman -Rns --noconfirm "${installed_pkgs[@]}" || sudo pacman -R --noconfirm "${installed_pkgs[@]}" || true
    restore_readonly
}

uninstall_flatpak() {
    local app_id=$1
    local removed=0

    if flatpak --user info "$app_id" >/dev/null 2>&1; then
        flatpak --user uninstall -y --delete-data "$app_id" || flatpak --user uninstall -y "$app_id"
        removed=1
    fi
    if flatpak --system info "$app_id" >/dev/null 2>&1; then
        sudo flatpak --system uninstall -y --delete-data "$app_id" || sudo flatpak --system uninstall -y "$app_id"
        removed=1
    fi
    if (( removed == 0 )); then
        printf 'Flatpak %s is not installed.\n' "$app_id"
    fi
}

install_config() {
    local destination=$1
    local staged_file
    local backup_file

    staged_file="$temp_dir/$(basename "$destination").new"

    cat > "$staged_file"
    mkdir -p "$(dirname "$destination")"

    if [[ -f "$destination" ]] && cmp -s "$staged_file" "$destination"; then
        return
    fi

    if [[ -e "$destination" ]]; then
        backup_file="${destination}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a -- "$destination" "$backup_file"
        printf 'Backed up %s to %s\n' "$destination" "$backup_file"
    fi

    install -m 0644 "$staged_file" "$destination"
}

install_or_update_flatpak() {
    local app_id=$1

    if flatpak --user info "$app_id" >/dev/null 2>&1; then
        flatpak --user update -y "$app_id"
    elif flatpak --system info "$app_id" >/dev/null 2>&1; then
        sudo flatpak --system update -y "$app_id"
    else
        flatpak --user remote-add --if-not-exists \
            flathub \
            https://flathub.org/repo/flathub.flatpakrepo
        flatpak --user install -y flathub "$app_id"
    fi
}

configure_flatpak_keyring_access() {
    local app_id=$1

    flatpak override --user \
        --talk-name=org.kde.kwalletd5 \
        --talk-name=org.kde.kwalletd6 \
        --talk-name=org.freedesktop.secrets \
        "$app_id"
}

configure_vscode_password_store() {
    local argv_file="$HOME/.vscode/argv.json"
    local updated_file="$temp_dir/vscode-argv.json"

    mkdir -p "$(dirname "$argv_file")"

    if [[ ! -e "$argv_file" ]]; then
        install_config "$argv_file" <<'EOF'
{
  "password-store": "kwallet5"
}
EOF
    elif jq -e 'type == "object"' "$argv_file" >/dev/null 2>&1; then
        jq '. + {"password-store": "kwallet5"}' "$argv_file" > "$updated_file"
        install_config "$argv_file" < "$updated_file"
    else
        printf '%s\n' \
            "WARNING: $argv_file contains JSON with comments or invalid JSON; leaving it unchanged." \
            'Open VS Code and run "Preferences: Configure Runtime Arguments", then add "password-store": "kwallet5" manually.' >&2
    fi
}

configure_edge_password_store() {
    local config_dir="$HOME/.var/app/com.microsoft.Edge/config"
    local password_store=kwallet5

    if command -v kwalletd6 >/dev/null 2>&1; then
        password_store=kwallet6
    fi

    mkdir -p "$config_dir"
    for flag_filename in "edge-flags.conf" "microsoft-edge-flags.conf"; do
        local flags_file="$config_dir/$flag_filename"
        local updated_file="$temp_dir/$flag_filename"

        if [[ -L "$flags_file" || ( -e "$flags_file" && ! -f "$flags_file" ) ]]; then
            printf 'WARNING: Refusing to replace non-regular Edge flags file: %s\n' "$flags_file" >&2
            continue
        fi

        if [[ -f "$flags_file" ]]; then
            awk -v password_store="$password_store" '
                BEGIN { password_store_written = 0 }
                /^[[:space:]]*--password-store(=|[[:space:]])/ {
                    if (!password_store_written) {
                        print "--password-store=" password_store
                        password_store_written = 1
                    }
                    next
                }
                { print }
                END {
                    if (!password_store_written) {
                        print "--password-store=" password_store
                    }
                }
            ' "$flags_file" > "$updated_file"
        else
            cat > "$updated_file" <<EOF
--password-store=$password_store
--enable-features=WebRTCPipeWireCapturer
EOF
        fi

        install_config "$flags_file" < "$updated_file"
    done
}

configure_chrome_password_store() {
    local flags_file="$HOME/.var/app/com.google.Chrome/config/chrome-flags.conf"
    local updated_file="$temp_dir/chrome-flags.conf"
    local password_store=kwallet5

    if command -v kwalletd6 >/dev/null 2>&1; then
        password_store=kwallet6
    fi

    if [[ -L "$flags_file" || ( -e "$flags_file" && ! -f "$flags_file" ) ]]; then
        printf 'WARNING: Refusing to replace non-regular Chrome flags file: %s\n' "$flags_file" >&2
        return
    fi

    if [[ -f "$flags_file" ]]; then
        awk -v password_store="$password_store" '
            BEGIN { password_store_written = 0 }
            /^[[:space:]]*--password-store(=|[[:space:]])/ {
                if (!password_store_written) {
                    print "--password-store=" password_store
                    password_store_written = 1
                }
                next
            }
            { print }
            END {
                if (!password_store_written) {
                    print "--password-store=" password_store
                }
            }
        ' "$flags_file" > "$updated_file"
    else
        printf '%s\n' "--password-store=$password_store" > "$updated_file"
    fi

    install_config "$flags_file" < "$updated_file"
}

# --- Individual App & Tool Installers (1..55) ---

install_chrome() {
    log "Installing or updating Google Chrome"
    install_or_update_flatpak "com.google.Chrome"
    configure_chrome_password_store
    configure_flatpak_keyring_access "com.google.Chrome"
}

install_edge() {
    log "Installing or updating Microsoft Edge (with KWallet6 Sync Fix)"
    install_or_update_flatpak "com.microsoft.Edge"
    configure_edge_password_store
    configure_flatpak_keyring_access "com.microsoft.Edge"
}

install_brave() {
    log "Installing Brave Browser"
    if ! command -v brave-origin >/dev/null 2>&1 && ! command -v brave >/dev/null 2>&1; then
        disable_readonly_if_needed
        curl -fsS https://dl.brave.com/install.sh | FLAVOR=origin sh || true
        restore_readonly
    else
        printf 'Brave Browser is already installed.\n'
    fi
}

install_antigravity() {
    log "Installing or updating Google Antigravity (IDE & CLI)"
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/512x512/apps"

    local shell_rc="$HOME/.bashrc"
    [[ "${SHELL:-/bin/bash}" == */zsh ]] && shell_rc="$HOME/.zshrc"

    local ide_target_dir="$HOME/.local/share/antigravity-ide"
    if [[ -d "$HOME/Downloads/Antigravity IDE" ]]; then
        log "Relocating Antigravity IDE from Downloads to $ide_target_dir"
        mkdir -p "$ide_target_dir"
        cp -r "$HOME/Downloads/Antigravity IDE/"* "$ide_target_dir/"
        rm -rf "$HOME/Downloads/Antigravity IDE"
    elif [[ ! -d "$ide_target_dir" && -f "$HOME/Downloads/Antigravity IDE.tar.gz" ]]; then
        log "Extracting Antigravity IDE tarball to $ide_target_dir"
        mkdir -p "$ide_target_dir"
        tar -xzf "$HOME/Downloads/Antigravity IDE.tar.gz" -C "$ide_target_dir" --strip-components=1 2>/dev/null || \
        tar -xzf "$HOME/Downloads/Antigravity IDE.tar.gz" -C "$ide_target_dir"
    fi

    if [[ -d "$ide_target_dir" ]]; then
        mkdir -p "$HOME/Applications"
        ln -sfn "$ide_target_dir" "$HOME/Applications/antigravity-ide"

        if [[ -x "$ide_target_dir/bin/antigravity-ide" ]]; then
            ln -sf "$ide_target_dir/bin/antigravity-ide" "$HOME/.local/bin/antigravity-ide"
            ln -sf "$ide_target_dir/bin/antigravity-ide" "$HOME/.local/bin/antigravity"
        elif [[ -x "$ide_target_dir/antigravity-ide" ]]; then
            ln -sf "$ide_target_dir/antigravity-ide" "$HOME/.local/bin/antigravity-ide"
            ln -sf "$ide_target_dir/antigravity-ide" "$HOME/.local/bin/antigravity"
        fi

        local local_logo="$ide_target_dir/resources/app/extensions/agy/img/logo.png"
        if [[ -f "$local_logo" ]]; then
            cp "$local_logo" "$HOME/.local/share/icons/antigravity-ide.png"
            cp "$local_logo" "$HOME/.local/share/icons/hicolor/512x512/apps/antigravity-ide.png"
        fi

        cat <<EOF > "$HOME/.local/share/applications/antigravity-ide.desktop"
[Desktop Entry]
Name=Antigravity IDE
Comment=AI-powered IDE by Google
GenericName=Text Editor
Exec=$HOME/.local/bin/antigravity-ide %F
Icon=antigravity-ide
Type=Application
StartupNotify=true
StartupWMClass=antigravity-ide
Categories=Development;IDE;TextEditor;
MimeType=text/plain;inode/directory;
Actions=new-empty-window;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec=$HOME/.local/bin/antigravity-ide --new-window %F
Icon=antigravity-ide
EOF
        chmod +x "$HOME/.local/share/applications/antigravity-ide.desktop"

        if [[ -d "$HOME/Desktop" ]]; then
            cp "$HOME/.local/share/applications/antigravity-ide.desktop" "$HOME/Desktop/antigravity-ide.desktop"
            chmod +x "$HOME/Desktop/antigravity-ide.desktop"
        fi
    fi

    if ! command -v agy >/dev/null 2>&1; then
        if [[ -x "$HOME/.gemini/bin/agy" ]]; then
            ln -sf "$HOME/.gemini/bin/agy" "$HOME/.local/bin/agy"
        else
            curl -fsSL https://antigravity.google/cli/install.sh | bash || true
            if [[ -x "$HOME/.gemini/bin/agy" && ! -f "$HOME/.local/bin/agy" ]]; then
                ln -sf "$HOME/.gemini/bin/agy" "$HOME/.local/bin/agy"
            fi
        fi
    else
        printf 'Google Antigravity CLI is already installed.\n'
    fi

    for bin_dir in "$HOME/.local/bin" "$HOME/.gemini/bin"; do
        if [[ -d "$bin_dir" ]] && ! grep -Fq "$bin_dir" "$shell_rc" 2>/dev/null; then
            # shellcheck disable=SC2016
            printf '\nexport PATH="%s:$PATH"\n' "$bin_dir" >> "$shell_rc"
        fi
        if [[ -d "$bin_dir" ]] && [[ -f "$HOME/.bash_profile" ]] && ! grep -Fq "$bin_dir" "$HOME/.bash_profile" 2>/dev/null; then
            # shellcheck disable=SC2016
            printf '\nexport PATH="%s:$PATH"\n' "$bin_dir" >> "$HOME/.bash_profile"
        fi
        if [[ -d "$bin_dir" && ":$PATH:" != *":$bin_dir:"* ]]; then
            export PATH="$bin_dir:$PATH"
        fi
    done
}

install_vscode() {
    log "Installing or updating Visual Studio Code"
    install_or_update_flatpak "com.visualstudio.code"
    configure_vscode_password_store
    configure_flatpak_keyring_access "com.visualstudio.code"
}

install_android_studio() {
    log "Installing or updating Android Studio"
    install_or_update_flatpak "com.google.AndroidStudio"
}

install_github_desktop() {
    log "Installing or updating GitHub Desktop"
    install_or_update_flatpak "io.github.shiftey.Desktop"
    configure_flatpak_keyring_access "io.github.shiftey.Desktop"
}

install_postman() {
    log "Installing or updating Postman"
    install_or_update_flatpak "com.getpostman.Postman"
}

install_insomnia() {
    log "Installing or updating Insomnia"
    install_or_update_flatpak "rest.insomnia.Insomnia"
}

install_wireshark() {
    log "Installing or updating Wireshark"
    install_or_update_flatpak "org.wireshark.Wireshark"
}

install_drawio() {
    log "Installing or updating draw.io"
    install_or_update_flatpak "com.jgraph.drawio.desktop"
}

install_filezilla() {
    log "Installing or updating FileZilla"
    install_or_update_flatpak "org.filezillaproject.Filezilla"
}

install_libreoffice() {
    log "Installing or updating LibreOffice"
    install_or_update_flatpak "org.libreoffice.LibreOffice"
}

install_distrobox_podman() {
    log "Installing or updating Distrobox & Podman"
    install_pacman_packages distrobox podman fuse-overlayfs
}

install_or_update_zalo() {
    log "Installing or updating Zalo for Linux (VN-Linux-Family)"
    local zalo_dir="$HOME/Applications"
    local zalo_bin="$zalo_dir/Zalo.AppImage"
    local zalo_tag
    local zalo_url

    mkdir -p "$zalo_dir" "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/512x512/apps"

    zalo_tag="$(curl -fsSL https://github.com/VN-Linux-Family/zalo-for-linux/tags 2>/dev/null | grep -o -E '/VN-Linux-Family/zalo-for-linux/releases/tag/[^"]+' | head -n 1 | sed 's|.*/releases/tag/||' || true)"
    [[ -n "$zalo_tag" ]] || zalo_tag="26.10.20"

    zalo_url="$(curl -fsSL "https://github.com/VN-Linux-Family/zalo-for-linux/releases/expanded_assets/$zalo_tag" 2>/dev/null | grep -o -E '/VN-Linux-Family/zalo-for-linux/releases/download/[^"]+x86_64\.AppImage' | head -n 1 || true)"
    if [[ -n "$zalo_url" ]]; then
        zalo_url="https://github.com$zalo_url"
    else
        zalo_url="https://github.com/VN-Linux-Family/zalo-for-linux/releases/download/$zalo_tag/Zalo-$zalo_tag+ZaDark-26.3-e9f3dc1-x86_64.AppImage"
    fi

    local temp_download="$temp_dir/Zalo.AppImage"
    printf 'Downloading Zalo for Linux (%s)...\n' "$zalo_tag"
    if curl -fsSL -o "$temp_download" "$zalo_url"; then
        chmod +x "$temp_download"
        mv -f "$temp_download" "$zalo_bin"
        ln -sf "$zalo_bin" "$HOME/.local/bin/zalo"

        local extract_dir="$temp_dir/zalo_icon_extract"
        mkdir -p "$extract_dir"
        (
            cd "$extract_dir"
            "$zalo_bin" --appimage-extract "usr/share/icons/hicolor/512x512/apps/zalo.png" >/dev/null 2>&1 || true
        )
        if [[ -f "$extract_dir/squashfs-root/usr/share/icons/hicolor/512x512/apps/zalo.png" ]]; then
            cp -f "$extract_dir/squashfs-root/usr/share/icons/hicolor/512x512/apps/zalo.png" "$HOME/.local/share/icons/zalo.png"
            cp -f "$extract_dir/squashfs-root/usr/share/icons/hicolor/512x512/apps/zalo.png" "$HOME/.local/share/icons/hicolor/512x512/apps/zalo.png"
        fi
        rm -rf "$extract_dir"

        cat <<EOF > "$HOME/.local/share/applications/zalo.desktop"
[Desktop Entry]
Name=Zalo
Comment=Zalo for Linux (Unofficial Desktop Client)
Exec=$zalo_bin %U
Icon=${HOME}/.local/share/icons/zalo.png
Terminal=false
Type=Application
Categories=Network;Chat;InstantMessaging;
StartupWMClass=Zalo
EOF
        chmod +x "$HOME/.local/share/applications/zalo.desktop"
        if [[ -d "$HOME/Desktop" ]]; then
            cp -f "$HOME/.local/share/applications/zalo.desktop" "$HOME/Desktop/zalo.desktop"
            chmod +x "$HOME/Desktop/zalo.desktop"
        fi
        printf 'Zalo for Linux installed successfully at %s\n' "$zalo_bin"
    else
        printf 'WARNING: Failed to download Zalo for Linux.\n' >&2
    fi
}

install_or_update_linuxviewer() {
    log "Installing or updating LinuxViewer (UltraViewer for Linux)"
    local lv_tar="$temp_dir/linuxviewer.tar.gz"
    local lv_extract="$temp_dir/linuxviewer_extract"
    local lv_url="https://github.com/DeanOpen/MacViewer/releases/latest/download/linuxviewer-wayland-x86_64.tar.gz"

    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps" "$lv_extract"

    printf 'Downloading LinuxViewer (Wayland edition)...\n'
    if curl -fsSL -o "$lv_tar" "$lv_url"; then
        tar -xzf "$lv_tar" -C "$lv_extract"
        if [[ -f "$lv_extract/usr/bin/linuxviewer" ]]; then
            cp -f "$lv_extract/usr/bin/linuxviewer" "$HOME/.local/bin/linuxviewer"
            chmod +x "$HOME/.local/bin/linuxviewer"
        fi

        if [[ -f "$lv_extract/usr/share/icons/hicolor/256x256/apps/linuxviewer.png" ]]; then
            cp -f "$lv_extract/usr/share/icons/hicolor/256x256/apps/linuxviewer.png" "$HOME/.local/share/icons/linuxviewer.png"
            cp -f "$lv_extract/usr/share/icons/hicolor/256x256/apps/linuxviewer.png" "$HOME/.local/share/icons/hicolor/256x256/apps/linuxviewer.png"
        fi

        cat <<EOF > "$HOME/.local/share/applications/linuxviewer.desktop"
[Desktop Entry]
Type=Application
Name=LinuxViewer
Comment=UltraViewer-compatible remote desktop
Exec=$HOME/.local/bin/linuxviewer %U
Icon=${HOME}/.local/share/icons/linuxviewer.png
Terminal=false
Categories=Network;RemoteAccess;
Keywords=remote;desktop;ultraviewer;vnc;
EOF
        chmod +x "$HOME/.local/share/applications/linuxviewer.desktop"
        if [[ -d "$HOME/Desktop" ]]; then
            cp -f "$HOME/.local/share/applications/linuxviewer.desktop" "$HOME/Desktop/linuxviewer.desktop"
            chmod +x "$HOME/Desktop/linuxviewer.desktop"
        fi
        printf 'LinuxViewer installed successfully at %s\n' "$HOME/.local/bin/linuxviewer"
    else
        printf 'WARNING: Failed to download LinuxViewer.\n' >&2
    fi
}

install_beeper() {
    log "Installing or updating Beeper Unified Messenger"
    local beeper_dir="$HOME/Applications"
    local beeper_bin="$beeper_dir/Beeper.AppImage"
    mkdir -p "$beeper_dir" "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons"

    local existing_beeper=""
    local candidate
    for candidate in "$HOME/Downloads"/Beeper*.AppImage; do
        if [[ -f "$candidate" ]]; then
            if [[ -z "$existing_beeper" || "$candidate" -nt "$existing_beeper" ]]; then
                existing_beeper="$candidate"
            fi
        fi
    done

    if [[ -n "$existing_beeper" ]]; then
        cp -f -- "$existing_beeper" "$beeper_bin"
        chmod +x "$beeper_bin"
    elif [[ ! -f "$beeper_bin" ]]; then
        printf 'Downloading Beeper AppImage...\n'
        curl -fsSL -L "https://api.beeper.com/desktop/download/linux/x64/stable/com.automattic.beeper.desktop" -o "$beeper_bin" || true
        [[ -f "$beeper_bin" ]] && chmod +x "$beeper_bin"
    fi

    if [[ -x "$beeper_bin" ]]; then
        ln -sf "$beeper_bin" "$HOME/.local/bin/beeper"
        cat <<EOF > "$HOME/.local/share/applications/Beeper.desktop"
[Desktop Entry]
Name=Beeper
Exec=$beeper_bin %u
Type=Application
Terminal=false
Comment=The ultimate messaging app
Categories=Network;Chat;
MimeType=x-scheme-handler/beeper;
StartupWMClass=Beeper
StartupNotify=true
Icon=$HOME/.local/share/icons/beeper.png
EOF
        chmod +x "$HOME/.local/share/applications/Beeper.desktop"
    fi
}

install_discord() {
    log "Installing or updating Discord"
    install_or_update_flatpak "com.discordapp.Discord"
    configure_flatpak_keyring_access "com.discordapp.Discord"
}

install_telegram() {
    log "Installing or updating Telegram Desktop"
    install_or_update_flatpak "org.telegram.desktop"
}

install_viber() {
    log "Installing or updating Viber"
    install_or_update_flatpak "com.viber.Viber"
}

install_signal() {
    log "Installing or updating Signal Desktop"
    install_or_update_flatpak "org.signal.Signal"
    configure_flatpak_keyring_access "org.signal.Signal"
}

install_slack() {
    log "Installing or updating Slack"
    install_or_update_flatpak "com.slack.Slack"
    configure_flatpak_keyring_access "com.slack.Slack"
}

install_zoom() {
    log "Installing or updating Zoom"
    install_or_update_flatpak "us.zoom.Zoom"
}

install_openbubbles() {
    log "Installing or updating OpenBubbles (iMessage Client)"
    install_or_update_flatpak "app.openbubbles.OpenBubbles"
}

install_proton_mail() {
    log "Installing or updating Proton Mail"
    install_or_update_flatpak "me.proton.Mail"
    configure_flatpak_keyring_access "me.proton.Mail"
}

install_thunderbird() {
    log "Installing or updating Mozilla Thunderbird"
    install_or_update_flatpak "org.mozilla.thunderbird"
    configure_flatpak_keyring_access "org.mozilla.thunderbird"
}

install_kdeconnect() {
    log "Installing or updating KDE Connect"
    install_pacman_packages kdeconnect
}

install_spotify() {
    log "Installing or updating Spotify"
    install_or_update_flatpak "com.spotify.Client"
}

install_vlc() {
    log "Installing or updating VLC Media Player"
    install_or_update_flatpak "org.videolan.VLC"
}

install_mpv() {
    log "Installing or updating mpv Media Player & GStreamer Codecs"
    install_pacman_packages mpv gst-libav gst-plugins-good gst-plugins-bad-libs gst-plugin-pipewire ffmpegthumbs
}

install_obs() {
    log "Installing or updating OBS Studio"
    install_or_update_flatpak "com.obsproject.Studio"
}

install_parsec() {
    log "Installing or updating Parsec Game Streaming"
    install_or_update_flatpak "com.parsecgaming.parsec"
}

install_audio_tools() {
    log "Installing or updating NoiseTorch & Pavucontrol (Audio Mixer & Mic Noise Suppression)"
    install_pacman_packages noisetorch pavucontrol alsa-utils
}

install_localsend() {
    log "Installing or updating LocalSend"
    install_or_update_flatpak "org.localsend.localsend_app"
}

install_nextcloud() {
    log "Installing or updating Nextcloud Desktop Client"
    install_or_update_flatpak "com.nextcloud.desktopclient.nextcloud"
}

install_protonvpn() {
    log "Installing or updating Proton VPN"
    install_or_update_flatpak "com.protonvpn.www"
}

install_wireguard() {
    log "Installing WireGuard VPN & Tools (wireguard-tools, wgcf, vortix, wireproxy)"
    install_pacman_packages wireguard-tools wgcf vortix wireproxy

    mkdir -p "$HOME/.config/wgcf" "$HOME/Documents"
    (
        cd "$HOME/.config/wgcf"
        if [[ ! -f wgcf-account.toml ]]; then
            wgcf register --accept-tos || true
        fi
        if [[ -f wgcf-account.toml && ! -f wgcf-profile.conf ]]; then
            wgcf generate || true
        fi
        if [[ -f wgcf-profile.conf ]]; then
            cp -f wgcf-profile.conf "$HOME/Documents/wgcf-wireguard.conf"
            sudo mkdir -p /etc/wireguard
            sudo cp -f wgcf-profile.conf /etc/wireguard/wgcf.conf
            if command -v nmcli >/dev/null 2>&1 && ! nmcli connection show "wgcf" >/dev/null 2>&1; then
                sudo nmcli connection import type wireguard file /etc/wireguard/wgcf.conf || true
                sudo nmcli connection modify "wgcf" connection.autoconnect no || true
                sudo nmcli connection down "wgcf" 2>/dev/null || true
            fi
        fi
    )
}

install_openvpn() {
    log "Installing or updating OpenVPN & NetworkManager Plugin"
    install_pacman_packages openvpn networkmanager-openvpn
}

install_wallpaper_engine() {
    log "Installing or updating Wallpaper Engine KDE 6 Plugin"
    disable_readonly_if_needed

    sudo pacman -S --needed --noconfirm \
        mpv \
        gst-libav \
        gst-plugins-good \
        gst-plugins-bad-libs \
        gst-plugin-pipewire \
        qt6-declarative \
        qt6-websockets \
        qt6-webchannel \
        plasma-desktop \
        libplasma \
        vulkan-icd-loader \
        lz4 \
        python-websockets 2>/dev/null || true

    if ! pacman -Q WallpaperEngine_kde6 >/dev/null 2>&1; then
        local we_pkg="$temp_dir/WallpaperEngine_kde6.pkg.tar.zst"
        local we_url="https://github.com/slynobody/SteamOS-wallpaper-engine-kde-plugin/releases/download/0.98a/WallpaperEngine_kde6-1_1m-1-x86_64.pkg.tar.zst"
        printf 'Downloading Wallpaper Engine KDE 6 package...\n'
        if curl -fsSL -o "$we_pkg" "$we_url"; then
            sudo pacman -U --noconfirm "$we_pkg"
        else
            printf 'WARNING: Failed to download WallpaperEngine_kde6 package.\n' >&2
        fi
    else
        printf 'WallpaperEngine_kde6 is already installed.\n'
    fi

    restore_readonly

    local plasma_applet_rc="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
    local steam_workshop_path="$HOME/.local/share/Steam/steamapps/workshop/content/431960"
    if [[ -d "$steam_workshop_path" && -f "$plasma_applet_rc" ]]; then
        sed -i "s|steamLibraryPath=file://${HOME}/.steam/steam|steamLibraryPath=file://${HOME}/.local/share/Steam|g" "$plasma_applet_rc" 2>/dev/null || true
    fi
}

install_kde_utilities() {
    log "Installing or updating KDE Desktop Utilities (Kate, Okular, Gwenview, Spectacle, Ark, Filelight, PartitionManager, Qrca)"
    install_pacman_packages \
        kate \
        okular \
        gwenview \
        spectacle \
        ark \
        filelight \
        partitionmanager \
        qrca \
        dolphin \
        konsole \
        kwalletmanager
}

install_homebrew() {
    log "Installing or updating Homebrew & CLI Tools (fastfetch, gh, neofetch, node, gemini-cli)"
    local brew_bin
    brew_bin="$(command -v brew || true)"
    if [[ -z "$brew_bin" ]]; then
        for candidate in /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
            if [[ -x "$candidate" ]]; then
                brew_bin=$candidate
                break
            fi
        done
    fi

    if [[ -z "$brew_bin" ]]; then
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        for candidate in /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
            if [[ -x "$candidate" ]]; then
                brew_bin=$candidate
                break
            fi
        done
    fi

    [[ -n "$brew_bin" && -x "$brew_bin" ]] || die "Homebrew was installed but brew could not be found."
    eval "$("$brew_bin" shellenv)"

    local shell_rc="$HOME/.bashrc"
    [[ "${SHELL:-/bin/bash}" == */zsh ]] && shell_rc="$HOME/.zshrc"

    local brew_shellenv_line="eval \"\$($brew_bin shellenv)\""
    touch "$shell_rc"
    if ! grep -Fqx "$brew_shellenv_line" "$shell_rc"; then
        printf '\n%s\n' "$brew_shellenv_line" >> "$shell_rc"
    fi

    brew update
    for formula in fastfetch gh neofetch node gemini-cli; do
        if brew list --formula "$formula" >/dev/null 2>&1; then
            brew upgrade "$formula" || true
        else
            brew install "$formula" || true
        fi
    done
}

install_cli_system_suite() {
    log "Installing or updating System & Developer CLI Suite (paru, btop, htop, ripgrep, fd, tmux, vim, fish, zsh, 7zip, unrar, jq...)"
    install_pacman_packages \
        base-devel \
        paru \
        btop \
        htop \
        iotop \
        nethogs \
        ncdu \
        compsize \
        ripgrep \
        fd \
        tmux \
        vim \
        nano \
        tree \
        jq \
        7zip \
        unrar \
        unzip \
        zip \
        dos2unix \
        fish \
        zsh \
        bash-completion \
        bats \
        gocryptfs \
        sshfs \
        powertop \
        mangohud \
        lib32-mangohud \
        gamemode \
        lib32-gamemode
}

install_cloud_sync_suite() {
    log "Installing OneDrive & Google Drive Cloud Sync Suite"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -x "$script_dir/setup_cloud_sync.sh" ]]; then
        "$script_dir/setup_cloud_sync.sh" --all
    fi
}

install_pc_workstation_optimizer() {
    log "Running SteamOS to PC Workstation Optimizer"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -x "$script_dir/optimize_pc_mode.sh" ]]; then
        "$script_dir/optimize_pc_mode.sh" --all
    fi
}

install_teams() {
    log "Installing or updating Teams for Linux (Microsoft Teams)"
    install_or_update_flatpak "com.github.IsmaelMartinez.teams_for_linux"
    configure_flatpak_keyring_access "com.github.IsmaelMartinez.teams_for_linux"
}

install_rocketchat() {
    log "Installing or updating Rocket.Chat Desktop"
    install_or_update_flatpak "chat.rocket.RocketChat"
    configure_flatpak_keyring_access "chat.rocket.RocketChat"
}

install_whatsapp() {
    log "Installing or updating ZapZap (WhatsApp Desktop)"
    install_or_update_flatpak "com.rtosta.zapzap"
}

install_remmina() {
    log "Installing or updating Remmina Remote Desktop (RDP/VNC/SSH)"
    install_or_update_flatpak "org.remmina.Remmina"
    configure_flatpak_keyring_access "org.remmina.Remmina"
}

install_git_guis() {
    log "Installing or updating Git GUIs (Gittyup & GitKraken)"
    install_or_update_flatpak "com.github.Murmele.Gittyup"
    install_or_update_flatpak "com.axosoft.GitKraken"
    configure_flatpak_keyring_access "com.axosoft.GitKraken"
}

install_download_managers() {
    log "Installing or updating Download Managers (Motrix & Varia)"
    install_or_update_flatpak "net.agalwood.Motrix"
    install_or_update_flatpak "io.github.giantpinkrobots.varia"
}

install_ente_auth() {
    log "Installing or updating Ente Auth (2FA Authenticator)"
    install_or_update_flatpak "io.ente.auth"
    configure_flatpak_keyring_access "io.ente.auth"
}

install_copyq() {
    log "Installing or updating CopyQ Clipboard Manager"
    install_or_update_flatpak "com.github.hluk.copyq"
}

install_heic_converter() {
    log "Installing or updating Switcheroo Image Converter & HEIF/HEIC Support"
    install_or_update_flatpak "io.gitlab.adhami3310.Converter"
    disable_readonly_if_needed
    sudo pacman -S --needed --noconfirm libheif kimageformats 2>/dev/null || true
    restore_readonly
}

install_flatpak_cleaners() {
    log "Installing or updating Warehouse & Flatseal (App Cleaner & Permissions)"
    install_or_update_flatpak "io.github.flattool.Warehouse"
    install_or_update_flatpak "com.github.tchx84.Flatseal"
}

install_gemini() {
    log "Installing or updating Google Gemini CLI & Desktop Launcher"
    local brew_bin=""
    brew_bin="$(command -v brew || true)"
    if [[ -z "$brew_bin" ]]; then
        for candidate in /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
            if [[ -x "$candidate" ]]; then
                brew_bin="$candidate"
                break
            fi
        done
    fi
    if [[ -n "$brew_bin" ]]; then
        eval "$("$brew_bin" shellenv)"
        if brew list --formula gemini-cli >/dev/null 2>&1; then
            brew upgrade gemini-cli || true
        else
            brew install gemini-cli || true
        fi
    elif command -v npm >/dev/null 2>&1; then
        npm install -g @google/gemini-cli || true
    else
        install_homebrew
    fi

    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
    cat <<'EOF' > "$HOME/.local/bin/google-gemini-app"
#!/usr/bin/env bash
set -Eeuo pipefail
if flatpak info com.microsoft.Edge >/dev/null 2>&1; then
    exec flatpak run com.microsoft.Edge --app=https://gemini.google.com
elif flatpak info com.google.Chrome >/dev/null 2>&1; then
    exec flatpak run com.google.Chrome --app=https://gemini.google.com
elif command -v brave-origin >/dev/null 2>&1; then
    exec brave-origin --app=https://gemini.google.com
elif command -v brave >/dev/null 2>&1; then
    exec brave --app=https://gemini.google.com
else
    exec xdg-open https://gemini.google.com
fi
EOF
    chmod +x "$HOME/.local/bin/google-gemini-app"

    cat <<EOF > "$HOME/.local/share/applications/google-gemini.desktop"
[Desktop Entry]
Name=Google Gemini
Comment=Google Gemini AI Desktop Web App
Exec=$HOME/.local/bin/google-gemini-app
Icon=applications-internet
Terminal=false
Type=Application
Categories=Network;Utility;Office;
StartupNotify=true
EOF
    chmod +x "$HOME/.local/share/applications/google-gemini.desktop"
    if [[ -d "$HOME/Desktop" ]]; then
        cp -f "$HOME/.local/share/applications/google-gemini.desktop" "$HOME/Desktop/google-gemini.desktop"
        chmod +x "$HOME/Desktop/google-gemini.desktop"
    fi
}

# --- Individual App & Tool Uninstallers (1..55) ---

uninstall_brave() {
    log "Uninstalling Brave Browser"
    local removed=0
    local pkg
    for pkg in brave-bin brave-origin-bin brave-browser brave-origin; do
        if command -v pacman >/dev/null 2>&1 && pacman -Q "$pkg" >/dev/null 2>&1; then
            remove_pacman_packages "$pkg"
            removed=1
        fi
    done
    if (( removed == 0 )); then
        disable_readonly_if_needed
        sudo rm -rf /opt/brave.com /opt/brave-origin \
            /usr/bin/brave-origin /usr/bin/brave \
            /usr/local/bin/brave-origin /usr/local/bin/brave \
            /usr/share/applications/brave-browser*.desktop 2>/dev/null || true
        rm -rf "$HOME/.local/bin/brave"* "$HOME/.local/share/brave"* \
            "$HOME/.local/share/applications/brave"*.desktop 2>/dev/null || true
        restore_readonly
    fi
}

uninstall_antigravity() {
    log "Uninstalling Google Antigravity (IDE & CLI)"
    rm -rf -- \
        "$HOME/.local/share/antigravity-ide" \
        "$HOME/Applications/antigravity-ide" \
        "$HOME/.local/bin/antigravity-ide" \
        "$HOME/.local/bin/antigravity" \
        "$HOME/.local/bin/agy" \
        "$HOME/.local/share/icons/antigravity-ide.png" \
        "$HOME/.local/share/icons/hicolor/512x512/apps/antigravity-ide.png" \
        "$HOME/.local/share/applications/antigravity-ide.desktop" \
        "$HOME/Desktop/antigravity-ide.desktop"
}

uninstall_zalo() {
    log "Uninstalling Zalo for Linux"
    rm -f -- \
        "$HOME/Applications/Zalo.AppImage" \
        "$HOME/.local/bin/zalo" \
        "$HOME/.local/share/icons/zalo.png" \
        "$HOME/.local/share/icons/hicolor/512x512/apps/zalo.png" \
        "$HOME/.local/share/applications/zalo.desktop" \
        "$HOME/Desktop/zalo.desktop"
}

uninstall_linuxviewer() {
    log "Uninstalling LinuxViewer"
    rm -f -- \
        "$HOME/.local/bin/linuxviewer" \
        "$HOME/.local/share/icons/linuxviewer.png" \
        "$HOME/.local/share/icons/hicolor/256x256/apps/linuxviewer.png" \
        "$HOME/.local/share/applications/linuxviewer.desktop" \
        "$HOME/Desktop/linuxviewer.desktop"
}

uninstall_beeper() {
    log "Uninstalling Beeper Unified Messenger"
    rm -f -- \
        "$HOME/Applications/Beeper.AppImage" \
        "$HOME/.local/bin/beeper" \
        "$HOME/.local/share/applications/Beeper.desktop"
}

uninstall_wireguard() {
    log "Uninstalling WireGuard VPN & Tools"
    if command -v nmcli >/dev/null 2>&1 && nmcli connection show "wgcf" >/dev/null 2>&1; then
        sudo nmcli connection down "wgcf" 2>/dev/null || true
        sudo nmcli connection delete "wgcf" 2>/dev/null || true
    fi
    remove_pacman_packages wireguard-tools wgcf vortix wireproxy
}

uninstall_kde_utilities() {
    log "Uninstalling Extra KDE Utilities (preserving Dolphin & Konsole)"
    remove_pacman_packages \
        kate \
        okular \
        gwenview \
        spectacle \
        ark \
        filelight \
        partitionmanager \
        qrca \
        kwalletmanager
}

uninstall_homebrew() {
    log "Uninstalling Homebrew formulas (fastfetch, gh, neofetch, node, gemini-cli)"
    local brew_bin=""
    brew_bin="$(command -v brew || true)"
    if [[ -z "$brew_bin" ]]; then
        for candidate in /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
            if [[ -x "$candidate" ]]; then
                brew_bin="$candidate"
                break
            fi
        done
    fi
    if [[ -n "$brew_bin" ]]; then
        eval "$("$brew_bin" shellenv)"
        for formula in gemini-cli node neofetch gh fastfetch; do
            if brew list --formula "$formula" >/dev/null 2>&1; then
                brew uninstall "$formula" || true
            fi
        done
    else
        printf 'Homebrew is not installed.\n'
    fi
}

uninstall_cli_system_suite() {
    log "Uninstalling Optional CLI System Suite Packages"
    remove_pacman_packages \
        paru \
        btop \
        htop \
        iotop \
        nethogs \
        ncdu \
        compsize \
        ripgrep \
        fd \
        tmux \
        tree \
        jq \
        unrar \
        dos2unix \
        fish \
        zsh \
        bats \
        gocryptfs \
        sshfs \
        powertop \
        mangohud \
        lib32-mangohud \
        gamemode \
        lib32-gamemode
}

uninstall_cloud_sync_suite() {
    log "Uninstalling OneDrive & Google Drive Cloud Sync Suite"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user disable --now rclone-mount@GoogleDrive.service 2>/dev/null || true
        systemctl --user disable --now rclone-mount@OneDrive.service 2>/dev/null || true
    fi
    rm -f -- \
        "$HOME/Applications/OneDriveGUI.AppImage" \
        "$HOME/.local/share/applications/onedrivegui.desktop" \
        "$HOME/.config/systemd/user/rclone-mount@.service" \
        "$HOME/.local/bin/isteamos-cloud-mount"
    remove_pacman_packages rclone rclone-browser-qt6 kio-gdrive onedrive-abraunegg onedriver
}

uninstall_pc_workstation_optimizer() {
    log "Reverting PC Workstation Optimizer configurations"
    disable_readonly_if_needed
    sudo rm -f /etc/sysctl.d/99-isteamos-pc.conf /etc/modules-load.d/isteamos-bbr.conf
    sudo sysctl --system >/dev/null 2>&1 || true
    restore_readonly
    rm -f -- "$HOME/.local/bin/isteamos-boot-mode" "$HOME/.distroboxrc"
    printf 'PC Workstation sysctl and boot-mode helper reverted (container data preserved).\n'
}

uninstall_gemini() {
    log "Uninstalling Google Gemini CLI & Desktop Launcher"
    local brew_bin=""
    brew_bin="$(command -v brew || true)"
    if [[ -z "$brew_bin" ]]; then
        for candidate in /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
            if [[ -x "$candidate" ]]; then
                brew_bin="$candidate"
                break
            fi
        done
    fi
    if [[ -n "$brew_bin" ]]; then
        eval "$("$brew_bin" shellenv)"
        if brew list --formula gemini-cli >/dev/null 2>&1; then
            brew uninstall gemini-cli || true
        fi
    fi
    if command -v npm >/dev/null 2>&1; then
        npm uninstall -g @google/gemini-cli 2>/dev/null || true
    fi
    rm -f -- \
        "$HOME/.local/bin/google-gemini-app" \
        "$HOME/.local/share/applications/google-gemini.desktop" \
        "$HOME/Desktop/google-gemini.desktop"
}

clean_unused_packages() {
    log "Cleaning Unused Flatpak Runtimes & Pacman Package Cache"
    if command -v flatpak >/dev/null 2>&1; then
        flatpak --user uninstall --unused -y 2>/dev/null || true
        sudo flatpak --system uninstall --unused -y 2>/dev/null || true
    fi
    if command -v pacman >/dev/null 2>&1; then
        disable_readonly_if_needed
        sudo pacman -Sc --noconfirm || true
        restore_readonly
    fi
    log "Cleanup completed"
}

# --- Installed Status Detection & Ghost Spectre Toolbox Renderer ---

refresh_installed_cache() {
    FLATPAK_CACHE=""
    PACMAN_CACHE=""
    if command -v flatpak >/dev/null 2>&1; then
        FLATPAK_CACHE="$(flatpak list --app --columns=application 2>/dev/null || true)"
    fi
    if command -v pacman >/dev/null 2>&1; then
        PACMAN_CACHE="$(pacman -Qq 2>/dev/null || true)"
    fi
}

has_flatpak() {
    [[ -n "$FLATPAK_CACHE" ]] && grep -Fqx "$1" <<< "$FLATPAK_CACHE"
}

has_pacman_pkg() {
    [[ -n "$PACMAN_CACHE" ]] && grep -Fqx "$1" <<< "$PACMAN_CACHE"
}

is_app_installed() {
    local id=$1
    case "$id" in
        1)  has_flatpak "com.google.Chrome" ;;
        2)  has_flatpak "com.microsoft.Edge" ;;
        3)  command -v brave-origin >/dev/null 2>&1 || command -v brave >/dev/null 2>&1 ;;
        4)  [[ -d "$HOME/.local/share/antigravity-ide" ]] || command -v agy >/dev/null 2>&1 ;;
        5)  has_flatpak "com.visualstudio.code" ;;
        6)  has_flatpak "com.google.AndroidStudio" ;;
        7)  has_flatpak "io.github.shiftey.Desktop" ;;
        8)  has_flatpak "com.getpostman.Postman" ;;
        9)  has_flatpak "rest.insomnia.Insomnia" ;;
        10) has_flatpak "org.wireshark.Wireshark" ;;
        11) has_flatpak "com.jgraph.drawio.desktop" ;;
        12) has_flatpak "org.filezillaproject.Filezilla" ;;
        13) has_flatpak "org.libreoffice.LibreOffice" ;;
        14) has_pacman_pkg "distrobox" && has_pacman_pkg "podman" ;;
        15) [[ -x "$HOME/Applications/Zalo.AppImage" ]] ;;
        16) [[ -x "$HOME/.local/bin/linuxviewer" ]] ;;
        17) [[ -x "$HOME/Applications/Beeper.AppImage" ]] ;;
        18) has_flatpak "com.discordapp.Discord" ;;
        19) has_flatpak "org.telegram.desktop" ;;
        20) has_flatpak "com.viber.Viber" ;;
        21) has_flatpak "org.signal.Signal" ;;
        22) has_flatpak "com.slack.Slack" ;;
        23) has_flatpak "us.zoom.Zoom" ;;
        24) has_flatpak "app.openbubbles.OpenBubbles" ;;
        25) has_flatpak "me.proton.Mail" ;;
        26) has_flatpak "org.mozilla.thunderbird" ;;
        27) has_pacman_pkg "kdeconnect" ;;
        28) has_flatpak "com.spotify.Client" ;;
        29) has_flatpak "org.videolan.VLC" ;;
        30) has_pacman_pkg "mpv" ;;
        31) has_flatpak "com.obsproject.Studio" ;;
        32) has_flatpak "com.parsecgaming.parsec" ;;
        33) has_pacman_pkg "noisetorch" && has_pacman_pkg "pavucontrol" ;;
        34) has_flatpak "org.localsend.localsend_app" ;;
        35) has_flatpak "com.nextcloud.desktopclient.nextcloud" ;;
        36) has_flatpak "com.protonvpn.www" ;;
        37) has_pacman_pkg "wireguard-tools" ;;
        38) has_pacman_pkg "openvpn" ;;
        39) has_pacman_pkg "WallpaperEngine_kde6" ;;
        40) has_pacman_pkg "kate" && has_pacman_pkg "okular" ;;
        41) command -v brew >/dev/null 2>&1 || [[ -x /home/linuxbrew/.linuxbrew/bin/brew || -x "$HOME/.linuxbrew/bin/brew" ]] ;;
        42) has_pacman_pkg "btop" && has_pacman_pkg "ripgrep" ;;
        43) has_pacman_pkg "rclone" && has_pacman_pkg "onedriver" ;;
        44) [[ -f /etc/sysctl.d/99-isteamos-pc.conf ]] ;;
        45) has_flatpak "com.github.IsmaelMartinez.teams_for_linux" ;;
        46) has_flatpak "chat.rocket.RocketChat" ;;
        47) has_flatpak "com.rtosta.zapzap" ;;
        48) has_flatpak "org.remmina.Remmina" ;;
        49) has_flatpak "com.github.Murmele.Gittyup" || has_flatpak "com.axosoft.GitKraken" ;;
        50) has_flatpak "net.agalwood.Motrix" || has_flatpak "io.github.giantpinkrobots.varia" ;;
        51) has_flatpak "io.ente.auth" ;;
        52) has_flatpak "com.github.hluk.copyq" ;;
        53) has_flatpak "io.gitlab.adhami3310.Converter" ;;
        54) has_flatpak "io.github.flattool.Warehouse" || has_flatpak "com.github.tchx84.Flatseal" ;;
        55) command -v gemini >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/google-gemini-app" ]] ;;
        *)  return 1 ;;
    esac
}

app_badge() {
    if is_app_installed "$1"; then
        printf '%b[✓]%b' "$GREEN" "$NC"
    else
        printf '%b[ ]%b' "$DIM" "$NC"
    fi
}

format_item() {
    local id=$1
    local label=$2
    local badge
    badge="$(app_badge "$id")"
    printf '%2d) %s %-31s' "$id" "$badge" "$label"
}

install_by_id() {
    local id=$1
    case "$id" in
        1)  install_chrome ;;
        2)  install_edge ;;
        3)  install_brave ;;
        4)  install_antigravity ;;
        5)  install_vscode ;;
        6)  install_android_studio ;;
        7)  install_github_desktop ;;
        8)  install_postman ;;
        9)  install_insomnia ;;
        10) install_wireshark ;;
        11) install_drawio ;;
        12) install_filezilla ;;
        13) install_libreoffice ;;
        14) install_distrobox_podman ;;
        15) install_or_update_zalo ;;
        16) install_or_update_linuxviewer ;;
        17) install_beeper ;;
        18) install_discord ;;
        19) install_telegram ;;
        20) install_viber ;;
        21) install_signal ;;
        22) install_slack ;;
        23) install_zoom ;;
        24) install_openbubbles ;;
        25) install_proton_mail ;;
        26) install_thunderbird ;;
        27) install_kdeconnect ;;
        28) install_spotify ;;
        29) install_vlc ;;
        30) install_mpv ;;
        31) install_obs ;;
        32) install_parsec ;;
        33) install_audio_tools ;;
        34) install_localsend ;;
        35) install_nextcloud ;;
        36) install_protonvpn ;;
        37) install_wireguard ;;
        38) install_openvpn ;;
        39) install_wallpaper_engine ;;
        40) install_kde_utilities ;;
        41) install_homebrew ;;
        42) install_cli_system_suite ;;
        43) install_cloud_sync_suite ;;
        44) install_pc_workstation_optimizer ;;
        45) install_teams ;;
        46) install_rocketchat ;;
        47) install_whatsapp ;;
        48) install_remmina ;;
        49) install_git_guis ;;
        50) install_download_managers ;;
        51) install_ente_auth ;;
        52) install_copyq ;;
        53) install_heic_converter ;;
        54) install_flatpak_cleaners ;;
        55) install_gemini ;;
        *)  printf 'WARNING: Unknown application number: %s\n' "$id" >&2 ;;
    esac
}

uninstall_by_id() {
    local id=$1
    case "$id" in
        1)  log "Uninstalling Google Chrome"; uninstall_flatpak "com.google.Chrome" ;;
        2)  log "Uninstalling Microsoft Edge"; uninstall_flatpak "com.microsoft.Edge" ;;
        3)  uninstall_brave ;;
        4)  uninstall_antigravity ;;
        5)  log "Uninstalling Visual Studio Code"; uninstall_flatpak "com.visualstudio.code" ;;
        6)  log "Uninstalling Android Studio"; uninstall_flatpak "com.google.AndroidStudio" ;;
        7)  log "Uninstalling GitHub Desktop"; uninstall_flatpak "io.github.shiftey.Desktop" ;;
        8)  log "Uninstalling Postman"; uninstall_flatpak "com.getpostman.Postman" ;;
        9)  log "Uninstalling Insomnia"; uninstall_flatpak "rest.insomnia.Insomnia" ;;
        10) log "Uninstalling Wireshark"; uninstall_flatpak "org.wireshark.Wireshark" ;;
        11) log "Uninstalling draw.io"; uninstall_flatpak "com.jgraph.drawio.desktop" ;;
        12) log "Uninstalling FileZilla"; uninstall_flatpak "org.filezillaproject.Filezilla" ;;
        13) log "Uninstalling LibreOffice"; uninstall_flatpak "org.libreoffice.LibreOffice" ;;
        14) log "Uninstalling Distrobox & Podman"; remove_pacman_packages distrobox podman fuse-overlayfs ;;
        15) uninstall_zalo ;;
        16) uninstall_linuxviewer ;;
        17) uninstall_beeper ;;
        18) log "Uninstalling Discord"; uninstall_flatpak "com.discordapp.Discord" ;;
        19) log "Uninstalling Telegram Desktop"; uninstall_flatpak "org.telegram.desktop" ;;
        20) log "Uninstalling Viber"; uninstall_flatpak "com.viber.Viber" ;;
        21) log "Uninstalling Signal Desktop"; uninstall_flatpak "org.signal.Signal" ;;
        22) log "Uninstalling Slack"; uninstall_flatpak "com.slack.Slack" ;;
        23) log "Uninstalling Zoom"; uninstall_flatpak "us.zoom.Zoom" ;;
        24) log "Uninstalling OpenBubbles"; uninstall_flatpak "app.openbubbles.OpenBubbles" ;;
        25) log "Uninstalling Proton Mail"; uninstall_flatpak "me.proton.Mail" ;;
        26) log "Uninstalling Mozilla Thunderbird"; uninstall_flatpak "org.mozilla.thunderbird" ;;
        27) log "Uninstalling KDE Connect"; remove_pacman_packages kdeconnect ;;
        28) log "Uninstalling Spotify"; uninstall_flatpak "com.spotify.Client" ;;
        29) log "Uninstalling VLC Media Player"; uninstall_flatpak "org.videolan.VLC" ;;
        30) log "Uninstalling mpv Media Player"; remove_pacman_packages mpv ;;
        31) log "Uninstalling OBS Studio"; uninstall_flatpak "com.obsproject.Studio" ;;
        32) log "Uninstalling Parsec"; uninstall_flatpak "com.parsecgaming.parsec" ;;
        33) log "Uninstalling NoiseTorch & Pavucontrol"; remove_pacman_packages noisetorch pavucontrol ;;
        34) log "Uninstalling LocalSend"; uninstall_flatpak "org.localsend.localsend_app" ;;
        35) log "Uninstalling Nextcloud Desktop"; uninstall_flatpak "com.nextcloud.desktopclient.nextcloud" ;;
        36) log "Uninstalling Proton VPN"; uninstall_flatpak "com.protonvpn.www" ;;
        37) uninstall_wireguard ;;
        38) log "Uninstalling OpenVPN & NM Plugin"; remove_pacman_packages openvpn networkmanager-openvpn ;;
        39) log "Uninstalling Wallpaper Engine KDE 6 Plugin"; remove_pacman_packages WallpaperEngine_kde6 ;;
        40) uninstall_kde_utilities ;;
        41) uninstall_homebrew ;;
        42) uninstall_cli_system_suite ;;
        43) uninstall_cloud_sync_suite ;;
        44) uninstall_pc_workstation_optimizer ;;
        45) log "Uninstalling Teams for Linux"; uninstall_flatpak "com.github.IsmaelMartinez.teams_for_linux" ;;
        46) log "Uninstalling Rocket.Chat Desktop"; uninstall_flatpak "chat.rocket.RocketChat" ;;
        47) log "Uninstalling ZapZap (WhatsApp)"; uninstall_flatpak "com.rtosta.zapzap" ;;
        48) log "Uninstalling Remmina Remote Desktop"; uninstall_flatpak "org.remmina.Remmina" ;;
        49)
            log "Uninstalling Git GUIs (Gittyup & GitKraken)"
            uninstall_flatpak "com.github.Murmele.Gittyup"
            uninstall_flatpak "com.axosoft.GitKraken"
            ;;
        50)
            log "Uninstalling Download Managers (Motrix & Varia)"
            uninstall_flatpak "net.agalwood.Motrix"
            uninstall_flatpak "io.github.giantpinkrobots.varia"
            ;;
        51) log "Uninstalling Ente Auth"; uninstall_flatpak "io.ente.auth" ;;
        52) log "Uninstalling CopyQ"; uninstall_flatpak "com.github.hluk.copyq" ;;
        53) log "Uninstalling Switcheroo Image Converter"; uninstall_flatpak "io.gitlab.adhami3310.Converter" ;;
        54)
            log "Uninstalling Warehouse & Flatseal"
            uninstall_flatpak "io.github.flattool.Warehouse"
            uninstall_flatpak "com.github.tchx84.Flatseal"
            ;;
        55) uninstall_gemini ;;
        *)  printf 'WARNING: Unknown application number: %s\n' "$id" >&2 ;;
    esac
}

install_all_apps() {
    log "Installing All Applications, Browsers & Developer Tools (1..55)"
    local i
    for i in {1..55}; do
        install_by_id "$i"
    done
    log "All Applications, Browsers & Developer Tools installed successfully"
}

uninstall_all_apps() {
    log "Uninstalling All Managed Applications & Tools (1..55)"
    local i
    for i in {1..55}; do
        uninstall_by_id "$i"
    done
    log "All managed applications uninstalled"
}

show_tools_menu() {
    local installed_count=0
    local i
    for i in {1..55}; do
        if is_app_installed "$i"; then
            installed_count=$((installed_count + 1))
        fi
    done

    clear 2>/dev/null || true
    printf '%b==============================================================================%b\n' "$CYAN" "$NC"
    printf '%b   iSteamOS Ghost Toolbox  |  App Manager (%d / 55 Installed)                 %b\n' "$GREEN" "$installed_count" "$NC"
    printf '%b==============================================================================%b\n' "$CYAN" "$NC"

    printf '\n  %b[Browsers]%b\n' "$YELLOW" "$NC"
    printf '  %s  %s\n' "$(format_item 1 "Google Chrome")" "$(format_item 2 "Microsoft Edge (KWallet6)")"
    printf '  %s\n' "$(format_item 3 "Brave Browser (Native)")"

    printf '\n  %b[Developer, AI & Productivity]%b\n' "$YELLOW" "$NC"
    printf '  %s  %s\n' "$(format_item 4 "Google Antigravity (IDE/CLI)")" "$(format_item 5 "Visual Studio Code")"
    printf '  %s  %s\n' "$(format_item 6 "Android Studio")" "$(format_item 7 "GitHub Desktop")"
    printf '  %s  %s\n' "$(format_item 8 "Postman")" "$(format_item 9 "Insomnia")"
    printf '  %s  %s\n' "$(format_item 10 "Wireshark")" "$(format_item 11 "draw.io")"
    printf '  %s  %s\n' "$(format_item 12 "FileZilla")" "$(format_item 13 "LibreOffice Suite")"
    printf '  %s  %s\n' "$(format_item 14 "Distrobox & Podman")" "$(format_item 49 "Gittyup & GitKraken (Git)")"
    printf '  %s\n' "$(format_item 55 "Google Gemini CLI & Web App")"

    printf '\n  %b[Communication & Remote Desktop]%b\n' "$YELLOW" "$NC"
    printf '  %s  %s\n' "$(format_item 15 "Zalo for Linux (AppImage)")" "$(format_item 16 "LinuxViewer (UltraViewer)")"
    printf '  %s  %s\n' "$(format_item 17 "Beeper Unified Messenger")" "$(format_item 18 "Discord")"
    printf '  %s  %s\n' "$(format_item 19 "Telegram Desktop")" "$(format_item 20 "Viber")"
    printf '  %s  %s\n' "$(format_item 21 "Signal Desktop")" "$(format_item 22 "Slack")"
    printf '  %s  %s\n' "$(format_item 23 "Zoom")" "$(format_item 24 "OpenBubbles (iMessage)")"
    printf '  %s  %s\n' "$(format_item 25 "Proton Mail")" "$(format_item 26 "Mozilla Thunderbird")"
    printf '  %s  %s\n' "$(format_item 27 "KDE Connect")" "$(format_item 45 "Teams for Linux (MS Teams)")"
    printf '  %s  %s\n' "$(format_item 46 "Rocket.Chat Desktop")" "$(format_item 47 "ZapZap (WhatsApp Desktop)")"
    printf '  %s\n' "$(format_item 48 "Remmina Remote Desktop (RDP)")"

    printf '\n  %b[Media, Audio & Streaming]%b\n' "$YELLOW" "$NC"
    printf '  %s  %s\n' "$(format_item 28 "Spotify")" "$(format_item 29 "VLC Media Player")"
    printf '  %s  %s\n' "$(format_item 30 "mpv Player & GStreamer")" "$(format_item 31 "OBS Studio")"
    printf '  %s  %s\n' "$(format_item 32 "Parsec Game Streaming")" "$(format_item 33 "NoiseTorch & Pavucontrol")"

    printf '\n  %b[Networking, VPN, Cloud & Utilities]%b\n' "$YELLOW" "$NC"
    printf '  %s  %s\n' "$(format_item 34 "LocalSend")" "$(format_item 35 "Nextcloud Desktop")"
    printf '  %s  %s\n' "$(format_item 36 "Proton VPN")" "$(format_item 37 "WireGuard VPN & Tools")"
    printf '  %s  %s\n' "$(format_item 38 "OpenVPN & NM Plugin")" "$(format_item 43 "OneDrive & GDrive Sync")"
    printf '  %s  %s\n' "$(format_item 50 "Motrix & Varia Downloaders")" "$(format_item 51 "Ente Auth (2FA)")"
    printf '  %s  %s\n' "$(format_item 52 "CopyQ Clipboard Manager")" "$(format_item 53 "Switcheroo (HEIC Conv)")"

    printf '\n  %b[Desktop, KDE Apps, CLI, Cleaners & PC Optimizer]%b\n' "$YELLOW" "$NC"
    printf '  %s  %s\n' "$(format_item 39 "Wallpaper Engine KDE6")" "$(format_item 40 "KDE Apps (Kate/Okular/Ark)")"
    printf '  %s  %s\n' "$(format_item 41 "Homebrew (fastfetch/gh)")" "$(format_item 42 "CLI Suite (paru/btop/rg)")"
    printf '  %s  %s\n' "$(format_item 44 "PC Workstation Optimizer")" "$(format_item 54 "Warehouse & Flatseal")"

    printf '\n%b------------------------------------------------------------------------------%b\n' "$CYAN" "$NC"
    printf '  %bInstall:%b   2, 15, 45  or  1-5      |  %b[A]%b  Install ALL (1..55)\n' "$GREEN" "$NC" "$GREEN" "$NC"
    printf '  %bUninstall:%b u 15, 45   or  -15 -45  |  %b[U]%b  Interactive Uninstall  |  %b[UA]%b Uninstall ALL\n' "$RED" "$NC" "$RED" "$NC" "$RED" "$NC"
    printf '  %bTools:%b     %b[C]%b Clean Unused Caches |  %b[0]%b  Back / Exit\n' "$YELLOW" "$NC" "$YELLOW" "$NC" "$DIM" "$NC"
    printf '%b==============================================================================%b\n' "$CYAN" "$NC"
    printf 'Toolbox Command: '
}

trim_ws() {
    local s=$1
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

expand_id_tokens() {
    local token start end i
    for token in "$@"; do
        token="${token//,/}"
        [[ -n "$token" ]] || continue
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            if (( start <= end )); then
                for (( i = start; i <= end; i++ )); do
                    printf '%s\n' "$i"
                done
            else
                for (( i = start; i >= end; i-- )); do
                    printf '%s\n' "$i"
                done
            fi
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$token"
        else
            printf 'WARNING: Ignoring invalid selection token: %s\n' "$token" >&2
        fi
    done
}

parse_and_run_selection() {
    local mode=$1
    local raw_input=$2
    local normalized_input
    local selected_tokens=()

    normalized_input="${raw_input//,/ }"
    IFS=$' \t' read -r -a selected_tokens <<< "$normalized_input"
    if (( ${#selected_tokens[@]} == 0 )); then
        return 0
    fi

    if [[ "$mode" == "auto" ]]; then
        local tok
        for tok in "${selected_tokens[@]}"; do
            [[ -n "$tok" ]] || continue
            if [[ "$tok" == -* ]]; then
                run_action_on_tokens "uninstall" "${tok#-}"
            else
                run_action_on_tokens "install" "$tok"
            fi
        done
    else
        run_action_on_tokens "$mode" "${selected_tokens[@]}"
    fi
}

run_action_on_tokens() {
    local mode=$1
    shift
    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if [[ "$mode" == "uninstall" ]]; then
            uninstall_by_id "$id"
        else
            install_by_id "$id"
        fi
    done < <(expand_id_tokens "$@")
}

# --- Main Execution ---
(( EUID != 0 )) || die "Run this script as your normal SteamOS user, not as root."

sudo -v
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/isteamos-tools.XXXXXX")"

if [[ "${1:-}" == "--all" || "${1:-}" == "-a" ]]; then
    install_all_apps
    exit 0
fi

if [[ "${1:-}" == "--uninstall-all" ]]; then
    uninstall_all_apps
    exit 0
fi

if [[ "${1:-}" == "--uninstall" || "${1:-}" == "-u" || "${1:-}" == "--remove" ]]; then
    shift
    if (( $# == 0 )); then
        die "Specify app numbers or ranges to uninstall (e.g. --uninstall 15 45 or --uninstall 1-5)"
    fi
    run_action_on_tokens "uninstall" "$@"
    log "Selected applications uninstalled"
    exit 0
fi

if (( $# > 0 )); then
    for arg in "$@"; do
        if [[ "$arg" == -* ]]; then
            run_action_on_tokens "uninstall" "${arg#-}"
        else
            run_action_on_tokens "install" "$arg"
        fi
    done
    exit 0
fi

while true; do
    refresh_installed_cache
    show_tools_menu
    IFS= read -r user_selection || break
    user_selection="$(trim_ws "$user_selection")"
    lower_selection="$(printf '%s' "$user_selection" | tr '[:upper:]' '[:lower:]')"

    case "$lower_selection" in
        ""|0|q|quit|exit)
            printf '\nExiting Ghost Toolbox App Manager.\n'
            break
            ;;
        a|all)
            install_all_apps
            ;;
        ua|uninstall-all|remove-all)
            printf 'Are you sure you want to uninstall ALL 55 managed apps? [y/N]: '
            IFS= read -r confirm_ua || confirm_ua=""
            if [[ "$confirm_ua" =~ ^[yY]([eE][sS])?$ ]]; then
                uninstall_all_apps
            else
                printf 'Cancelled Uninstall ALL.\n'
            fi
            ;;
        c|clean)
            clean_unused_packages
            ;;
        u|uninstall|r|remove)
            printf 'Enter app numbers or ranges to UNINSTALL (e.g. 15, 45 or 1-5): '
            IFS= read -r uninstall_input || uninstall_input=""
            uninstall_input="$(trim_ws "$uninstall_input")"
            if [[ -n "$uninstall_input" ]]; then
                parse_and_run_selection "uninstall" "$uninstall_input"
            fi
            ;;
        u\ *|uninstall\ *|r\ *|remove\ *)
            rest_input="${user_selection#*[[:space:]]}"
            parse_and_run_selection "uninstall" "$rest_input"
            ;;
        i\ *|install\ *)
            rest_input="${user_selection#*[[:space:]]}"
            parse_and_run_selection "install" "$rest_input"
            ;;
        *)
            parse_and_run_selection "auto" "$user_selection"
            ;;
    esac

    if [[ -t 0 ]]; then
        printf '\nAction completed. Press Enter to return to Toolbox...'
        IFS= read -r || true
    fi
done
