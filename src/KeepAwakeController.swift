import Foundation
import OSLog

struct KeepAwakeUIState: Equatable {
    let current: Availability<Bool>
    let lastKnown: Bool?
    let lastKnownAt: Date?
    let pendingIntent: Bool?
    let helperError: String?
}

final class KeepAwakeController {
    private enum State { case active, retryScheduled(UInt64), shuttingDown, terminated }

    private let runner: CommandRunning
    private let scheduler: Scheduling
    private let publish: (KeepAwakeUIState) -> Void
    private let executor = DispatchQueue(label: "com.dockawake.keep-awake", qos: .utility)
    private let logger = Logger(subsystem: "com.sskys.dockawake", category: "keepAwake")
    private var state: State = .active
    private var retryTask: DashboardScheduledTask?
    private var verificationTask: DashboardScheduledTask?
    private var retryToken: UInt64 = 0
    private var current: Availability<Bool> = .unknown
    private var lastKnown: Bool?
    private var lastKnownAt: Date?
    private var pendingIntent: Bool?
    private var helperError: String?

    init(runner: CommandRunning, scheduler: Scheduling, publish: @escaping (KeepAwakeUIState) -> Void) {
        self.runner = runner
        self.scheduler = scheduler
        self.publish = publish
    }

    func adoptCurrentState() {
        executor.async { [weak self] in
            guard let self else { return }
            self.readAndPublish(expected: nil)
            self.startPeriodicVerification()
        }
    }
    func verifyState() { executor.async { [weak self] in self?.readAndPublish(expected: nil) } }

    func setDesired(_ desired: Bool) {
        executor.async { [weak self] in
            guard let self else { return }
            self.logger.info("keep-awake requested mode \(desired ? "on" : "off", privacy: .public)")
            if case .shuttingDown = self.state { return }
            if case .terminated = self.state { return }
            self.invalidateRetry()
            self.pendingIntent = desired
            self.publishState()
            self.writeAndVerify(desired, allowRetry: true)
        }
    }

    func shutdownAndRestoreSleep() {
        executor.sync {
            if case .terminated = self.state { return }
            self.state = .shuttingDown
            self.invalidateRetry()
            self.verificationTask?.cancel()
            self.verificationTask = nil
            self.logger.info("keep-awake shutdown barrier started")
            self.pendingIntent = false
            self.publishState()
            _ = self.runHelper(false)
            self.pendingIntent = nil
            self.readAndPublish(expected: nil)
            self.state = .terminated
            self.logger.info("keep-awake shutdown barrier finished")
            self.publishState()
        }
    }

    private func writeAndVerify(_ desired: Bool, allowRetry: Bool) {
        guard case .active = state else { return }
        let writeSucceeded = runHelper(desired)
        guard case .active = state else { return }
        let read = readSleepDisabled()
        current = read
        if case let .available(value) = read {
            lastKnown = value
            lastKnownAt = Date()
        }
        pendingIntent = nil
        helperError = (writeSucceeded && read.value == desired) ? nil : "Unable to confirm keep-awake state"
        publishState()
        if allowRetry && (read.value != desired || !writeSucceeded) { scheduleRetry(desired) }
    }

    private func scheduleRetry(_ desired: Bool) {
        guard case .active = state else { return }
        retryToken &+= 1
        let token = retryToken
        state = .retryScheduled(token)
        retryTask = scheduler.schedule(after: 5, repeating: nil) { [weak self] in
            self?.executor.async {
                guard let self, case let .retryScheduled(activeToken) = self.state, activeToken == token else { return }
                self.retryTask = nil
                self.state = .active
                self.pendingIntent = desired
                self.publishState()
                self.writeAndVerify(desired, allowRetry: false)
            }
        }
    }

    private func startPeriodicVerification() {
        verificationTask?.cancel()
        verificationTask = scheduler.schedule(after: 10, repeating: 10) { [weak self] in
            self?.executor.async {
                guard let self, case .active = self.state else { return }
                self.readAndPublish(expected: nil)
            }
        }
    }
    private func invalidateRetry() {
        retryToken &+= 1
        retryTask?.cancel()
        retryTask = nil
        if case .retryScheduled = state { state = .active }
    }

    private func runHelper(_ desired: Bool) -> Bool {
        if case .shuttingDown = state, desired { return false }
        let result = runner.run(executable: "/usr/bin/sudo", arguments: ["-n", "/Library/PrivilegedHelperTools/dockawake-pmset", desired ? "on" : "off"], outputLimit: 4 * 1024, timeout: 5)
        return result.succeeded
    }

    private func readSleepDisabled() -> Availability<Bool> {
        let result = runner.run(executable: "/usr/bin/pmset", arguments: ["-g"], outputLimit: 64 * 1024, timeout: 5)
        guard result.succeeded, let text = String(data: result.output, encoding: .utf8) else { return .unknown }
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let index = fields.firstIndex(where: { $0 == "SleepDisabled" }), fields.indices.contains(index + 1) else { continue }
            switch fields[index + 1] {
            case "0": return .available(false)
            case "1": return .available(true)
            default: return .unknown
            }
        }
        return .unknown
    }

    private func readAndPublish(expected: Bool?) {
        if case .terminated = state { return }
        let read = readSleepDisabled()
        current = read
        if case let .available(value) = read {
            lastKnown = value
            lastKnownAt = Date()
        }
        if let expected, read.value != expected { helperError = "Unable to confirm keep-awake state" }
        publishState()
    }

    private func publishState() {
        let snapshot = KeepAwakeUIState(current: current, lastKnown: lastKnown, lastKnownAt: lastKnownAt, pendingIntent: pendingIntent, helperError: helperError)
        DispatchQueue.main.async { [publish] in publish(snapshot) }
    }
}
