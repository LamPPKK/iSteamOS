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
    local flags_file="$HOME/.var/app/com.microsoft.Edge/config/edge-flags.conf"
    local updated_file="$temp_dir/edge-flags.conf"
    local password_store=kwallet5

    if command -v kwalletd6 >/dev/null 2>&1; then
        password_store=kwallet6
    fi

    if [[ -L "$flags_file" || ( -e "$flags_file" && ! -f "$flags_file" ) ]]; then
        printf 'WARNING: Refusing to replace non-regular Edge flags file: %s\n' "$flags_file" >&2
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

configure_flatpak_keyring_access() {
    local app_id=$1

    flatpak override --user \
        --talk-name=org.kde.kwalletd5 \
        --talk-name=org.kde.kwalletd6 \
        --talk-name=org.freedesktop.secrets \
        "$app_id"
}

(( EUID != 0 )) || die "Run this script as your normal SteamOS user, not as root."

sudo -v
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/isteamos-tools.XXXXXX")"

log "Installing Brave Browser"
if ! command -v brave-origin >/dev/null 2>&1 && ! command -v brave >/dev/null 2>&1; then
    disable_readonly_if_needed
    curl -fsS https://dl.brave.com/install.sh | FLAVOR=origin sh || true
    restore_readonly
else
    printf 'Brave Browser is already installed.\n'
fi

log "Installing or updating Homebrew"
brew_bin="$(command -v brew || true)"
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

case "${SHELL:-/bin/bash}" in
    */zsh) shell_rc="$HOME/.zshrc" ;;
    *)     shell_rc="$HOME/.bashrc" ;;
esac

brew_shellenv_line="eval \"\$($brew_bin shellenv)\""
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

log "Installing or updating Google Antigravity"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/512x512/apps"

# 1. If Antigravity IDE is found in Downloads or tarball exists, relocate to ~/.local/share/antigravity-ide
ide_target_dir="$HOME/.local/share/antigravity-ide"
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

    local_logo="$ide_target_dir/resources/app/extensions/agy/img/logo.png"
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

# 2. CLI installation / symlinking
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

log "Installing or updating Flatpak applications"
flatpak_apps=(
    # Web Browsers
    "com.google.Chrome"                     # Google Chrome
    "com.microsoft.Edge"                    # Microsoft Edge

    # Developer & Productivity Tools
    "io.github.shiftey.Desktop"             # GitHub Desktop
    "com.visualstudio.code"                 # Visual Studio Code
    "com.google.AndroidStudio"              # Android Studio
    "com.getpostman.Postman"                # Postman API Platform
    "rest.insomnia.Insomnia"                # Insomnia REST Client
    "org.filezillaproject.Filezilla"        # FileZilla FTP Client
    "com.jgraph.drawio.desktop"             # draw.io Diagram Tool
    "org.libreoffice.LibreOffice"           # LibreOffice Suite

    # Communication & Social
    "com.discordapp.Discord"                # Discord
    "org.telegram.desktop"                  # Telegram Desktop
    "com.viber.Viber"                       # Viber
    "org.signal.Signal"                     # Signal Desktop
    "com.slack.Slack"                       # Slack
    "us.zoom.Zoom"                          # Zoom
    "app.openbubbles.OpenBubbles"           # OpenBubbles
    "me.proton.Mail"                        # Proton Mail
    "org.mozilla.thunderbird"               # Mozilla Thunderbird

    # Media, Streaming & Gaming
    "com.spotify.Client"                    # Spotify Music
    "org.videolan.VLC"                      # VLC Media Player
    "com.obsproject.Studio"                 # OBS Studio
    "com.parsecgaming.parsec"               # Parsec Game Streaming

    # Networking & Utilities
    "org.localsend.localsend_app"           # LocalSend
    "com.nextcloud.desktopclient.nextcloud" # Nextcloud Desktop Client
    "com.protonvpn.www"                     # Proton VPN
    "org.fcitx.Fcitx5"                      # Fcitx 5
)

for app in "${flatpak_apps[@]}"; do
    printf 'Installing or updating Flatpak: %s\n' "$app"
    install_or_update_flatpak "$app"
done

log "Configuring encrypted KWallet credential storage and keyring overrides"
configure_vscode_password_store
configure_edge_password_store
configure_chrome_password_store

keyring_apps=(
    "com.visualstudio.code"
    "com.microsoft.Edge"
    "com.google.Chrome"
    "io.github.shiftey.Desktop"
    "com.discordapp.Discord"
    "com.slack.Slack"
    "org.signal.Signal"
    "me.proton.Mail"
    "org.mozilla.thunderbird"
)

for app in "${keyring_apps[@]}"; do
    configure_flatpak_keyring_access "$app"
done

log "Apps, Browsers & Developer Tools installed successfully"

