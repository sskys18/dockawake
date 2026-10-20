# Dashboard native E2E checklist

Run this checklist against a locally built `DockAwake.app` on an Apple silicon Mac running macOS 13 or later. Record macOS version, build target, and each observed result.

## Launch and locked UI

- [ ] Launch the app. Confirm it shows in the Dock (no menu bar item) and the Dock icon draws live CPU, MEM, SSD, and BAT ring gauges in a 2x2 grid that refresh with the summary, with the keep-awake cup in the center while sleep is disabled.
- [ ] Click the Dock icon. Confirm one dashboard window opens on Overview, scrolled to the top, with CPU, Memory, Storage, and Battery gauges, the load chart already holding history, Network, Top CPU, Top Memory, Sleep, Containers, and Launch Agents cards, and Keep Awake in the header.
- [ ] Confirm the section control switches between Overview, Processes, Containers, and Launch Agents, that the card links jump to the matching section, and that Keep Awake stays visible in every section.
- [ ] Confirm the dashboard process columns are Process, Directory, PID, CPU, Memory, Energy, Ports, Awake, and Command, the table opens sorted by CPU descending, and columns cannot be reordered.
- [ ] With several `bun` processes running, confirm each reads by its script, such as `gjc (bun)` or `gjc sdk (bun)`, and that a process not owned by you keeps its plain name with Command N/A.
- [ ] Press Escape or Command-W, then click the Dock icon again. Confirm each closes the window and reopening starts a fresh dashboard without duplicate windows.
- [ ] Right-click the Dock icon. Confirm the menu has Open Dashboard, a disabled current Keep Awake status, Start at Login, and Quit.

## Lifecycle and keep-awake

- [ ] Toggle Start at Login from the menu, restart the app, and confirm the corresponding System Settings Login Items state changes without creating duplicate entries.
- [ ] Toggle Keep Awake on. Confirm the switch is disabled while applying, then reports Enabled only after the helper verifies `SleepDisabled`.
- [ ] Toggle it off. Confirm Disabled follows verification and `pmset -g | grep SleepDisabled` reports the restored state.
- [ ] While enabled, quit from the menu. Confirm normal sleep is restored. Repeat after sending SIGTERM and SIGINT to confirm termination also restores it.
- [ ] Deny or break helper authorization in a disposable test installation. Confirm an error is visible, no enabled state is claimed, and retry behavior does not freeze the UI.

## Privacy, network, and process data

- [ ] Observe network requests with a proxy or firewall. Confirm the only public-IP request is HTTPS to `api.ipify.org` with `format=json`; no telemetry, account, or unrelated network traffic appears.
- [ ] With network access blocked, confirm Public IP becomes Unavailable and the dashboard remains usable.
- [ ] With IPv4 and IPv6 interfaces available, confirm interface addresses, link speed, and receive/transmit rates render correctly. Confirm unavailable values show N/A and not-yet-known values show Unknown.
- [ ] Confirm Power Assertions render owner PID, owner name, and reason when available, otherwise N/A or Unknown without crashing.
- [ ] Create a local listening TCP socket. Confirm its owning process can show the listener, IPv6 listeners use bracketed addresses, and process sorting is stable by the selected column with unavailable values below available values.

## Containers and launch agents

- [ ] With the runtime running, open the Containers tab. Shift-click and Command-click several rows. Confirm the Stop Selected button reports the selected count and stays disabled when only stopped containers are selected.
- [ ] Press Stop Selected with two or more running containers. Confirm each is stopped through the runtime's graceful stop and the summary reports the stopped count, naming any container that failed.
- [ ] Let the five-second refresh run while rows are selected. Confirm the selection is not dropped.
- [ ] Stop the container runtime and reopen the tab. Confirm it reports the missing CLI or unreachable runtime instead of an empty list.
- [ ] Open the LaunchAgents tab. Confirm every `~/Library/LaunchAgents` plist is listed, running jobs show a PID, loaded-but-idle jobs show Loaded, unknown jobs show Not loaded, and a plist without a `Label` shows Invalid.
- [ ] Confirm jobs an app registered for itself appear with Source `Elsewhere` and Unknown trigger and program, that they match `launchctl list` minus `com.apple.` and `application.` labels, and that Apple's own agents are absent.
- [ ] Confirm a non-zero last exit status is highlighted and that no action in this tab loads, unloads, or edits any job.

## Build target and RunCat matrix

- [ ] Build and launch the direct production app with the documented Apple silicon macOS 13 target. Confirm it includes all dashboard sources and the compiled `dockawake-pmset` helper.
- [ ] Run the SwiftPM core test graph separately on the same target. Confirm it is test-only and does not replace the production build.
- [ ] With no RunCat bundle, run installation and confirm the migration reports no verified candidate and changes nothing.
- [ ] With an unsigned, symlinked, wrong-bundle-ID, or wrong-team-ID RunCat-shaped bundle in a disposable `~/Applications`, confirm it is rejected and preserved.
- [ ] With a verified RunCat candidate, decline migration or use non-interactive input. Confirm the bundle, preferences, Application Support data, and login registration are preserved, and manual-removal guidance is shown when applicable.
