import Foundation
import Darwin
import IOKit.pwr_mgt

final class PowerAssertionCollector {
    /// Returns `.unavailable` when IOKit cannot provide the assertion dictionary.
    /// This is intentionally read-only and unrelated to pmset's SleepDisabled setting.
    func collect() -> Availability<[PowerAssertionRow]> {
        var unmanaged: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsByProcess(&unmanaged)
        guard result == kIOReturnSuccess else {
            return .unavailable
        }
        let dictionary = unmanaged?.takeRetainedValue() as NSDictionary?
        guard let dictionary else { return .unavailable }
        var rows: [PowerAssertionRow] = []
        for (pidKey, value) in dictionary {
            guard let ownerPID = (pidKey as? NSNumber)?.int32Value,
                  let assertions = value as? [[String: Any]] else {
                continue
            }
            let ownerName = processName(for: ownerPID)
            for fields in assertions {
                let type = fields["AssertType"] as? String ?? "Unknown"
                let reason = fields["HumanReadableReason"] as? String
                    ?? fields["Details"] as? String
                    ?? fields["AssertName"] as? String
                rows.append(PowerAssertionRow(
                    type: type,
                    ownerPID: ownerPID,
                    ownerName: ownerName,
                    reason: reason))
            }
        }
        return .available(rows.sorted { $0.id < $1.id })
    }

    private func processName(for pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: Int(MAXCOMLEN))
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        let value = String(cString: name)
        return value.isEmpty ? nil : value
    }
}
