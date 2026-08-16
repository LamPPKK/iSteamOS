"""iSteamOS safety override for SimpleDeckyTDP's unverified root OTA updater."""

import os
import subprocess

import decky_plugin


INSTALLED_VERSION = "1.0.5"


def restart_decky_loader():
    env = os.environ.copy()
    env.pop("LD_LIBRARY_PATH", None)
    return subprocess.run(
        ["systemctl", "restart", "plugin_loader.service"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )


def ota_update():
    decky_plugin.logger.warning(
        "SimpleDeckyTDP OTA updates are disabled by iSteamOS; rerun iSteamOS to install a verified update."
    )
    return {"status": "disabled", "version": INSTALLED_VERSION}


def get_latest_version():
    # Reporting the pinned version keeps the bundled frontend from offering the
    # upstream updater, while ota_update() remains a second backend guard.
    return INSTALLED_VERSION


def reset_settings():
    settings_file = os.path.join(
        decky_plugin.DECKY_USER_HOME,
        "homebrew",
        "settings",
        "SimpleDeckyTDP",
        "settings.json",
    )
    try:
        os.remove(settings_file)
    except FileNotFoundError:
        pass
    restart_decky_loader()
    return True
