#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SIMPLE_DECKY_TDP_UPDATE_STUB="$SCRIPT_DIR/../patches/simple_decky_tdp/plugin_update.py"
readonly SIMPLE_DECKY_TDP_UPDATE_STUB_SHA256="b9ee49ead06fa00785d235fb796d7ce29afa0cb2ff58b352b5cbf6155636cba4"
readonly LOCK_DIR="/run/isteamos-decky-components.lock"
readonly DECKY_LOADER_VERSION="v3.2.6"
readonly DECKY_LOADER_SHA256="30f017a36a8baeb8c3dbae884f5d64be987a9b351b3859bf33e88615b653cf5e"
readonly DECKY_SERVICE_SHA256="64d6aa626aa45e1659e3137aa3afd72edd840094199d62bb6ff2e73c5ce738b1"
readonly SIMPLE_DECKY_TDP_VERSION="v1.0.5"
readonly SIMPLE_DECKY_TDP_SHA256="ebf1c68147b6300ee17c2d7ea00a9cfe9ac1c78af78d364d9d306ac64a2cc057"
readonly DECKY_WARP_VERSION="v1.6.1"
readonly DECKY_WARP_INSTALL_COMMIT="9493f87d9c0a3e8a141a7c3bfafc58be04305c81"
readonly DECKY_WARP_INSTALL_SHA256="02a636c78c6ae42fc1b5032718ecd14cc5ad1bfb682e82d2c1eae345722ed430"
readonly DECKY_WARP_RELEASE_SHA256="c328ad6377a52fdcb0829cbeb6ac8e086ef8fd7111216ee21e03e446aeeedaa0"

temp_dir=""
readonly_changed=0
lock_acquired=0

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

    if (( readonly_changed )); then
        printf 'Restoring SteamOS readonly mode after an error...\n' >&2
        if ! sudo steamos-readonly enable && (( exit_code == 0 )); then
            exit_code=1
        fi
    fi
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf -- "$temp_dir"
    fi
    if (( lock_acquired )); then
        if ! sudo rmdir -- "$LOCK_DIR" && (( exit_code == 0 )); then
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

download_file() {
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

    [[ -s "$destination" ]] || die "Downloaded file is empty: $url"
    checksum_output="$(sha256sum "$destination")"
    actual_sha256="${checksum_output%% *}"
    [[ "$actual_sha256" == "$expected_sha256" ]] || \
        die "Checksum mismatch for $url (expected $expected_sha256, got $actual_sha256)"
}

protected_mount_root() {
    local target=$1
    local mount_root
    local mount_owner
    local mount_mode

    mount_root="$(findmnt --noheadings --output TARGET --target "$target")"
    [[ "$mount_root" == /* && -d "$mount_root" && ! -L "$mount_root" ]] || \
        die "Could not determine a safe mount root for $target"
    mount_owner="$(stat -c '%u' -- "$mount_root")"
    mount_mode="$(stat -c '%a' -- "$mount_root")"
    if [[ "$mount_owner" != 0 ]] || (( (8#$mount_mode & 0022) != 0 )); then
        die "Mount root is not root-owned and protected: $mount_root"
    fi
    printf '%s\n' "$mount_root"
}

disable_readonly_if_needed() {
    local readonly_status

    readonly_status="$(sudo steamos-readonly status 2>&1 || true)"
    if grep -qi enabled <<< "$readonly_status"; then
        log "Temporarily disabling SteamOS readonly mode for Decky Loader"
        sudo steamos-readonly disable
        readonly_changed=1
    elif ! grep -qi disabled <<< "$readonly_status"; then
        die "Could not determine SteamOS readonly state: $readonly_status"
    fi
}

install_decky_loader() (
    set -Eeuo pipefail

    local homebrew_folder="$HOME/homebrew"
    local services_dir="$HOME/homebrew/services"
    local plugins_dir="$HOME/homebrew/plugins"
    local binary_download="$temp_dir/PluginLoader"
    local service_download="$temp_dir/plugin_loader-release.service"
    local mount_root
    local root_work_dir=""
    local escaped_home
    local transaction_started=0
    local install_complete=0
    local loader_was_active=0
    local loader_was_enabled=0
    local had_binary=0
    local had_version=0
    local had_system_service=0
    local had_saved_service=0
    local services_dir_created=0
    local saved_service_dir_created=0
    local services_uid=""
    local services_gid=""
    local services_mode=""
    local saved_services_uid=""
    local saved_services_gid=""
    local saved_services_mode=""
    local cef_marker="$HOME/.steam/steam/.cef-enable-remote-debugging"
    local flatpak_steam_dir="$HOME/.var/app/com.valvesoftware.Steam/data/Steam"
    local flatpak_cef_marker="$HOME/.var/app/com.valvesoftware.Steam/data/Steam/.cef-enable-remote-debugging"
    local cef_marker_managed=0
    local flatpak_marker_managed=0
    local had_cef_marker=0
    local had_flatpak_cef_marker=0

    # Invoked by the EXIT trap below.
    # shellcheck disable=SC2317,SC2329
    rollback_loader() {
        local exit_code=$?
        local rollback_failed=0
        local current_enabled_state
        trap - EXIT
        set +e

        if (( transaction_started && ! install_complete )); then
            sudo systemctl stop plugin_loader.service >/dev/null 2>&1 || true

            if (( ! loader_was_enabled )); then
                current_enabled_state="$(sudo systemctl is-enabled plugin_loader.service 2>/dev/null || true)"
                case "$current_enabled_state" in
                    enabled|enabled-runtime|linked|linked-runtime|alias)
                        sudo systemctl disable plugin_loader.service >/dev/null 2>&1 || rollback_failed=1
                        ;;
                esac
            fi

            if (( had_binary )); then
                sudo install -m 0755 -o root -g root "$root_work_dir/PluginLoader.backup" "$services_dir/PluginLoader" || rollback_failed=1
            else
                sudo rm -f -- "$services_dir/PluginLoader" || rollback_failed=1
            fi
            if (( had_version )); then
                sudo install -m 0644 -o root -g root "$root_work_dir/loader-version.backup" "$services_dir/.loader.version" || rollback_failed=1
            else
                sudo rm -f -- "$services_dir/.loader.version" || rollback_failed=1
            fi
            if (( had_system_service )); then
                sudo install -m 0644 -o root -g root "$root_work_dir/system-service.backup" /etc/systemd/system/plugin_loader.service || rollback_failed=1
            else
                sudo rm -f -- /etc/systemd/system/plugin_loader.service || rollback_failed=1
            fi
            if (( had_saved_service )); then
                sudo install -m 0644 -o root -g root "$root_work_dir/saved-service.backup" "$services_dir/.systemd/plugin_loader-release.service" || rollback_failed=1
            else
                sudo rm -f -- "$services_dir/.systemd/plugin_loader-release.service" || rollback_failed=1
            fi

            sudo systemctl daemon-reload || rollback_failed=1
            if (( loader_was_enabled )); then
                sudo systemctl enable plugin_loader.service >/dev/null 2>&1 || rollback_failed=1
            else
                if sudo systemctl is-enabled --quiet plugin_loader.service 2>/dev/null; then
                    rollback_failed=1
                fi
            fi
            if (( loader_was_active )); then
                sudo systemctl start plugin_loader.service || rollback_failed=1
            fi

            if (( cef_marker_managed && ! had_cef_marker )); then
                rm -f -- "$cef_marker" || rollback_failed=1
            fi
            if (( flatpak_marker_managed && ! had_flatpak_cef_marker )); then
                rm -f -- "$flatpak_cef_marker" || rollback_failed=1
            fi

            if (( saved_service_dir_created )); then
                if [[ -d "$services_dir/.systemd" ]]; then
                    sudo rmdir -- "$services_dir/.systemd" || rollback_failed=1
                fi
            else
                sudo chown "$saved_services_uid:$saved_services_gid" "$services_dir/.systemd" || rollback_failed=1
                sudo chmod "$saved_services_mode" "$services_dir/.systemd" || rollback_failed=1
            fi
            if (( services_dir_created )); then
                if [[ -d "$services_dir" ]]; then
                    sudo rmdir -- "$services_dir" || rollback_failed=1
                fi
            else
                sudo chown "$services_uid:$services_gid" "$services_dir" || rollback_failed=1
                sudo chmod "$services_mode" "$services_dir" || rollback_failed=1
            fi
        fi

        if (( rollback_failed == 0 )) && [[ -n "$root_work_dir" && -d "$root_work_dir" ]]; then
            sudo rm -rf -- "$root_work_dir"
        elif (( rollback_failed )); then
            printf 'ERROR: Decky Loader rollback files remain at %s\n' "$root_work_dir" >&2
            exit_code=1
        fi
        exit "$exit_code"
    }

    trap rollback_loader EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    mkdir -p -- "$homebrew_folder" "$plugins_dir"
    [[ -d "$homebrew_folder" && ! -L "$homebrew_folder" ]] || die "Invalid Decky homebrew directory"
    [[ -d "$plugins_dir" && ! -L "$plugins_dir" ]] || die "Invalid Decky plugins directory"
    if [[ -e "$services_dir" || -L "$services_dir" ]]; then
        [[ -d "$services_dir" && ! -L "$services_dir" ]] || die "Invalid Decky services directory"
        services_uid="$(stat -c '%u' -- "$services_dir")"
        services_gid="$(stat -c '%g' -- "$services_dir")"
        services_mode="$(stat -c '%a' -- "$services_dir")"
    else
        services_dir_created=1
    fi
    if [[ -e "$services_dir/.systemd" || -L "$services_dir/.systemd" ]]; then
        [[ -d "$services_dir/.systemd" && ! -L "$services_dir/.systemd" ]] || \
            die "Invalid Decky saved-service directory"
        saved_services_uid="$(stat -c '%u' -- "$services_dir/.systemd")"
        saved_services_gid="$(stat -c '%g' -- "$services_dir/.systemd")"
        saved_services_mode="$(stat -c '%a' -- "$services_dir/.systemd")"
    else
        saved_service_dir_created=1
    fi

    [[ -d "$HOME/.steam/steam" ]] || die "Steam data directory is missing: $HOME/.steam/steam"
    [[ ! -L "$cef_marker" ]] || die "Refusing symlinked Steam CEF marker"
    cef_marker_managed=1
    [[ -e "$cef_marker" ]] && had_cef_marker=1
    if [[ -d "$flatpak_steam_dir" ]]; then
        [[ ! -L "$flatpak_cef_marker" ]] || die "Refusing symlinked Flatpak Steam CEF marker"
        flatpak_marker_managed=1
        [[ -e "$flatpak_cef_marker" ]] && had_flatpak_cef_marker=1
    fi

    for target_file in \
        "$services_dir/PluginLoader" \
        "$services_dir/.loader.version" \
        "$services_dir/.systemd/plugin_loader-release.service" \
        /etc/systemd/system/plugin_loader.service; do
        [[ ! -L "$target_file" ]] || die "Refusing symlinked Decky Loader target: $target_file"
        if [[ -e "$target_file" ]]; then
            [[ -f "$target_file" ]] || die "Refusing non-file Decky Loader target: $target_file"
        fi
    done

    mount_root="$(protected_mount_root "$homebrew_folder")"
    root_work_dir="$(sudo mktemp -d "${mount_root%/}/.isteamos-decky-loader.XXXXXX")"
    [[ "$root_work_dir" == "${mount_root%/}"/.isteamos-decky-loader.* && -d "$root_work_dir" && ! -L "$root_work_dir" ]] || \
        die "Could not create secure Decky Loader staging"
    [[ "$(stat -c '%d' -- "$root_work_dir")" == "$(stat -c '%d' -- "$homebrew_folder")" ]] || \
        die "Decky Loader staging is on a different filesystem"

    sudo install -m 0500 -o root -g root "$binary_download" "$root_work_dir/PluginLoader.new"
    sudo install -m 0400 -o root -g root "$service_download" "$root_work_dir/service.template"
    [[ "$(sudo sha256sum "$root_work_dir/PluginLoader.new" | cut -d' ' -f1)" == "$DECKY_LOADER_SHA256" ]] || \
        die "Decky Loader changed while staging"
    [[ "$(sudo sha256sum "$root_work_dir/service.template" | cut -d' ' -f1)" == "$DECKY_SERVICE_SHA256" ]] || \
        die "Decky service changed while staging"

    escaped_home="${homebrew_folder//\\/\\\\}"
    escaped_home="${escaped_home//&/\\&}"
    escaped_home="${escaped_home//|/\\|}"
    sudo sed "s|\${HOMEBREW_FOLDER}|$escaped_home|g" "$root_work_dir/service.template" | \
        sudo tee "$root_work_dir/plugin_loader.service" >/dev/null
    sudo chmod 0644 "$root_work_dir/plugin_loader.service"
    sudo grep -Fqx "ExecStart=$services_dir/PluginLoader" "$root_work_dir/plugin_loader.service" || \
        die "Decky service substitution failed"

    if sudo systemctl is-active --quiet plugin_loader.service; then
        loader_was_active=1
    fi
    if sudo systemctl is-enabled --quiet plugin_loader.service; then
        loader_was_enabled=1
    fi

    if [[ -f "$services_dir/PluginLoader" ]]; then
        sudo cp -a -- "$services_dir/PluginLoader" "$root_work_dir/PluginLoader.backup"
        had_binary=1
    fi
    if [[ -f "$services_dir/.loader.version" ]]; then
        sudo cp -a -- "$services_dir/.loader.version" "$root_work_dir/loader-version.backup"
        had_version=1
    fi
    if [[ -f /etc/systemd/system/plugin_loader.service ]]; then
        sudo cp -a -- /etc/systemd/system/plugin_loader.service "$root_work_dir/system-service.backup"
        had_system_service=1
    fi
    if [[ -f "$services_dir/.systemd/plugin_loader-release.service" ]]; then
        sudo cp -a -- "$services_dir/.systemd/plugin_loader-release.service" "$root_work_dir/saved-service.backup"
        had_saved_service=1
    fi

    transaction_started=1
    if (( loader_was_active )); then
        sudo systemctl stop plugin_loader.service
    fi
    if (( services_dir_created )); then
        sudo install -d -m 0755 -o root -g root "$services_dir"
    fi
    if (( saved_service_dir_created )); then
        sudo install -d -m 0755 -o root -g root "$services_dir/.systemd"
    fi
    sudo chown root:root "$services_dir" "$services_dir/.systemd"
    sudo chmod 0755 "$services_dir" "$services_dir/.systemd"
    sudo mv -fT -- "$root_work_dir/PluginLoader.new" "$services_dir/PluginLoader"
    printf '%s\n' "$DECKY_LOADER_VERSION" | sudo tee "$root_work_dir/loader-version.new" >/dev/null
    sudo chmod 0644 "$root_work_dir/loader-version.new"
    sudo mv -fT -- "$root_work_dir/loader-version.new" "$services_dir/.loader.version"
    sudo install -m 0644 -o root -g root "$root_work_dir/plugin_loader.service" /etc/systemd/system/plugin_loader.service
    sudo install -m 0644 -o root -g root "$root_work_dir/plugin_loader.service" "$services_dir/.systemd/plugin_loader-release.service"
    if (( ! had_cef_marker )); then
        touch "$cef_marker"
    fi
    if (( flatpak_marker_managed && ! had_flatpak_cef_marker )); then
        touch "$flatpak_cef_marker"
    fi
    sudo systemctl daemon-reload
    sudo systemctl enable --now plugin_loader.service
    sudo systemctl is-active --quiet plugin_loader.service

    install_complete=1
    sudo rm -rf -- "$root_work_dir"
    root_work_dir=""
    printf 'Decky Loader %s installed successfully.\n' "$DECKY_LOADER_VERSION"
)

install_simple_decky_tdp() (
    set -Eeuo pipefail

    local archive="$temp_dir/SimpleDeckyTDP.zip"
    local plugins_dir="$HOME/homebrew/plugins"
    local plugin_dir="$plugins_dir/SimpleDeckyTDP"
    local mount_root
    local root_work_dir=""
    local staging_dir=""
    local backup_dir=""
    local loader_was_active=0
    local placement_attempted=0
    local backup_made=0
    local install_complete=0

    # Invoked by the EXIT trap below.
    # shellcheck disable=SC2317,SC2329
    rollback_simple_tdp() {
        local exit_code=$?
        local rollback_failed=0
        trap - EXIT
        set +e

        if (( ! install_complete )); then
            if (( placement_attempted )); then
                sudo rm -rf -- "$plugin_dir" || rollback_failed=1
            fi
            if (( backup_made )) && [[ -e "$backup_dir" || -L "$backup_dir" ]]; then
                sudo mv -T -- "$backup_dir" "$plugin_dir" || rollback_failed=1
            fi
            if (( loader_was_active )); then
                sudo systemctl start plugin_loader.service || rollback_failed=1
            fi
        fi

        if (( rollback_failed == 0 )) && [[ -n "$root_work_dir" && -d "$root_work_dir" ]]; then
            sudo rm -rf -- "$root_work_dir"
        elif (( rollback_failed )); then
            printf 'ERROR: SimpleDeckyTDP rollback files remain at %s\n' "$root_work_dir" >&2
            exit_code=1
        fi
        exit "$exit_code"
    }

    trap rollback_simple_tdp EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    download_file \
        "https://github.com/aarron-lee/SimpleDeckyTDP/releases/download/${SIMPLE_DECKY_TDP_VERSION}/SimpleDeckyTDP.zip" \
        "$archive" \
        "$SIMPLE_DECKY_TDP_SHA256"
    7z t -bd -y "$archive" >/dev/null

    mkdir -p -- "$plugins_dir"
    [[ -d "$plugins_dir" && ! -L "$plugins_dir" ]] || die "Invalid Decky plugins directory"
    mount_root="$(protected_mount_root "$plugins_dir")"
    root_work_dir="$(sudo mktemp -d "${mount_root%/}/.isteamos-simple-tdp.XXXXXX")"
    [[ "$root_work_dir" == "${mount_root%/}"/.isteamos-simple-tdp.* && -d "$root_work_dir" && ! -L "$root_work_dir" ]] || \
        die "Could not create secure SimpleDeckyTDP staging"
    [[ "$(stat -c '%d' -- "$root_work_dir")" == "$(stat -c '%d' -- "$plugins_dir")" ]] || \
        die "SimpleDeckyTDP staging is on a different filesystem"

    sudo install -m 0400 -o root -g root "$archive" "$root_work_dir/SimpleDeckyTDP.zip"
    [[ "$(sudo sha256sum "$root_work_dir/SimpleDeckyTDP.zip" | cut -d' ' -f1)" == "$SIMPLE_DECKY_TDP_SHA256" ]] || \
        die "SimpleDeckyTDP archive changed while staging"
    sudo 7z x -bd -y "$root_work_dir/SimpleDeckyTDP.zip" "-o$root_work_dir/extracted" >/dev/null
    staging_dir="$root_work_dir/extracted/SimpleDeckyTDP"
    for required_file in plugin.json package.json main.py dist/index.js bin/ryzenadj; do
        sudo test -f "$staging_dir/$required_file" || die "SimpleDeckyTDP archive is missing $required_file"
    done
    [[ -z "$(sudo find "$staging_dir" -type l -print -quit)" ]] || \
        die "SimpleDeckyTDP archive contains symbolic links"
    sudo jq -e --arg version "${SIMPLE_DECKY_TDP_VERSION#v}" '.version == $version' "$staging_dir/package.json" >/dev/null || \
        die "SimpleDeckyTDP package version does not match its release tag"
    [[ -f "$SIMPLE_DECKY_TDP_UPDATE_STUB" && ! -L "$SIMPLE_DECKY_TDP_UPDATE_STUB" ]] || \
        die "SimpleDeckyTDP OTA safety override is missing"
    [[ "$(sha256sum "$SIMPLE_DECKY_TDP_UPDATE_STUB" | cut -d' ' -f1)" == "$SIMPLE_DECKY_TDP_UPDATE_STUB_SHA256" ]] || \
        die "SimpleDeckyTDP OTA safety override checksum mismatch"
    sudo install -m 0444 -o root -g root \
        "$SIMPLE_DECKY_TDP_UPDATE_STUB" \
        "$staging_dir/py_modules/plugin_update.py"
    [[ "$(sudo sha256sum "$staging_dir/py_modules/plugin_update.py" | cut -d' ' -f1)" == "$SIMPLE_DECKY_TDP_UPDATE_STUB_SHA256" ]] || \
        die "SimpleDeckyTDP OTA safety override changed while staging"
    sudo chown -R root:root "$staging_dir"
    sudo chmod -R a-w,u+rX,go+rX "$staging_dir"
    sudo chmod 0555 "$staging_dir/bin/ryzenadj"

    backup_dir="$root_work_dir/SimpleDeckyTDP.backup"
    if sudo systemctl is-active --quiet plugin_loader.service; then
        loader_was_active=1
    fi
    if (( loader_was_active )); then
        sudo systemctl stop plugin_loader.service
    fi
    if [[ -e "$plugin_dir" || -L "$plugin_dir" ]]; then
        backup_made=1
        sudo mv -T -- "$plugin_dir" "$backup_dir"
    fi
    placement_attempted=1
    sudo mv -T -- "$staging_dir" "$plugin_dir"
    sudo systemctl restart plugin_loader.service
    sudo systemctl is-active --quiet plugin_loader.service

    install_complete=1
    sudo rm -rf -- "$root_work_dir"
    root_work_dir=""
    printf 'SimpleDeckyTDP %s installed successfully.\n' "$SIMPLE_DECKY_TDP_VERSION"
)

install_decky_warp() {
    local installer="$temp_dir/decky-warp-install.sh"

    download_file \
        "https://raw.githubusercontent.com/LamPPKK/DeckyWARP/${DECKY_WARP_INSTALL_COMMIT}/InstallPlugin.sh" \
        "$installer" \
        "$DECKY_WARP_INSTALL_SHA256"
    head -n 1 "$installer" | grep -q '^#!' || die "DeckyWARP installer is not a script"
    DECKYWARP_RELEASE_TAG="$DECKY_WARP_VERSION" \
    DECKYWARP_RELEASE_SHA256="$DECKY_WARP_RELEASE_SHA256" \
        /bin/bash "$installer"
}

(( EUID != 0 )) || die "Run this helper as the normal SteamOS desktop user, not root."
[[ "$HOME" == /* && "$HOME" != / && ! "$HOME" =~ $'\n' ]] || die "Invalid HOME directory"
for command_name in curl sha256sum sudo steamos-readonly findmnt stat mktemp sed tee cut grep jq 7z systemctl; do
    require_command "$command_name"
done

sudo -v
if ! sudo mkdir -- "$LOCK_DIR" 2>/dev/null; then
    die "Another Decky component installation is running (or $LOCK_DIR is stale after a crash)."
fi
lock_acquired=1
sudo chown root:root "$LOCK_DIR"
sudo chmod 0700 "$LOCK_DIR"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/isteamos-decky.XXXXXX")"

log "Downloading verified Decky Loader ${DECKY_LOADER_VERSION} payloads"
download_file \
    "https://github.com/SteamDeckHomebrew/decky-loader/releases/download/${DECKY_LOADER_VERSION}/PluginLoader" \
    "$temp_dir/PluginLoader" \
    "$DECKY_LOADER_SHA256"
download_file \
    "https://raw.githubusercontent.com/SteamDeckHomebrew/decky-loader/${DECKY_LOADER_VERSION}/dist/plugin_loader-release.service" \
    "$temp_dir/plugin_loader-release.service" \
    "$DECKY_SERVICE_SHA256"

disable_readonly_if_needed
log "Installing Decky Loader ${DECKY_LOADER_VERSION}"
install_decky_loader
restore_readonly

log "Installing SimpleDeckyTDP ${SIMPLE_DECKY_TDP_VERSION}"
install_simple_decky_tdp

log "Installing DeckyWARP ${DECKY_WARP_VERSION}"
install_decky_warp

log "Decky components installed"
