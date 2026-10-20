# DockAwake

**Keep your Mac awake with the lid closed, and see exactly what it is doing, from one Dock icon.**

DockAwake lives in the Dock. The icon itself is a live gauge of CPU, memory, storage, and battery. Clicking it opens a visual dashboard with live charts, the processes using your Mac, and the one switch that keeps the Mac awake even with the lid shut.

## Features

### A Dock icon that is a gauge

- Four live rings in a 2x2 grid: **CPU**, **MEM**, **SSD**, **BAT**, colored green, amber, or red by load
- A coffee-cup marker in the center while Keep Awake is on
- The battery ring shows `⚡︎BAT` while charging and `AC` while plugged in, and updates the moment the charger is connected or removed
- The icon badges and bounces once on sustained CPU above 90%, storage above 90%, or battery under 15% on battery power

### The Overview

Clicking the Dock icon opens the Overview:

- **Gauges** for CPU, memory, storage, and battery with absolute values such as `29.9 GB of 32 GB` or `115 GB free of 460 GB`, plus CPU and memory sparklines
- **Load chart** of CPU and memory over the last 10 minutes. It records while the window is closed, so it already has history when you open it
- **Network** throughput with a live down/up chart, your routable interface addresses, and your public IP
- **Top CPU** and **Top Memory** bars, each with its PID and working directory
- **Sleep** status: whether Keep Awake is on and which apps are holding off sleep, grouped per app
- **Containers** and **Launch Agents** summaries (running, loaded, failed) that jump to the full tables

### Every process, named by what it runs

Runtimes like bun, node, deno, and python all show up as the same executable name in Activity Monitor. DockAwake reads each process's command line and names it by the script it runs:

| Command line | Shown as |
| --- | --- |
| `bun ~/.bun/bin/gjc --mpreset hybrid-default` | `gjc (bun)` |
| `bun ~/.bun/bin/gjc sdk session raw …` | `gjc sdk (bun)` |
| `bun run dev` | `dev (bun)` |
| `node /app/server/dist/index.js` | `server (node)` |
| `node (vitest 1)` (a process that renamed itself) | `node (vitest 1)` |

The Processes table opens with the busiest CPU first and has Process, Directory, PID, CPU, Memory, Energy, Ports, Awake, and Command columns. Click any column heading to sort. Unavailable values always sort last.

### Containers and launch agents

- **Containers**: everything on the local Docker-compatible runtime. Select one or more running containers (Shift or Command click) and press **Stop Selected** to stop them through the runtime's own graceful stop, with a result reported for each one
- **Launch Agents**: every non-Apple launchd job in your user domain, both the `~/Library/LaunchAgents` property lists and jobs that apps registered for themselves, with live state, PID, last exit status, and trigger. Read-only: DockAwake never loads, unloads, or edits a job

## Why not `caffeinate`?

`caffeinate` prevents idle sleep while the lid is open. Closing the lid is different: normal power assertions do not reliably keep local jobs running with the lid closed. DockAwake toggles the system `SleepDisabled` setting (`pmset -a disablesleep`), which does.

Inspired by [Capsomnia](https://github.com/fuji-mak/Capsomnia), which uses Caps Lock as the switch. DockAwake uses the same sleep-control principle without Caps Lock watching, Input Monitoring, or keyboard access.

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

1. Builds `DockAwake.app`, the two-mode `dockawake-pmset` helper, and a temporary unprivileged RunCat remover locally
2. Installs the app to `/Applications/DockAwake.app`
3. Installs the helper to `/Library/PrivilegedHelperTools/dockawake-pmset` (`root:wheel`)
4. Adds a narrow NOPASSWD sudoers rule at `/etc/sudoers.d/dockawake`
5. Finds only cryptographically verified RunCat bundles under `~/Applications` and `/Applications`, lists every match, and removes them after you type exactly `yes`
6. Registers DockAwake as a login item (shown as "DockAwake" in System Settings > General > Login Items)
7. Launches DockAwake, whatever the outcome of the RunCat step

Administrator authentication is needed once, for the helper. The RunCat step itself is unprivileged.

<details>
<summary>How RunCat removal stays safe</summary>

RunCat removal is identity-bound and fails closed. A candidate must match the archived bundle identifier, team identifier, and full designated requirement, be a direct non-symlink child of an approved root, and still be the exact device/inode object recorded when it was listed. Removal renames that object into a same-volume quarantine, re-verifies identity and signature on the moved object, and deletes only that object; on any mismatch it restores the bundle or keeps the quarantine and reports failure. The exact-path login registration is cleared, and verified absent, only after the bundle is gone, so a registration failure can never leave RunCat installed without its autostart. Declining, an identity mismatch, and every failure delete nothing and print exact manual steps. RunCat preferences, caches, logs, saved state, and Application Support data are never removed.

Evidence limitation: this path is verified against fixture bundles and negative races only. Success against an authentic, currently signed RunCat release, including its modern background-item registration, still needs reviewer-confirmed end-to-end evidence before release. Matching is never loosened to compensate.

</details>

## Usage

- **Click the Dock icon** to open the dashboard. Press Escape or Command-W to close it
- **Sections**: switch between Overview, Processes, Containers, and Launch Agents with the control at the top. The links on the Overview cards jump straight to a section
- **Keep Awake**: the switch at the top right, visible in every section
- **Right-click the Dock icon** for Open Dashboard, the current readings, a Keep Awake toggle, and Start at Login
- **Quit** waits for the final helper `off` call and restores normal sleep

When keeping the Mac awake with the lid closed, use a stable power source and make sure it has airflow. Closed-lid operation increases heat and battery drain.

## How the numbers are measured

- The Dock icon and gauges refresh immediately and then every five seconds. Plugging in or unplugging the charger updates at once
- Detailed work (network, processes, ports, power assertions, containers, launch agents, public IP) runs only while the dashboard is open and stops when it closes
- **Memory used** counts active, inactive, wired, and compressed pages against total physical memory. **Storage used** is the root volume's total minus available capacity. Both come from public macOS APIs and will not match Activity Monitor or `df` exactly
- **CPU** in the Processes table is per core, so 100% is one full core. **Energy** is CPU use spread across all cores: a rough hint, not Activity Monitor's Energy Impact
- Directory and command line are shown only for processes you own; macOS does not hand them out for other users' processes, and DockAwake shows `N/A` rather than guess
- Missing or inaccessible values show as `N/A`, `Unavailable`, or `Unknown`. DockAwake never invents replacement data

## Security and privacy

The app never runs as root and never invokes a shell for privileged work. All privileged operations go through a fixed compiled helper that accepts exactly two arguments:

```
sudo -n /Library/PrivilegedHelperTools/dockawake-pmset on    # pmset -a disablesleep 1
sudo -n /Library/PrivilegedHelperTools/dockawake-pmset off   # pmset -a disablesleep 0
```

The sudoers rule is limited to those two exact commands. DockAwake reads the actual tri-state `SleepDisabled` value after every change, checks it again after 10 seconds when needed, and never reports an unreadable value as disabled. Shutdown rejects new writes and orders a final `off` after any running helper call.

Everything stays on your Mac. There are no accounts, telemetry, history database, monitoring daemon, private energy APIs, or privileged metric paths. The only network request is one public-IP lookup to `https://api.ipify.org?format=json` per dashboard opening; it has no retry or fallback provider and is canceled when the window closes.

## Recovery

If the app is force-killed while Keep Awake is on, sleep can stay disabled. Restore it manually:

```bash
sudo pmset -a disablesleep 0
```

Check the current state:

```bash
pmset -g | grep SleepDisabled
```

## Development

```bash
swift test                    # core logic tests
Tests/InstallerTests/run.sh   # installer tests
./scripts/build.sh            # builds build/DockAwake.app and the helpers
```

Check the build targets:

```bash
vtool -show-build build/DockAwake.app/Contents/MacOS/DockAwake
vtool -show-build build/dockawake-pmset
vtool -show-build build/runcat-safe-remove
lipo -archs build/DockAwake.app/Contents/MacOS/DockAwake
lipo -archs build/dockawake-pmset
lipo -archs build/runcat-safe-remove
```

The manual dashboard and migration checklist is in [`Tests/Manual/dashboard-e2e.md`](Tests/Manual/dashboard-e2e.md).

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes the app, helper, and sudoers rule, and restores normal sleep.

## License

MIT
