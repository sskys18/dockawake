import Foundation

protocol DashboardScheduledTask: AnyObject {
    func cancel()
}

protocol Scheduling: AnyObject {
    @discardableResult
    func scheduleImmediately(_ handler: @escaping () -> Void) -> DashboardScheduledTask

    @discardableResult
    func schedule(after delay: TimeInterval, repeating interval: TimeInterval?, _ handler: @escaping () -> Void) -> DashboardScheduledTask
}

final class DispatchScheduler: Scheduling {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    @discardableResult
    func scheduleImmediately(_ handler: @escaping () -> Void) -> DashboardScheduledTask {
        let task = DispatchScheduledTask()
        queue.async {
            guard task.isActive else { return }
            handler()
            task.cancel()
        }
        return task
    }

    @discardableResult
    func schedule(after delay: TimeInterval, repeating interval: TimeInterval? = nil, _ handler: @escaping () -> Void) -> DashboardScheduledTask {
        let task = DispatchScheduledTask()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        task.setTimer(timer)
        let deadline = DispatchTime.now() + max(0, delay)
        if let interval {
            timer.schedule(deadline: deadline, repeating: max(0.001, interval))
        } else {
            timer.schedule(deadline: deadline)
        }
        timer.setEventHandler { [weak task] in
            guard let task, task.isActive else { return }
            handler()
            if interval == nil {
                task.cancel()
            }
        }
        timer.resume()
        return task
    }
}

private final class DispatchScheduledTask: DashboardScheduledTask {
    private let lock = NSLock()
    private var active = true
    private var timer: DispatchSourceTimer?

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func setTimer(_ timer: DispatchSourceTimer) {
        lock.lock()
        if active {
            self.timer = timer
            lock.unlock()
        } else {
            lock.unlock()
            timer.cancel()
        }
    }

    func cancel() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        active = false
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
    }
}
