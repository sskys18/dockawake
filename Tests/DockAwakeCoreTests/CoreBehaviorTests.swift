import Foundation
import AppKit
import XCTest
@testable import DockAwakeCore

final class CoreBehaviorTests: XCTestCase {
    func testFormattingClampsPercentAndRendersAddresses() {
        XCTAssertEqual(DashboardFormat.percent(-0.1), "0.0%")
        XCTAssertEqual(DashboardFormat.percent(42.4), "42.4%")
        XCTAssertEqual(DashboardFormat.percent(100.1), "100.0%")
        XCTAssertEqual(DashboardFormat.processPercent(245.6), "245.6%")
        XCTAssertEqual(DashboardFormat.address("192.0.2.1", port: 443), "192.0.2.1:443")
        XCTAssertEqual(DashboardFormat.address("2001:db8::1", port: 443), "[2001:db8::1]:443")
    }

    func testAvailabilityAndNetworkDisplayDistinguishUnknownFromUnavailable() {
        XCTAssertNil(Availability<Int>.unknown.value)
        XCTAssertNil(Availability<Int>.unavailable.value)
        XCTAssertEqual(Availability.available(7).value, 7)
        XCTAssertEqual(DashboardFormat.text(Availability<Double>.unknown, formatter: DashboardFormat.percent), "Unknown")
        XCTAssertEqual(DashboardFormat.text(Availability<Double>.unavailable, formatter: DashboardFormat.percent), "N/A")

        let interface = NetworkInterfaceSnapshot(
            name: "en0",
            flags: 0,
            addresses: [],
            linkSpeedBitsPerSecond: .unavailable,
            receivedBytes: .unknown,
            sentBytes: .unknown,
            receivedRateBytesPerSecond: .unknown,
            sentRateBytesPerSecond: .unavailable
        )
        XCTAssertEqual(interface.addressesText, "N/A")
        XCTAssertEqual(interface.linkSpeedText, "N/A")
        XCTAssertEqual(interface.receivedRateText, "Unknown")
        XCTAssertEqual(interface.sentRateText, "N/A")
    }

    func testInterpreterProcessesAreLabelledByTheScriptTheyRun() {
        let gjc = "/Users/me/.bun/bin/gjc"
        XCTAssertEqual(ProcessLabel.displayName(name: "bun", arguments: ["bun", gjc, "--mpreset", "hybrid-default"]), "gjc (bun)")
        XCTAssertEqual(ProcessLabel.displayName(name: "bun", arguments: ["bun", gjc, "sdk", "session", "raw"]), "gjc sdk (bun)")
        XCTAssertEqual(ProcessLabel.displayName(name: "bun", arguments: ["bun", "run", "dev"]), "dev (bun)")
        XCTAssertEqual(ProcessLabel.displayName(name: "node", arguments: ["node", "/app/server/dist/index.js"]), "server (node)")
        XCTAssertEqual(ProcessLabel.displayName(name: "python3.12", arguments: ["python3.12", "-u", "train.py", "/data/x"]), "train (python3.12)")
        // Non-interpreters, missing argv, and a bare REPL keep the executable name.
        XCTAssertEqual(ProcessLabel.displayName(name: "Safari", arguments: ["Safari", "open"]), "Safari")
        XCTAssertEqual(ProcessLabel.displayName(name: "bun", arguments: nil), "bun")
        XCTAssertEqual(ProcessLabel.displayName(name: "bun", arguments: ["bun", "--watch"]), "bun")
        // A self-retitled process blanks argv; its title is the only label it has.
        XCTAssertEqual(ProcessLabel.displayName(name: "node", arguments: ["node (vitest 1)", "", "   "]), "node (vitest 1)")
    }

    func testProcArgsParsingReadsArgvAfterExecutablePath() {
        var buffer = withUnsafeBytes(of: Int32(3)) { Array($0) }
        buffer += Array("/opt/bun".utf8) + [0, 0, 0]
        buffer += Array("bun".utf8) + [0] + Array("/x/gjc".utf8) + [0] + Array("sdk".utf8) + [0]
        buffer += Array("PATH=/bin".utf8) + [0]
        XCTAssertEqual(ProcessCollector.parseProcArgs(buffer), .available(["bun", "/x/gjc", "sdk"]))
        // A truncated buffer reports unavailable rather than a partial argv.
        XCTAssertEqual(ProcessCollector.parseProcArgs(Array(buffer.prefix(18))), .unavailable)
        XCTAssertEqual(ProcessCollector.parseProcArgs([1, 0]), .unavailable)
    }

    func testBoundedHistoryKeepsNewestSamplesUpToCapacity() {
        var history = BoundedHistory(capacity: 3)
        for second in 0..<5 {
            history.append(HistorySample(date: Date(timeIntervalSince1970: TimeInterval(second)), value: Double(second)))
        }
        XCTAssertEqual(history.samples.map(\.value), [2, 3, 4])
        history.removeAll()
        XCTAssertTrue(history.samples.isEmpty)
    }

    func testNetworkThroughputSumsOnlyAddressedNonLoopbackInterfaces() {
        func interface(_ name: String, _ addresses: [String], down: Double?, up: Double?) -> NetworkInterfaceSnapshot {
            NetworkInterfaceSnapshot(
                name: name, flags: 0, addresses: addresses,
                linkSpeedBitsPerSecond: .unavailable, receivedBytes: .unknown, sentBytes: .unknown,
                receivedRateBytesPerSecond: down.map(Availability.available) ?? .unknown,
                sentRateBytesPerSecond: up.map(Availability.available) ?? .unknown)
        }
        let throughput = NetworkThroughput.aggregate([
            interface("en0", ["192.168.1.2"], down: 100, up: 10),
            interface("utun3", ["10.0.0.2"], down: 50, up: nil),
            interface("lo0", ["127.0.0.1"], down: 9_999, up: 9_999),
            interface("anpi0", [], down: 7_777, up: 7_777)
        ])
        XCTAssertEqual(throughput, NetworkThroughput(receivedBytesPerSecond: 150, sentBytesPerSecond: 10))
        XCTAssertNil(NetworkThroughput.aggregate([interface("lo0", ["127.0.0.1"], down: 1, up: 1)]))
    }

    func testTopConsumersSkipExitedAndUnmeasuredProcesses() {
        func row(_ pid: Int32, cpu: Double?, memory: UInt64?, missing: Int = 0) -> ProcessRow {
            ProcessRow(
                id: ProcessIdentity(pid: pid, startSeconds: 0, startMicroseconds: 0),
                name: "p\(pid)", directory: .unavailable, arguments: .unavailable,
                cpuPercent: cpu.map(Availability.available) ?? .unavailable,
                memoryBytes: memory.map(Availability.available) ?? .unavailable,
                energyProxyPercent: .unavailable, ports: .unavailable, missingRefreshCount: missing)
        }
        let rows = [
            row(1, cpu: 5, memory: 300),
            row(2, cpu: 80, memory: 100),
            row(3, cpu: nil, memory: 900),
            row(4, cpu: 99, memory: 999, missing: 1),
            row(5, cpu: 0, memory: 200),
            row(6, cpu: 40, memory: nil)
        ]
        XCTAssertEqual(TopConsumers.byCPU(rows, limit: 2).map(\.id.pid), [2, 6])
        XCTAssertEqual(TopConsumers.byMemory(rows, limit: 3).map(\.id.pid), [3, 1, 5])
    }

    func testProcessIdentityOrdersPidThenStartTime() {
        let identities = [
            ProcessIdentity(pid: 12, startSeconds: 1, startMicroseconds: 0),
            ProcessIdentity(pid: 4, startSeconds: 20, startMicroseconds: 3),
            ProcessIdentity(pid: 4, startSeconds: 20, startMicroseconds: 1),
            ProcessIdentity(pid: 4, startSeconds: 19, startMicroseconds: 99)
        ]

        XCTAssertEqual(identities.sorted(), [
            ProcessIdentity(pid: 4, startSeconds: 19, startMicroseconds: 99),
            ProcessIdentity(pid: 4, startSeconds: 20, startMicroseconds: 1),
            ProcessIdentity(pid: 4, startSeconds: 20, startMicroseconds: 3),
            ProcessIdentity(pid: 12, startSeconds: 1, startMicroseconds: 0)
        ])
    }

    func testListeningPortIdentityAndDisplayIncludeIPv6Brackets() {
        let port = ListeningPort(protocolName: "tcp", address: "2001:db8::2", port: 8080, fileDescriptor: 6)
        XCTAssertEqual(port.id, "tcp:2001:db8::2:8080:6")
        XCTAssertEqual(port.displayText, "tcp [2001:db8::2]:8080")
    }

    func testPublicIPEndpointIsTheFixedSecureIpifyJSONEndpoint() {
        let endpoint = PublicIPClient.endpoint
        XCTAssertEqual(endpoint.scheme, "https")
        XCTAssertEqual(endpoint.host, "api.ipify.org")
        XCTAssertEqual(endpoint.absoluteString, "https://api.ipify.org?format=json")
        XCTAssertEqual(endpoint.query, "format=json")
    }

    func testPublicIPRequestCompletesOnceWithoutUnknownResult() {
        let completed = expectation(description: "public IP request completes")
        completed.assertForOverFulfill = true
        let request = PublicIPClient().makeRequest { result in
            XCTAssertNotEqual(result, .unknown)
            completed.fulfill()
        }

        request.start()

        wait(for: [completed], timeout: 7)
    }
    func testSchedulerImmediatelyExecutesHandlerWithoutSleeping() {
        let executed = expectation(description: "scheduled handler executes")
        let scheduler = DispatchScheduler(queue: DispatchQueue(label: "DockAwakeCoreTests.scheduler"))

        _ = scheduler.scheduleImmediately {
            executed.fulfill()
        }

        wait(for: [executed], timeout: 1)
    }
    private func alertSnapshot(cpu: Double = 10, storage: Double = 30, battery: Double = 80,
                               power: BatteryPower = .onBattery) -> SystemSummarySnapshot {
        SystemSummarySnapshot(
            timestamp: Date(),
            cpu: .available(MetricDisplay(value: cpu, text: "")),
            memory: .available(MetricDisplay(value: 50, text: "")),
            storage: .available(MetricDisplay(value: storage, text: "")),
            battery: .available(MetricDisplay(value: battery, text: "")),
            batteryPower: .available(power))
    }

    func testDockAlertNeedsSustainedCPUAndFiresOnce() {
        var tracker = DockAlertTracker()
        XCTAssertFalse(tracker.update(with: alertSnapshot(cpu: 95)))
        XCTAssertFalse(tracker.update(with: alertSnapshot(cpu: 95)))
        XCTAssertNil(tracker.badge)
        XCTAssertTrue(tracker.update(with: alertSnapshot(cpu: 95)))
        XCTAssertEqual(tracker.badge, "CPU")
        XCTAssertFalse(tracker.update(with: alertSnapshot(cpu: 95)))
        XCTAssertFalse(tracker.update(with: alertSnapshot(cpu: 20)))
        XCTAssertNil(tracker.badge)
    }

    func testDockAlertLowBatteryOnlyWhenUnplugged() {
        var tracker = DockAlertTracker()
        XCTAssertFalse(tracker.update(with: alertSnapshot(battery: 10, power: .charging)))
        XCTAssertNil(tracker.badge)
        XCTAssertTrue(tracker.update(with: alertSnapshot(battery: 10, power: .onBattery)))
        XCTAssertEqual(tracker.badge, "BAT")
    }

    func testDockAlertFullStorage() {
        var tracker = DockAlertTracker()
        XCTAssertTrue(tracker.update(with: alertSnapshot(storage: 93)))
        XCTAssertEqual(tracker.badge, "SSD")
    }

    func testDockTileRendersFourGauges() {
        let tile = DockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        tile.update(with: SystemSummarySnapshot(
            timestamp: Date(),
            cpu: .available(MetricDisplay(value: 10, text: "10%")),
            memory: .available(MetricDisplay(value: 20.4, text: "20%")),
            storage: .unavailable,
            battery: .available(MetricDisplay(value: 40, text: "40%"))
        ))
        XCTAssertEqual(tile.renderedGauges, ["CPU 10", "MEM 20", "SSD –", "BAT 40"])
    }

    func testDockTileReflectsChargerStateWithoutPercentChange() {
        let tile = DockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        func snapshot(_ power: BatteryPower) -> SystemSummarySnapshot {
            SystemSummarySnapshot(
                timestamp: Date(),
                cpu: .available(MetricDisplay(value: 10, text: "10%")),
                memory: .available(MetricDisplay(value: 20, text: "20%")),
                storage: .available(MetricDisplay(value: 30, text: "30%")),
                battery: .available(MetricDisplay(value: 40, text: "40%")),
                batteryPower: .available(power))
        }

        tile.update(with: snapshot(.onBattery))
        XCTAssertEqual(tile.renderedGauges.last, "BAT 40")
        tile.update(with: snapshot(.charging))
        XCTAssertEqual(tile.renderedGauges.last, "⚡︎BAT 40")
        tile.update(with: snapshot(.pluggedNotCharging))
        XCTAssertEqual(tile.renderedGauges.last, "AC 40")
    }

    func testLiveBatteryReportsChargerState() {
        let snapshot = SystemSummaryCollector().collect(previousCPU: nil).snapshot
        guard case .available = snapshot.battery else { return }
        guard case .available = snapshot.batteryPower else {
            XCTFail("charger state must accompany an available battery charge")
            return
        }
    }

    func testPowerAssertionsUseOwningPidKeys() {
        switch PowerAssertionCollector().collect() {
        case let .available(rows):
            for row in rows {
                XCTAssertNotNil(row.ownerPID)
                XCTAssertFalse(row.type.isEmpty)
            }
        case .unavailable, .unknown:
            XCTFail("IOKit assertion inventory should be available on supported macOS")
        }
    }
    func testLiveSummaryMetricsStayWithinPercentageBounds() {
        let result = SystemSummaryCollector().collect(previousCPU: nil)
        for metric in [result.snapshot.memory, result.snapshot.storage] {
            guard case let .available(display) = metric else {
                return XCTFail("Expected a local summary metric")
            }
            XCTAssertGreaterThanOrEqual(display.value, 0)
            XCTAssertLessThanOrEqual(display.value, 100)
        }
        XCTAssertEqual(result.snapshot.cpu, .unavailable)
    }

    func testLiveProcessCollectionUsesUniqueStartIdentities() {
        let rows = ProcessCollector().collect()
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        for row in rows {
            XCTAssertGreaterThan(row.id.pid, 0)
        }
    }

    // A MAXCOMLEN-sized buffer makes libproc reject every proc_name call, which
    // silently rendered the whole table as "Unknown".
    func testProcessRowsResolveRealNames() {
        let rows = ProcessCollector().collect()
        let mine = rows.first { $0.id.pid == getpid() }

        XCTAssertNotNil(mine)
        XCTAssertNotEqual(mine?.name, "Unknown")
        XCTAssertFalse(mine?.name.isEmpty ?? true)
        XCTAssertLessThan(rows.filter { $0.name == "Unknown" }.count, rows.count / 2)
    }

    // Interpreter processes such as bun all report the same executable name, so
    // the working directory is what identifies which project one is running.
    func testProcessRowsCarryTheWorkingDirectory() {
        let expected = FileManager.default.currentDirectoryPath
        let mine = ProcessCollector().collect().first { $0.id.pid == getpid() }

        guard case let .available(directory)? = mine?.directory else {
            return XCTFail("Expected a working directory for the test process")
        }
        XCTAssertEqual(directory, expected)
    }

    func testHomeRelativePathShortensOnlyPathsUnderHome() {
        let home = NSHomeDirectory()
        XCTAssertEqual(DashboardFormat.homeRelativePath(home), "~")
        XCTAssertEqual(DashboardFormat.homeRelativePath(home + "/Mine/dockawake"), "~/Mine/dockawake")
        XCTAssertEqual(DashboardFormat.homeRelativePath("/usr/local"), "/usr/local")
        XCTAssertEqual(DashboardFormat.homeRelativePath(home + "x/y"), home + "x/y")
    }

    // libproc task times are mach units, not nanoseconds. Without the timebase
    // conversion a fully busy core reported roughly 1/42 of its real usage.
    func testProcessCPUUsesMachTimebaseSoBusyWorkIsNotUnderReported() {
        let collector = ProcessCollector()
        _ = collector.collect()

        let deadline = Date().addingTimeInterval(0.6)
        var sink = 0.0
        while Date() < deadline { sink += 1 }
        XCTAssertGreaterThan(sink, 0)

        let mine = collector.collect().first { $0.id.pid == getpid() }
        guard case let .available(percent)? = mine?.cpuPercent else {
            return XCTFail("Expected a CPU sample for the test process")
        }
        XCTAssertGreaterThan(percent, 40)
    }
    func testCommandRunnerTimeoutIsBounded() {
        let started = ProcessInfo.processInfo.systemUptime
        let result = CommandRunner().run(
            executable: "/bin/sleep",
            arguments: ["10"],
            outputLimit: 1024,
            timeout: 0.1)
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(elapsed, 3)
    }
    func testDetailSessionStoppedBeforeStartSchedulesNoWork() {
        let scheduled = expectation(description: "no detail schedule")
        scheduled.isInverted = true
        let published = expectation(description: "no detail publication")
        published.isInverted = true
        let scheduler = RecordingScheduler {
            scheduled.fulfill()
        }
        let session = DetailCollectionSession(
            generation: 1,
            scheduler: scheduler,
            networkCollector: NetworkCollector(),
            publicIPClient: PublicIPClient(),
            processCollector: ProcessCollector(),
            powerAssertionCollector: PowerAssertionCollector(),
            containerCollector: ContainerCollector(runner: RecordingRunner(results: []), isExecutable: { _ in false }),
            launchAgentCollector: LaunchAgentCollector(runner: RecordingRunner(results: []))
        ) { _ in
            published.fulfill()
        }

        session.stop()
        session.start()

        wait(for: [scheduled, published], timeout: 0.2)
        XCTAssertTrue(scheduler.delays.isEmpty)
    }

    func testDetailSessionSchedulesTheSecondPassOneSecondAfterTheFirst() {
        let scheduled = expectation(description: "repeating pass scheduled")
        let scheduler = RecordingScheduler { scheduled.fulfill() }
        let session = DetailCollectionSession(
            generation: 1,
            scheduler: scheduler,
            networkCollector: NetworkCollector(),
            publicIPClient: PublicIPClient(),
            processCollector: ProcessCollector(),
            powerAssertionCollector: PowerAssertionCollector(),
            containerCollector: ContainerCollector(runner: RecordingRunner(results: []), isExecutable: { _ in false }),
            launchAgentCollector: LaunchAgentCollector(runner: RecordingRunner(results: []))
        ) { _ in }

        session.start()

        wait(for: [scheduled], timeout: 2)
        // The immediate pass only sets the CPU baseline, so the next one has to
        // arrive quickly or the panel shows N/A for a full refresh interval.
        XCTAssertEqual(scheduler.delays, [1])
        session.stop()
    }

    func testProcessCPUNeedsAMeasurableWindowBeforeItIsReported() {
        // A baseline taken microseconds ago cannot produce a meaningful percentage.
        XCTAssertGreaterThan(ProcessCollector.minimumSampleInterval, 0)

        let collector = ProcessCollector()
        let first = collector.collect()
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(first.allSatisfy { $0.cpuPercent.value == nil })

        Thread.sleep(forTimeInterval: ProcessCollector.minimumSampleInterval + 0.1)
        let second = collector.collect()
        XCTAssertTrue(second.contains { $0.cpuPercent.value != nil })
    }

    func testKeepAwakeUnknownReadIsNeverReportedDisabled() {
        let published = expectation(description: "unknown state published")
        let scheduled = expectation(description: "periodic verification scheduled")
        let runner = RecordingRunner(results: [
            CommandResult(status: 1, output: Data(), timedOut: false, exceededOutputLimit: false)
        ])
        let scheduler = RecordingScheduler {
            scheduled.fulfill()
        }
        let controller = KeepAwakeController(runner: runner, scheduler: scheduler) { state in
            XCTAssertEqual(state.current, .unknown)
            XCTAssertNil(state.lastKnown)
            published.fulfill()
        }

        controller.adoptCurrentState()

        wait(for: [published, scheduled], timeout: 2)
        XCTAssertEqual(runner.calls, [
            RecordingRunner.Call(executable: "/usr/bin/pmset", arguments: ["-g"])
        ])
        XCTAssertEqual(scheduler.delays, [10])
    }

    func testKeepAwakeUsesExactCommandsAndFiveSecondRetry() {
        let published = expectation(description: "pending and failed states published")
        published.expectedFulfillmentCount = 2
        let runner = RecordingRunner(results: [
            CommandResult(status: 1, output: Data(), timedOut: false, exceededOutputLimit: false),
            CommandResult(status: 0, output: Data(" SleepDisabled 0\n".utf8), timedOut: false, exceededOutputLimit: false)
        ])
        let scheduled = expectation(description: "retry scheduled")
        let scheduler = RecordingScheduler { scheduled.fulfill() }
        let controller = KeepAwakeController(runner: runner, scheduler: scheduler) { _ in
            published.fulfill()
        }

        controller.setDesired(true)

        wait(for: [published, scheduled], timeout: 2)
        XCTAssertEqual(runner.calls, [
            RecordingRunner.Call(
                executable: "/usr/bin/sudo",
                arguments: ["-n", "/Library/PrivilegedHelperTools/dockawake-pmset", "on"]),
            RecordingRunner.Call(executable: "/usr/bin/pmset", arguments: ["-g"])
        ])
        XCTAssertEqual(scheduler.delays, [5])
    }

    func testShutdownOrdersFinalOffAsLastHelperMutation() {
        let runner = RecordingRunner(results: [
            CommandResult(status: 0, output: Data(), timedOut: false, exceededOutputLimit: false),
            CommandResult(status: 0, output: Data(" SleepDisabled 0\n".utf8), timedOut: false, exceededOutputLimit: false)
        ])
        let controller = KeepAwakeController(runner: runner, scheduler: RecordingScheduler()) { _ in }

        controller.shutdownAndRestoreSleep()

        XCTAssertEqual(runner.calls.last, RecordingRunner.Call(
            executable: "/usr/bin/pmset",
            arguments: ["-g"]))
        XCTAssertEqual(runner.calls.dropLast().last, RecordingRunner.Call(
            executable: "/usr/bin/sudo",
            arguments: ["-n", "/Library/PrivilegedHelperTools/dockawake-pmset", "off"]))
        XCTAssertFalse(runner.calls.contains {
            $0.executable == "/usr/bin/sudo" && $0.arguments.last == "on"
        })
    }

    // MARK: - Containers

    func testContainerParsingKeepsRunningFirstAndNormalizesEmptyFields() {
        let output = """
        {"ID":"aaa111","Names":"pc-settlement-pg","Image":"postgres:16","State":"exited","Status":"Exited (255) 2 days ago","Ports":""}
        {"ID":"bbb222","Names":"zeroradar-redis","Image":"redis:7","State":"RUNNING","Status":"Up 20 hours","Ports":"0.0.0.0:6379->6379/tcp"}
        not json at all
        {"Names":"missing-id","State":"running"}
        """
        let rows = ContainerCollector.parse(Data(output.utf8))

        XCTAssertEqual(rows.map(\.name), ["zeroradar-redis", "pc-settlement-pg"])
        XCTAssertTrue(rows[0].isRunning)
        XCTAssertEqual(rows[0].portsText, "0.0.0.0:6379->6379/tcp")
        XCTAssertFalse(rows[1].isRunning)
        XCTAssertEqual(rows[1].portsText, "None")
    }

    func testContainerRowShortIDAndFallbackName() {
        let row = ContainerRow(
            id: "0123456789abcdef0123",
            name: "",
            image: "redis:7",
            state: "",
            status: "Created",
            ports: "")
        XCTAssertEqual(row.shortID, "0123456789ab")
        XCTAssertEqual(row.displayName, "0123456789ab")
        XCTAssertEqual(row.stateText, "Unknown")
        XCTAssertFalse(row.isRunning)
    }

    func testRuntimeStatusDistinguishesMissingCLIFromEmptyContainerList() {
        XCTAssertEqual(ContainerRuntimeStatus.missingCLI.summaryText, "No docker CLI found")
        XCTAssertEqual(ContainerRuntimeStatus.daemonUnreachable.summaryText, "Runtime not running")
        XCTAssertEqual(ContainerRuntimeStatus.available([]).summaryText, "0 running · 0 total")
        XCTAssertTrue(ContainerRuntimeStatus.missingCLI.rows.isEmpty)
    }

    func testContainerCollectorReportsMissingCLIWithoutRunningAnything() {
        let runner = RecordingRunner(results: [])
        let collector = ContainerCollector(runner: runner, isExecutable: { _ in false })

        XCTAssertEqual(collector.collect(), .missingCLI)
        XCTAssertFalse(collector.stop(containerID: "aaa111"))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testContainerCollectorReportsDaemonUnreachableOnNonZeroExit() {
        let runner = RecordingRunner(results: [
            CommandResult(status: 1, output: Data(), timedOut: false, exceededOutputLimit: false)
        ])
        let collector = ContainerCollector(runner: runner, isExecutable: { $0 == "/opt/homebrew/bin/docker" })

        XCTAssertEqual(collector.collect(), .daemonUnreachable)
        XCTAssertEqual(runner.calls.first, RecordingRunner.Call(
            executable: "/opt/homebrew/bin/docker",
            arguments: ["ps", "--all", "--no-trunc", "--format", "{{json .}}"]))
    }

    func testContainerStopUsesGracefulRuntimeStopAndRejectsEmptyID() {
        let runner = RecordingRunner(results: [
            CommandResult(status: 0, output: Data(), timedOut: false, exceededOutputLimit: false)
        ])
        let collector = ContainerCollector(runner: runner, isExecutable: { $0 == "/usr/local/bin/docker" })

        XCTAssertFalse(collector.stop(containerID: ""))
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(collector.stop(containerID: "aaa111"))
        XCTAssertEqual(runner.calls, [RecordingRunner.Call(
            executable: "/usr/local/bin/docker",
            arguments: ["stop", "aaa111"])])
    }

    func testLaunchAgentListParsingSkipsHeaderAndReadsUnloadedPID() {
        let output = Data("PID\tStatus\tLabel\n742\t0\tcom.example.worker\n-\t-9\tcom.example.idle\nbroken line\n".utf8)

        let runtime = LaunchAgentCollector.parseList(output)

        XCTAssertEqual(runtime.count, 2)
        XCTAssertEqual(runtime["com.example.worker"], LaunchAgentRuntime(pid: 742, lastExitStatus: 0))
        XCTAssertEqual(runtime["com.example.idle"], LaunchAgentRuntime(pid: nil, lastExitStatus: -9))
        XCTAssertNil(runtime["Label"])
    }

    func testLaunchAgentDefinitionRequiresLabelAndDescribesItsTrigger() throws {
        let withLabel = try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "com.example.worker",
                "ProgramArguments": ["/bin/echo", "hi"],
                "RunAtLoad": true,
                "StartInterval": 300
            ] as [String: Any],
            format: .xml,
            options: 0)
        let withoutLabel = try PropertyListSerialization.data(
            fromPropertyList: ["Program": "/bin/echo"] as [String: Any],
            format: .xml,
            options: 0)

        XCTAssertEqual(
            LaunchAgentCollector.parseDefinition(withLabel),
            LaunchAgentCollector.Definition(
                label: "com.example.worker",
                program: "/bin/echo hi",
                trigger: "At load · Every 300s"))
        XCTAssertNil(LaunchAgentCollector.parseDefinition(withoutLabel))
    }

    func testLaunchAgentCollectorReportsRuntimeUnreadableWhenLaunchctlFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingRunner(results: [
            CommandResult(status: 1, output: Data(), timedOut: false, exceededOutputLimit: false)
        ])
        let collector = LaunchAgentCollector(runner: runner, directory: directory)

        XCTAssertEqual(collector.collect(), .runtimeUnreadable)
        XCTAssertEqual(runner.calls, [RecordingRunner.Call(executable: "/bin/launchctl", arguments: ["list"])])
    }

    func testLaunchAgentCollectorJoinsPlistsWithLiveStateAndOrdersRunningFirst() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(label: "com.example.idle", program: "/bin/sleep", to: directory.appendingPathComponent("idle.plist"))
        try write(label: "com.example.worker", program: "/bin/echo", to: directory.appendingPathComponent("worker.plist"))
        try write(label: "com.example.unloaded", program: "/bin/date", to: directory.appendingPathComponent("unloaded.plist"))
        try PropertyListSerialization
            .data(fromPropertyList: [String: Any](), format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("stub.plist"))
        let runner = RecordingRunner(results: [
            CommandResult(
                status: 0,
                output: Data("PID\tStatus\tLabel\n742\t0\tcom.example.worker\n-\t3\tcom.example.idle\n".utf8),
                timedOut: false,
                exceededOutputLimit: false)
        ])
        let collector = LaunchAgentCollector(runner: runner, directory: directory)

        let rows = collector.collect().rows

        XCTAssertEqual(
            rows.map(\.labelText),
            ["com.example.worker", "com.example.idle", "com.example.unloaded", "(no Label)"])
        XCTAssertEqual(rows[0].stateText, "Running")
        XCTAssertEqual(rows[0].pidText, "742")
        XCTAssertFalse(rows[0].failedLastRun)
        XCTAssertEqual(rows[1].stateText, "Loaded")
        XCTAssertEqual(rows[1].lastExitText, "3")
        XCTAssertTrue(rows[1].failedLastRun)
        XCTAssertEqual(rows[2].stateText, "Not loaded")
        XCTAssertEqual(rows[2].pidText, "-")
        XCTAssertEqual(rows[2].lastExitText, "-")
        XCTAssertEqual(rows[3].stateText, "Invalid")
        XCTAssertEqual(rows[3].fileName, "stub.plist")
        XCTAssertEqual(
            LaunchAgentStatus.available(rows).summaryText,
            "1 running · 2 loaded · 4 total · 1 invalid")
    }

    func testLaunchAgentCollectorListsAppRegisteredJobsAndDropsAppleAgents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(label: "com.example.worker", program: "/bin/echo", to: directory.appendingPathComponent("worker.plist"))
        let output = """
        PID\tStatus\tLabel
        742\t0\tcom.example.worker
        1267\t0\tcom.openssh.ssh-agent
        -\t0\tcom.1password.1password-launcher
        601\t0\tcom.apple.Spotlight
        44272\t0\tapplication.ru.keepcoder.Telegram.153008649.153008847

        """
        let runner = RecordingRunner(results: [
            CommandResult(status: 0, output: Data(output.utf8), timedOut: false, exceededOutputLimit: false)
        ])

        let rows = LaunchAgentCollector(runner: runner, directory: directory).collect().rows

        XCTAssertEqual(
            Set(rows.map(\.label)),
            ["com.example.worker", "com.openssh.ssh-agent", "com.1password.1password-launcher"])
        let agent = try XCTUnwrap(rows.first { $0.label == "com.openssh.ssh-agent" })
        XCTAssertEqual(agent.sourceText, "Elsewhere")
        XCTAssertEqual(agent.programText, "Unknown")
        XCTAssertEqual(agent.triggerText, "Unknown")
        XCTAssertEqual(agent.stateText, "Running")
        let fileBacked = try XCTUnwrap(rows.first { $0.label == "com.example.worker" })
        XCTAssertEqual(fileBacked.sourceText, "worker.plist")
        XCTAssertEqual(fileBacked.programText, "/bin/echo")
    }

    private func write(label: String, program: String, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": label, "Program": program] as [String: Any],
            format: .xml,
            options: 0)
        try data.write(to: url)
    }

    func testContainerStopFailsWhenTheRuntimeTimesOut() {
        let runner = RecordingRunner(results: [
            CommandResult(status: 0, output: Data(), timedOut: true, exceededOutputLimit: false)
        ])
        let collector = ContainerCollector(runner: runner, isExecutable: { _ in true })

        XCTAssertFalse(collector.stop(containerID: "aaa111"))
    }

}

private final class RecordingRunner: CommandRunning {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var results: [CommandResult]
    private var recordedCalls: [Call] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func run(executable: String, arguments: [String], outputLimit: Int, timeout: TimeInterval) -> CommandResult {
        lock.lock()
        defer { lock.unlock() }
        recordedCalls.append(Call(executable: executable, arguments: arguments))
        guard !results.isEmpty else {
            return CommandResult(status: nil, output: Data(), timedOut: false, exceededOutputLimit: false)
        }
        return results.removeFirst()
    }
}

private final class RecordingScheduler: Scheduling {
    private let lock = NSLock()
    private var recordedDelays: [TimeInterval] = []
    private let onSchedule: (() -> Void)?

    init(onSchedule: (() -> Void)? = nil) {
        self.onSchedule = onSchedule
    }

    var delays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDelays
    }

    func scheduleImmediately(_ handler: @escaping () -> Void) -> DashboardScheduledTask {
        StubScheduledTask()
    }

    func schedule(after delay: TimeInterval, repeating interval: TimeInterval?, _ handler: @escaping () -> Void) -> DashboardScheduledTask {
        lock.lock()
        recordedDelays.append(delay)
        lock.unlock()
        onSchedule?()
        return StubScheduledTask()
    }
}

private final class StubScheduledTask: DashboardScheduledTask {
    func cancel() {}
}
