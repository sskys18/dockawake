# DockAwake

A tiny macOS menu bar app that keeps your Mac awake with the lid closed, toggled by a single click.

Click the menu bar icon to keep your MacBook running with the lid closed. Click again to restore normal sleep. Useful for AI coding agents, SSH sessions, builds, downloads, and other long-running local work.

- Green cup icon: staying awake (lid-close safe)
- Moon icon: normal sleep behavior
- Red warning icon: helper error (state could not be applied or verified)

Inspired by [Capsomnia](https://github.com/fuji-mak/Capsomnia), which uses Caps Lock as the switch. DockAwake uses the same sleep-control principle but replaces the Caps Lock switch with a menu bar toggle: no Caps Lock watching, no Input Monitoring, no keyboard access at all.

## Why not `caffeinate`?

`caffeinate` prevents idle sleep while the lid is open. Closing the lid is different: normal power assertions do not reliably keep local jobs running in closed-lid use. DockAwake toggles the system `SleepDisabled` setting (`pmset -a disablesleep`), which does.

## Requirements

- Apple silicon Mac, macOS 13 or later
- Xcode command line tools (`swiftc`, `clang`)
- Administrator access during installation

## Install

```bash
git clone https://github.com/sskys18/dockawake.git
cd dockawake
./scripts/install.sh
```

The installer:

1. Builds `DockAwake.app` and the `dockawake-pmset` helper locally
2. Installs the app to `~/Applications/DockAwake.app`
3. Installs the helper to `/Library/PrivilegedHelperTools/dockawake-pmset` (root:wheel)
4. Adds a narrow NOPASSWD sudoers rule at `/etc/sudoers.d/dockawake`
5. Launches the app

Administrator authentication is required once, during installation only.

## Usage

- **Left-click** the menu bar icon: toggle keep-awake ON/OFF
- **Right-click**: menu with explicit toggle, current status, and Quit
- Quitting the app always restores normal sleep

When keeping the Mac awake with the lid closed, use a stable power source and ensure airflow. Closed-lid operation increases heat and battery consumption.

## Security model

The app never runs as root and never invokes a shell for privileged work. All privileged operations go through a fixed compiled helper that accepts exactly two arguments:

```
sudo -n /Library/PrivilegedHelperTools/dockawake-pmset on    # pmset -a disablesleep 1
sudo -n /Library/PrivilegedHelperTools/dockawake-pmset off   # pmset -a disablesleep 0
```

The sudoers rule is limited to those two exact commands. DockAwake verifies the actual `SleepDisabled` state after every change and every 10 seconds afterward; on failure it shows a red error icon and retries.

No network requests, no telemetry, no accounts, no Input Monitoring.

## Recovery

If the app is force-killed while keep-awake is ON, the sleep setting can remain disabled. Restore manually:

```bash
sudo pmset -a disablesleep 0
```

Check current state:

```bash
pmset -g | grep SleepDisabled
```

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes the app, helper, and sudoers rule, and restores normal sleep behavior.

## License

MIT
