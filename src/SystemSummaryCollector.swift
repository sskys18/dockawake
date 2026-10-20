import Foundation
import Darwin
import IOKit.ps
import OSLog

struct CPUTickSnapshot: Equatable {
    let busy: UInt64
    let total: UInt64
}

protocol SystemSummaryCollecting {
    func collect(previousCPU: CPUTickSnapshot?) -> (snapshot: DashboardSnapshot, cpu: CPUTickSnapshot?)
}

final class SystemSummaryCollector: SystemSummaryCollecting {
    func collect(previousCPU: CPUTickSnapshot?) -> (snapshot: DashboardSnapshot, cpu: CPUTickSnapshot?) {
        let cpuSample = readCPUTicks()
        let cpu = cpuMetric(current: cpuSample, previous: previousCPU)
        let battery = batteryMetric()
        return (
            DashboardSnapshot(
                timestamp: Date(),
                cpu: cpu,
                memory: memoryMetric(),
                storage: storageMetric(),
                battery: battery.charge,
                batteryPower: battery.power),
            cpuSample)
    }

    private func cpuMetric(current: CPUTickSnapshot?, previous: CPUTickSnapshot?) -> Availability<MetricDisplay> {
        guard let current, let previous,
              current.busy >= previous.busy, current.total > previous.total else {
            return .unavailable
        }
        let busyDelta = current.busy - previous.busy
        let totalDelta = current.total - previous.total
        guard totalDelta > 0, busyDelta <= totalDelta else { return .unavailable }
        let percent = Double(busyDelta) * 100 / Double(totalDelta)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return .available(MetricDisplay(value: percent, text: DashboardFormat.percent(percent), detail: "\(cores) cores"))
    }

    private func memoryMetric() -> Availability<MetricDisplay> {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return .unavailable
        }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return .unavailable }
        let pages = UInt64(info.active_count) + UInt64(info.inactive_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        let used = pages.multipliedReportingOverflow(by: UInt64(pageSize))
        let total = ProcessInfo.processInfo.physicalMemory
        guard !used.overflow, total > 0 else { return .unavailable }
        let percent = Double(used.partialValue) * 100 / Double(total)
        return .available(MetricDisplay(
            value: percent,
            text: DashboardFormat.percent(percent),
            detail: "\(DashboardFormat.bytes(used.partialValue)) of \(DashboardFormat.bytes(total))"))
    }

    private func storageMetric() -> Availability<MetricDisplay> {
        let root = URL(fileURLWithPath: "/")
        guard let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity,
              total > 0, available >= 0, available <= total else {
            return .unavailable
        }
        let percent = Double(total - available) * 100 / Double(total)
        return .available(MetricDisplay(
            value: percent,
            text: DashboardFormat.percent(percent),
            detail: "\(DashboardFormat.bytes(UInt64(available))) free of \(DashboardFormat.bytes(UInt64(total)))"))
    }

    private func batteryMetric() -> (charge: Availability<MetricDisplay>, power: Availability<BatteryPower>) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (.unavailable, .unavailable)
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0, current >= 0, current <= maximum else {
                continue
            }
            let percent = Double(current) * 100 / Double(maximum)
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let power: BatteryPower = charging ? .charging : (onAC ? .pluggedNotCharging : .onBattery)
            return (
                .available(MetricDisplay(value: percent, text: DashboardFormat.percent(percent))),
                .available(power))
        }
        return (.unavailable, .unavailable)
    }

    private func readCPUTicks() -> CPUTickSnapshot? {
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0
        guard host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount) == KERN_SUCCESS,
            let processorInfo else {
            return nil
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: processorInfo)), vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)
        for processor in 0..<Int(processorCount) {
            let offset = processor * stride
            let user = UInt64(processorInfo[offset + Int(CPU_STATE_USER)])
            let system = UInt64(processorInfo[offset + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(processorInfo[offset + Int(CPU_STATE_NICE)])
            let idle = UInt64(processorInfo[offset + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return CPUTickSnapshot(busy: busy, total: total)
    }
}

final class SystemSummaryController {
    private let scheduler: Scheduling
    private let collector: SystemSummaryCollecting
    private let collectionQueue = DispatchQueue(label: "com.dockawake.summary", qos: .utility)
    private let logger = Logger(subsystem: "com.sskys.dockawake", category: "summary")
    private let lock = NSLock()
    private var task: DashboardScheduledTask?
    private var running = false
    private var previousCPU: CPUTickSnapshot?
    private var collecting = false
    private var powerSourceSource: CFRunLoopSource?
    var onUpdate: @MainActor (DashboardSnapshot) -> Void

    init(scheduler: Scheduling, collector: SystemSummaryCollecting = SystemSummaryCollector(), onUpdate: @escaping @MainActor (DashboardSnapshot) -> Void) {
        self.scheduler = scheduler
        self.collector = collector
        self.onUpdate = onUpdate
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        logger.info("summary collection started")
        _ = scheduler.scheduleImmediately { [weak self] in self?.collectIfNeeded() }
        observePowerSourceChanges()
        let repeatingTask = scheduler.schedule(after: 5, repeating: 5) { [weak self] in self?.collectIfNeeded() }
        lock.lock()
        if running {
            task = repeatingTask
            lock.unlock()
        } else {
            lock.unlock()
            repeatingTask.cancel()
        }
    }

    func stop() {
        lock.lock()
        running = false
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
        stopObservingPowerSourceChanges()
        logger.info("summary collection stopped")
    }

    /// Charge percentage moves in whole-percent steps, so a 5 second poll never
    /// reflects plugging or unplugging the charger on its own. IOKit posts a
    /// power source change immediately, which is what makes the strip realtime.
    private func observePowerSourceChanges() {
        precondition(Thread.isMainThread)
        guard powerSourceSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<SystemSummaryController>.fromOpaque(context)
                .takeUnretainedValue()
                .collectIfNeeded()
        }, context)?.takeRetainedValue() else {
            logger.error("power source notifications unavailable")
            return
        }
        powerSourceSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func stopObservingPowerSourceChanges() {
        precondition(Thread.isMainThread)
        guard let source = powerSourceSource else { return }
        powerSourceSource = nil
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func collectIfNeeded() {
        lock.lock()
        guard running, !collecting else { lock.unlock(); return }
        collecting = true
        lock.unlock()
        collectionQueue.async { [weak self] in
            guard let self else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime
            let result = self.collector.collect(previousCPU: self.previousCPU)
            self.logger.debug("summary collection finished in \(ProcessInfo.processInfo.systemUptime - startedAt, privacy: .public) seconds")
            self.lock.lock()
            self.previousCPU = result.cpu
            self.collecting = false
            let shouldPublish = self.running
            self.lock.unlock()
            guard shouldPublish else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let shouldPublish = self.running
                self.lock.unlock()
                guard shouldPublish else { return }
                self.onUpdate(result.snapshot)
            }
        }
    }
}
