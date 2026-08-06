import Foundation
import OSLog

final class DetailCollectionSession {
    private enum State { case created, running, stopping, stopped }

    private let generation: UInt64
    private let scheduler: Scheduling
    private let networkCollector: NetworkCollector
    private let publicIPClient: PublicIPClient
    private let processCollector: ProcessCollector
    private let powerAssertionCollector: PowerAssertionCollector
    private let containerCollector: ContainerCollector
    private let publish: (DetailSnapshot) -> Void
    private let executor = DispatchQueue(label: "com.dockawake.detail", qos: .utility)
    private let worker = DispatchQueue(label: "com.dockawake.detail.collectors", qos: .utility)
    private let logger = Logger(subsystem: "com.sskys.dockawake", category: "detailLifecycle")
    private let lifecycleLock = NSLock()
    private var state: State = .created
    private var immediateTask: DashboardScheduledTask?
    private var repeatingTask: DashboardScheduledTask?
    private var publicIPRequest: PublicIPRequest?
    private var cancelled = false
    private var publicIP: Availability<String> = .unknown
    private var interfaces: [NetworkInterfaceSnapshot] = []
    private var processes: [ProcessRow] = []
    private var assertions: [PowerAssertionRow] = []
    private var containers: ContainerRuntimeStatus = .daemonUnreachable

    private var refreshInFlight = false
    init(generation: UInt64, scheduler: Scheduling, networkCollector: NetworkCollector, publicIPClient: PublicIPClient, processCollector: ProcessCollector, powerAssertionCollector: PowerAssertionCollector, containerCollector: ContainerCollector, publish: @escaping (DetailSnapshot) -> Void) {
        self.generation = generation
        self.scheduler = scheduler
        self.networkCollector = networkCollector
        self.publicIPClient = publicIPClient
        self.processCollector = processCollector
        self.powerAssertionCollector = powerAssertionCollector
        self.containerCollector = containerCollector
        self.publish = publish
    }

    func start() {
        executor.async { [weak self] in
            guard let self, case .created = self.state else { return }
            self.lifecycleLock.lock()
            guard !self.cancelled else {
                self.lifecycleLock.unlock()
                return
            }
            self.logger.info("detail session \(self.generation, privacy: .public) start requested")
            self.state = .running
            // The immediate pass has no prior sample, so its only job is to fill the
            // panel and set the CPU baseline. The second pass follows one second
            // later so real CPU appears almost at once instead of five seconds in.
            self.immediateTask = self.scheduler.scheduleImmediately { [weak self] in self?.refreshFromScheduler() }
            self.repeatingTask = self.scheduler.schedule(after: 1, repeating: 5) { [weak self] in self?.refreshFromScheduler() }
            self.lifecycleLock.unlock()
            self.startPublicIPRequest()
        }
    }

    func stop() {
        lifecycleLock.lock()
        guard !cancelled else {
            lifecycleLock.unlock()
            return
        }
        cancelled = true
        let request = publicIPRequest
        publicIPRequest = nil
        lifecycleLock.unlock()
        request?.cancel()
        processCollector.cancelActiveCollection()
        logger.info("detail session \(self.generation, privacy: .public) stop requested")
        executor.async { [weak self] in
            guard let self else { return }
            if case .stopped = self.state { return }
            self.state = .stopping
            self.immediateTask?.cancel()
            self.repeatingTask?.cancel()
            self.immediateTask = nil
            self.repeatingTask = nil
            self.publicIP = .unknown
            self.interfaces.removeAll()
            self.processes.removeAll()
            self.assertions.removeAll()
            self.containers = .daemonUnreachable
            self.state = .stopped
            self.logger.info("detail session \(self.generation, privacy: .public) stopped")
        }
    }

    private func refreshFromScheduler() {
        executor.async { [weak self] in
            guard let self, !self.isCancelled, case .running = self.state, !self.refreshInFlight else { return }
            self.refreshInFlight = true
            self.worker.async { [weak self] in
                guard let self, self.isRunning else { return }
                let interfaces = self.networkCollector.collect()
                guard self.isRunning else { return }
                let processes = self.processCollector.collect()
                guard self.isRunning else { return }
                let assertions: [PowerAssertionRow]
                switch self.powerAssertionCollector.collect() {
                case let .available(rows): assertions = rows
                case .unavailable, .unknown: assertions = []
                }
                guard self.isRunning else { return }
                let containers = self.containerCollector.collect()
                self.executor.async {
                    guard !self.isCancelled, case .running = self.state else {
                        self.refreshInFlight = false
                        return
                    }
                    self.interfaces = interfaces
                    self.processes = processes
                    self.assertions = assertions
                    self.containers = containers
                    self.refreshInFlight = false
                    self.publishIfRunning(interfaces: interfaces, processes: processes, assertions: assertions, containers: containers)
                }
            }
        }
    }

    private var isRunning: Bool {
        guard !isCancelled else { return false }
        return executor.sync {
            if case .running = state { return true }
            return false
        }
    }

    private var isCancelled: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return cancelled
    }

    private func startPublicIPRequest() {
        guard !isCancelled, case .running = state else { return }
        let request = publicIPClient.makeRequest { [weak self] result in
            self?.executor.async {
                guard let self, !self.isCancelled, case .running = self.state else { return }
                self.lifecycleLock.lock()
                self.publicIPRequest = nil
                self.lifecycleLock.unlock()
                self.publicIP = result
                self.publishIfRunning(interfaces: self.interfaces, processes: self.processes, assertions: self.assertions, containers: self.containers)
            }
        }
        lifecycleLock.lock()
        guard !cancelled else {
            lifecycleLock.unlock()
            request.cancel()
            return
        }
        publicIPRequest = request
        request.start()
        lifecycleLock.unlock()
    }


    private func publishIfRunning(interfaces: [NetworkInterfaceSnapshot], processes: [ProcessRow], assertions: [PowerAssertionRow], containers: ContainerRuntimeStatus) {
        guard !isCancelled, case .running = state else { return }
        let snapshot = DetailSnapshot(generation: generation, timestamp: Date(), interfaces: interfaces, publicIP: publicIP, powerAssertions: assertions, processes: processes, containers: containers)
        DispatchQueue.main.async { [weak self, publish] in
            guard let self, !self.isCancelled else { return }
            publish(snapshot)
        }
    }
}
