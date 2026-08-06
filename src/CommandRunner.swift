import Foundation
import Darwin

struct CommandResult: Equatable {
    let status: Int32?
    let output: Data
    let timedOut: Bool
    let exceededOutputLimit: Bool

    var succeeded: Bool { status == 0 && !timedOut && !exceededOutputLimit }
}

protocol CommandRunning {
    func run(executable: String, arguments: [String], outputLimit: Int, timeout: TimeInterval) -> CommandResult
}

protocol CommandCancelling: AnyObject {
    func cancelActiveCommand()
}

final class CommandRunner: CommandRunning, CommandCancelling {
    private let processLock = NSLock()
    private var activeProcess: Process?
    private var cancelled = false

    func run(executable: String, arguments: [String], outputLimit: Int = 64 * 1024, timeout: TimeInterval = 5) -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let lock = NSLock()
        var output = Data()
        var exceededLimit = false
        let finished = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            let remaining = max(0, outputLimit - output.count)
            if data.count > remaining {
                output.append(data.prefix(remaining))
                exceededLimit = true
                process.terminate()
            } else {
                output.append(data)
            }
        }
        process.terminationHandler = { _ in finished.signal() }

        processLock.lock()
        if cancelled {
            processLock.unlock()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: nil, output: Data(), timedOut: false, exceededOutputLimit: false)
        }
        activeProcess = process
        do {
            try process.run()
            processLock.unlock()
        } catch {
            activeProcess = nil
            processLock.unlock()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: nil, output: Data(), timedOut: false, exceededOutputLimit: false)
        }

        let didFinish = finished.wait(timeout: .now() + max(0.1, timeout)) == .success
        var terminated = didFinish
        if !terminated {
            process.terminate()
            terminated = finished.wait(timeout: .now() + 1) == .success
        }
        if !terminated {
            kill(process.processIdentifier, SIGKILL)
            terminated = finished.wait(timeout: .now() + 1) == .success
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        // Only an exited child guarantees the write end is closed, so the EOF read stays bounded.
        let trailing = terminated ? outputPipe.fileHandleForReading.readDataToEndOfFile() : Data()
        try? outputPipe.fileHandleForReading.close()
        lock.lock()
        let remaining = max(0, outputLimit - output.count)
        output.append(trailing.prefix(remaining))
        if trailing.count > remaining { exceededLimit = true }
        let captured = output
        let exceeded = exceededLimit
        lock.unlock()
        processLock.lock()
        activeProcess = nil
        processLock.unlock()
        return CommandResult(status: terminated ? process.terminationStatus : nil, output: captured, timedOut: !didFinish, exceededOutputLimit: exceeded)
    }

    func cancelActiveCommand() {
        processLock.lock()
        cancelled = true
        let process = activeProcess
        if process?.isRunning == true {
            process?.terminate()
        }
        processLock.unlock()
    }
}
