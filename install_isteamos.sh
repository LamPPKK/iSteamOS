#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly_changed=0
temp_dir=""
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly HOMEBREW_INSTALL_COMMIT="cced90146ea6d3057c03a636b668fef177415eb3"
readonly HOMEBREW_INSTALL_SHA256="12479a24be3f5307eecac7cde670fad7118640f031229e964f544b1367b52a41"

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

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

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

download_script() {
    local url=$1
    local destination=$2
    local expected_sha256=$3
    local checksum_output
    local actual_sha256

    curl \
        --fail \
        --show-error \
        --silent \
        --location \
        --proto '=https' \
        --tlsv1.2 \
        --retry 3 \
        --output "$destination" \
        "$url"

    [[ -s "$destination" ]] || die "Downloaded script is empty: $url"
    head -n 1 "$destination" | grep -q '^#!' || die "Downloaded file is not a script: $url"

    checksum_output="$(sha256sum "$destination")"
    actual_sha256="${checksum_output%% *}"
    [[ "$actual_sha256" == "$expected_sha256" ]] || \
        die "Checksum mismatch for $url (expected $expected_sha256, got $actual_sha256)"
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
  "password-store": "basic"
}
EOF
    elif jq -e 'type == "object"' "$argv_file" >/dev/null 2>&1; then
        jq '. + {"password-store": "basic"}' "$argv_file" > "$updated_file"
        install_config "$argv_file" < "$updated_file"
    else
        printf '%s\n' \
            "WARNING: $argv_file contains JSON with comments or invalid JSON; leaving it unchanged." \
            'Open VS Code and run "Preferences: Configure Runtime Arguments", then add "password-store": "basic" manually.' >&2
    fi

    printf '%s\n' \
        "WARNING: VS Code password-store=basic uses weak, reversible obfuscation; use it only because SteamOS has no supported keyring." >&2
}

(( EUID != 0 )) || die "Run this script as your normal SteamOS user, not as root."

for required_command in sudo steamos-devmode steamos-readonly pacman flatpak curl mktemp grep sha256sum; do
    require_command "$required_command"
done

sudo -v
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/isteamos.XXXXXX")"

log "SteamOS post-install/update"

disable_readonly_if_needed

log "Enabling SteamOS developer mode"
sudo steamos-devmode enable --no-prompt

if command -v steamos-unminimize >/dev/null 2>&1; then
    log "Restoring development files removed from the SteamOS image"
    sudo steamos-unminimize --dev --noconfirm
fi

log "Updating system packages and installing prerequisites"
# Use a full upgrade to avoid the unsupported partial-upgrade state caused by pacman -Sy.
sudo pacman -Syu --needed --noconfirm \
    base-devel \
    procps-ng \
    curl \
    file \
    git \
    jq \
    7zip \
    unzip \
    fcitx5 \
    fcitx5-configtool \
    fcitx5-gtk \
    fcitx5-qt \
    fcitx5-unikey

require_command jq
require_command 7z
require_command unzip

# Homebrew, user Flatpaks and desktop configuration do not need a writable OS
# image. Restore it before the slower network operations below.
restore_readonly

log "Installing or updating Homebrew"
brew_bin="$(command -v brew || true)"
if [[ -z "$brew_bin" ]]; then
    homebrew_installer="$temp_dir/homebrew-install.sh"
    download_script \
        "https://raw.githubusercontent.com/Homebrew/install/${HOMEBREW_INSTALL_COMMIT}/install.sh" \
        "$homebrew_installer" \
        "$HOMEBREW_INSTALL_SHA256"
    NONINTERACTIVE=1 /bin/bash "$homebrew_installer"

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
if brew list --formula fastfetch >/dev/null 2>&1; then
    brew upgrade fastfetch
else
    brew install fastfetch
fi

log "Installing or updating Flatpak applications"
install_or_update_flatpak com.visualstudio.code
install_or_update_flatpak com.microsoft.Edge
configure_vscode_password_store

log "Configuring Fcitx5 and Unikey"
install_config "$HOME/.config/environment.d/fcitx5.conf" <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF

mkdir -p "$HOME/.config/autostart"
fcitx_autostart="$HOME/.config/autostart/org.fcitx.Fcitx5.desktop"
if [[ ! -e "$fcitx_autostart" && ! -L "$fcitx_autostart" ]]; then
    install -m 0644 \
        /usr/share/applications/org.fcitx.Fcitx5.desktop \
        "$fcitx_autostart"
else
    printf 'Preserving existing Fcitx5 autostart configuration: %s\n' "$fcitx_autostart"
fi

log "Installing verified Decky components"
decky_components_installer="$SCRIPT_DIR/scripts/install_decky_components.sh"
[[ -x "$decky_components_installer" ]] || \
    die "Missing executable helper: $decky_components_installer"
"$decky_components_installer"

# GAMESCOPE_FORCE_HDR is not a supported current Gamescope setting. Preserve any
# custom configuration, but move aside the exact legacy file created by old versions.
gamescope_config="$HOME/.config/environment.d/gamescope.conf"
legacy_gamescope_config="$temp_dir/gamescope.conf.legacy"
printf 'GAMESCOPE_FORCE_HDR=0\n' > "$legacy_gamescope_config"
if [[ -f "$gamescope_config" ]] && cmp -s "$gamescope_config" "$legacy_gamescope_config"; then
    gamescope_backup="${gamescope_config}.bak.$(date +%Y%m%d-%H%M%S)"
    mv -- "$gamescope_config" "$gamescope_backup"
    printf 'Moved unsupported legacy Gamescope setting to %s\n' "$gamescope_backup"
fi

restore_readonly

log "DONE"
printf '%s\n' "Please reboot the system, then open Fcitx5 Configuration and select Unikey."
