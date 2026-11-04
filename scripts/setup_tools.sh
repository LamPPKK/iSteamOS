#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

temp_dir=""
readonly_changed=0

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

# --- Individual App Installers ---

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

        cat <<'EOF' > "$HOME/.local/share/applications/antigravity-ide.desktop"
[Desktop Entry]
Name=Antigravity IDE
Comment=AI-powered IDE by Google
GenericName=Text Editor
Exec=/home/deck/.local/share/antigravity-ide/antigravity-ide %F
Icon=antigravity-ide
Type=Application
StartupNotify=true
StartupWMClass=antigravity-ide
Categories=Development;IDE;TextEditor;
MimeType=text/plain;inode/directory;
Actions=new-empty-window;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec=/home/deck/.local/share/antigravity-ide/antigravity-ide --new-window %F
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
            printf '\nexport PATH="%s:$PATH"\n' "$bin_dir" >> "$shell_rc"
        fi
        if [[ -d "$bin_dir" ]] && [[ -f "$HOME/.bash_profile" ]] && ! grep -Fq "$bin_dir" "$HOME/.bash_profile" 2>/dev/null; then
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
    log "Installing or updating LinuxViewer (MacViewer/UltraViewer for Linux)"
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

install_spotify() {
    log "Installing or updating Spotify"
    install_or_update_flatpak "com.spotify.Client"
}

install_vlc() {
    log "Installing or updating VLC Media Player"
    install_or_update_flatpak "org.videolan.VLC"
}

install_obs() {
    log "Installing or updating OBS Studio"
    install_or_update_flatpak "com.obsproject.Studio"
}

install_parsec() {
    log "Installing or updating Parsec Game Streaming"
    install_or_update_flatpak "com.parsecgaming.parsec"
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
        sed -i 's|steamLibraryPath=file:///home/deck/.steam/steam|steamLibraryPath=file:///home/deck/.local/share/Steam|g' "$plasma_applet_rc" 2>/dev/null || true
    fi
}

install_homebrew() {
    log "Installing or updating Homebrew & CLI Tools (fastfetch, gh)"
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
    for formula in fastfetch gh; do
        if brew list --formula "$formula" >/dev/null 2>&1; then
            brew upgrade "$formula" || true
        else
            brew install "$formula" || true
        fi
    done
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
        10) install_drawio ;;
        11) install_filezilla ;;
        12) install_libreoffice ;;
        13) install_or_update_zalo ;;
        14) install_or_update_linuxviewer ;;
        15) install_discord ;;
        16) install_telegram ;;
        17) install_viber ;;
        18) install_signal ;;
        19) install_slack ;;
        20) install_zoom ;;
        21) install_openbubbles ;;
        22) install_proton_mail ;;
        23) install_thunderbird ;;
        24) install_spotify ;;
        25) install_vlc ;;
        26) install_obs ;;
        27) install_parsec ;;
        28) install_localsend ;;
        29) install_nextcloud ;;
        30) install_protonvpn ;;
        31) install_wallpaper_engine ;;
        32) install_homebrew ;;
        *)  printf 'WARNING: Unknown application number: %s\n' "$id" >&2 ;;
    esac
}

install_all_apps() {
    log "Installing All Applications, Browsers & Developer Tools"
    for i in {1..32}; do
        install_by_id "$i"
    done
    log "All Applications, Browsers & Developer Tools installed successfully"
}

show_tools_menu() {
    clear 2>/dev/null || true
    cat <<'EOF'
===================================================================
          Select Applications to Install (Option 5)
===================================================================
  [Browsers]
    1) Google Chrome                2) Microsoft Edge (KWallet6 Sync)
    3) Brave Browser (Native)

  [Developer & Productivity]
    4) Google Antigravity (IDE/CLI) 5) Visual Studio Code
    6) Android Studio               7) GitHub Desktop
    8) Postman                      9) Insomnia
   10) draw.io                     11) FileZilla
   12) LibreOffice Suite

  [Communication & Remote Desktop]
   13) Zalo for Linux (AppImage)   14) LinuxViewer (UltraViewer)
   15) Discord                     16) Telegram Desktop
   17) Viber                       18) Signal Desktop
   19) Slack                       20) Zoom
   21) OpenBubbles (iMessage)      22) Proton Mail
   23) Mozilla Thunderbird

  [Media, Streaming & Utilities]
   24) Spotify                     25) VLC Media Player
   26) OBS Studio                  27) Parsec Game Streaming
   28) LocalSend                   29) Nextcloud Desktop
   30) Proton VPN

  [Desktop Customization & CLI]
   31) Wallpaper Engine KDE6       32) Homebrew (fastfetch, gh)

  [A] Install ALL Applications
  [0] Cancel / Exit
===================================================================
EOF
    printf 'Enter app numbers separated by space or comma (e.g. 2, 13, 31 or A for all): '
}

# --- Main Execution ---
(( EUID != 0 )) || die "Run this script as your normal SteamOS user, not as root."

sudo -v
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/isteamos-tools.XXXXXX")"

if [[ "${1:-}" == "--all" || "${1:-}" == "-a" ]]; then
    install_all_apps
    exit 0
fi

if (( $# > 0 )); then
    for arg in "$@"; do
        install_by_id "$arg"
    done
    exit 0
fi

show_tools_menu
IFS= read -r user_selection

if [[ -z "$user_selection" || "$user_selection" =~ ^[0qQ]$ ]]; then
    printf '\nCancelled application installation.\n'
    exit 0
fi

if [[ "$user_selection" =~ ^[aA]([lL][lL])?$ ]]; then
    install_all_apps
    exit 0
fi

# Replace commas with spaces and iterate over each selected number
normalized_selection="${user_selection//,/ }"
IFS=' ' read -r -a selected_ids <<< "$normalized_selection"

for id in "${selected_ids[@]}"; do
    [[ -n "$id" ]] || continue
    install_by_id "$id"
done

log "Selected applications finished installing"
