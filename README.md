# DockAwake

A local macOS menu-bar dashboard for the current Mac. Its compact rounded strip always shows exactly four icon/value pairs: CPU busy, physical memory used, root-volume storage used, and battery charge.

Left-click opens a transient dashboard with:

- The only Keep Awake switch and the current `SleepDisabled` state
- Active macOS power assertions, kept separate from `SleepDisabled`
- Every detected network interface, local IP addresses, link speed, traffic rates and totals
- One public-IP lookup from `https://api.ipify.org?format=json`
- A sortable process table with CPU, memory, `Energy proxy (CPU-based)`, and listening ports

The summary strip refreshes immediately and every five seconds. Detailed network, process, port, assertion, and public-IP work starts only while the dashboard is open and is canceled when it closes. Missing or inaccessible values display as `N/A`, `Unavailable`, or `Unknown`; DockAwake does not invent replacement data.

Memory used counts active, inactive, wired, and compressed pages against total physical memory, and disk used is the root volume's total minus available capacity. Both are read from public macOS APIs and are not expected to match Activity Monitor's or `df`'s presentation exactly.

Inspired by [Capsomnia](https://github.com/fuji-mak/Capsomnia), which uses Caps Lock as the switch. DockAwake uses the same sleep-control principle without Caps Lock watching, Input Monitoring, or keyboard access.

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

1. Builds `DockAwake.app`, the exact two-mode `dockawake-pmset` helper, and a temporary unprivileged RunCat remover locally
2. Installs the app to `~/Applications/DockAwake.app`
3. Installs the helper to `/Library/PrivilegedHelperTools/dockawake-pmset` (`root:wheel`)
4. Adds a narrow NOPASSWD sudoers rule at `/etc/sudoers.d/dockawake`
5. Discovers only cryptographically verified RunCat bundles under `~/Applications` and `/Applications`, discloses every match, and removes them after exact lowercase `yes` consent
6. Registers DockAwake as a login item (shown as "DockAwake" in System Settings > General > Login Items)
7. Launches DockAwake regardless of every RunCat migration outcome

RunCat removal is identity-bound and fail-closed. A candidate must match the archived bundle identifier, team identifier, and full designated requirement, be a direct non-symlink child of an approved root, and still be the exact device/inode object recorded at disclosure time. Removal renames that object into a same-volume quarantine, re-verifies identity and signature on the moved object, and deletes only that object; on any mismatch it restores the bundle or retains the quarantine and reports failure. The exact-path login registration is cleared and verified absent only after the bundle is gone, so a registration failure can never leave RunCat installed without its autostart. Consent decline, identity mismatch, and every failure delete nothing and print exact manual steps. RunCat preferences, caches, logs, saved state, and Application Support data are never removed.

Evidence limitation: this path is verified against fixture bundles and negative races only. Success against an authentic currently signed RunCat release, including its modern background-item registration, still requires reviewer-confirmed end-to-end evidence before release. Matching is never loosened to compensate.

Administrator authentication is required once for the DockAwake helper installation. RunCat migration itself is unprivileged.

## Usage

- **Left-click:** open the dashboard; left-click again, click away, or press Escape to close it
- **Keep Awake:** use the switch inside the dashboard
- **Right-click:** Open Dashboard, read-only keep-awake status, Start at Login, and Quit
- **Process sorting:** click a process column; unavailable numeric values remain last
- **Quit:** waits for the final ordered helper `off` operation and restores normal sleep

When keeping the Mac awake with the lid closed, use a stable power source and ensure airflow. Closed-lid operation increases heat and battery consumption.

## Security model

The app never runs as root and never invokes a shell for privileged work. All privileged operations go through a fixed compiled helper that accepts exactly two arguments:

```
sudo -n /Library/PrivilegedHelperTools/dockawake-pmset on    # pmset -a disablesleep 1
sudo -n /Library/PrivilegedHelperTools/dockawake-pmset off   # pmset -a disablesleep 0
```

The sudoers rule is limited to those two exact commands. DockAwake reads the actual tri-state `SleepDisabled` value after changes, verifies it again after 10 seconds when needed, and never reports an unreadable value as disabled. Shutdown rejects new writes and orders a final `off` after any active helper operation.

Dashboard metrics and process data stay local. There are no accounts, telemetry, history database, monitoring daemon, private energy APIs, or privileged metric paths. The only dashboard network request is one visible-session request to `https://api.ipify.org?format=json`; it has no retry or fallback provider and is canceled on close. `Energy proxy (CPU-based)` is derived from process CPU use and is not Activity Monitor Energy Impact.

## Recovery

If the app is force-killed while keep-awake is ON, the sleep setting can remain disabled. Restore manually:

```bash
sudo pmset -a disablesleep 0
```

Check current state:

```bash
pmset -g | grep SleepDisabled
```

## Verification

```bash
swift test
Tests/InstallerTests/run.sh
./scripts/build.sh
vtool -show-build build/DockAwake.app/Contents/MacOS/DockAwake
vtool -show-build build/dockawake-pmset
vtool -show-build build/runcat-safe-remove
lipo -archs build/DockAwake.app/Contents/MacOS/DockAwake
lipo -archs build/dockawake-pmset
lipo -archs build/runcat-safe-remove
```

The manual native-dashboard and migration matrix is in `Tests/Manual/dashboard-e2e.md`.
## Uninstall

```bash
./scripts/uninstall.sh
```

Removes the app, helper, and sudoers rule, and restores normal sleep behavior.

## License

MIT
