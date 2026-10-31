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
if brew list --formula fastfetch >/dev/null 2>&1; then
    brew upgrade fastfetch
else
    brew install fastfetch
fi

log "Installing or updating Google Antigravity"
if ! command -v agy >/dev/null 2>&1; then
    curl -fsSL https://antigravity.google/cli/install.sh | bash || true
else
    printf 'Google Antigravity is already installed.\n'
fi

for bin_dir in "$HOME/.local/bin" "$HOME/.gemini/bin"; do
    if [[ -d "$bin_dir" ]] && ! grep -Fq "$bin_dir" "$shell_rc" 2>/dev/null; then
        printf '\nexport PATH="%s:$PATH"\n' "$bin_dir" >> "$shell_rc"
    fi
    if [[ -d "$bin_dir" && ":$PATH:" != *":$bin_dir:"* ]]; then
        export PATH="$bin_dir:$PATH"
    fi
done

log "Installing or updating Flatpak applications"
install_or_update_flatpak com.visualstudio.code
install_or_update_flatpak com.microsoft.Edge
install_or_update_flatpak io.github.shiftey.Desktop

log "Configuring encrypted KWallet credential storage"
configure_vscode_password_store
configure_edge_password_store
configure_flatpak_keyring_access com.visualstudio.code
configure_flatpak_keyring_access com.microsoft.Edge
configure_flatpak_keyring_access io.github.shiftey.Desktop

log "Browsers & Developer Tools installed successfully"

