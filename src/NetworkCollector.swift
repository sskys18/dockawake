import Foundation
import Darwin

final class NetworkCollector {
    private struct CounterSample {
        let received: UInt64
        let sent: UInt64
        let timestampNanoseconds: UInt64
    }

    private struct InterfaceData {
        var flags: UInt32 = 0
        var addresses = Set<String>()
        var linkSpeed: UInt64?
        var receivedBytes: UInt64?
        var sentBytes: UInt64?
    }

    private var previousCounters: [String: CounterSample] = [:]

    /// Collects one all-interface snapshot. Counter baselines belong only to this collector instance.
    func collect() -> [NetworkInterfaceSnapshot] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        var interfaces: [String: InterfaceData] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            guard let namePointer = entry.ifa_name else {
                cursor = entry.ifa_next
                continue
            }
            let name = String(cString: namePointer)
            var data = interfaces[name] ?? InterfaceData()
            data.flags |= UInt32(entry.ifa_flags)
            if let address = numericAddress(entry.ifa_addr) {
                data.addresses.insert(address)
            }
            if let statistics = entry.ifa_data?.assumingMemoryBound(to: if_data.self) {
                let value = statistics.pointee
                if value.ifi_baudrate > 0 { data.linkSpeed = UInt64(value.ifi_baudrate) }
                data.receivedBytes = UInt64(value.ifi_ibytes)
                data.sentBytes = UInt64(value.ifi_obytes)
            }
            interfaces[name] = data
            cursor = entry.ifa_next
        }

        let now = DispatchTime.now().uptimeNanoseconds
        var currentCounters: [String: CounterSample] = [:]
        let rows = interfaces.keys.sorted().map { name -> NetworkInterfaceSnapshot in
            let data = interfaces[name]!
            let received = data.receivedBytes.map(Availability.available) ?? .unavailable
            let sent = data.sentBytes.map(Availability.available) ?? .unavailable
            let rates = rate(for: name, received: data.receivedBytes, sent: data.sentBytes, now: now)
            if let receivedBytes = data.receivedBytes, let sentBytes = data.sentBytes {
                currentCounters[name] = CounterSample(received: receivedBytes, sent: sentBytes, timestampNanoseconds: now)
            }
            return NetworkInterfaceSnapshot(
                name: name,
                flags: data.flags,
                addresses: data.addresses.sorted(),
                linkSpeedBitsPerSecond: data.linkSpeed.map(Availability.available) ?? .unavailable,
                receivedBytes: received,
                sentBytes: sent,
                receivedRateBytesPerSecond: rates.received,
                sentRateBytesPerSecond: rates.sent)
        }
        previousCounters = currentCounters
        return rows
    }

    func reset() {
        previousCounters.removeAll()
    }

    private func rate(for name: String, received: UInt64?, sent: UInt64?, now: UInt64) -> (received: Availability<Double>, sent: Availability<Double>) {
        guard let received, let sent, let previous = previousCounters[name],
              received >= previous.received, sent >= previous.sent, now > previous.timestampNanoseconds else {
            return (.unavailable, .unavailable)
        }
        let elapsed = Double(now - previous.timestampNanoseconds) / 1_000_000_000
        guard elapsed > 0 else { return (.unavailable, .unavailable) }
        return (
            .available(Double(received - previous.received) / elapsed),
            .available(Double(sent - previous.sent) / elapsed))
    }

    private func numericAddress(_ address: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let address else { return nil }
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = family == AF_INET ? socklen_t(MemoryLayout<sockaddr_in>.size) : socklen_t(MemoryLayout<sockaddr_in6>.size)
        let result = getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard result == 0 else { return nil }
        return String(cString: host)
    }
}
