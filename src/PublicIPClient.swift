import Foundation
import Darwin
import OSLog

/// A single visible-session request. It is created suspended so its owner can register it before start.
final class PublicIPRequest: DashboardScheduledTask {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private let task: URLSessionDataTask
    private let onCancel: () -> Void

    fileprivate init(task: URLSessionDataTask, onCancel: @escaping () -> Void) {
        self.task = task
        self.onCancel = onCancel
    }

    func start() {
        lock.lock()
        guard !started, !cancelled else { lock.unlock(); return }
        started = true
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        onCancel()
        task.cancel()
    }
}

final class PublicIPClient {
    static let endpoint = URL(string: "https://api.ipify.org?format=json")!

    /// Makes one request to the fixed endpoint. The caller owns start and cancellation.
    func makeRequest(completion: @escaping (Availability<String>) -> Void) -> PublicIPRequest {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false

        let delegate = PublicIPDelegate(completion: completion)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: URLRequest(url: Self.endpoint, timeoutInterval: 5))
        delegate.attach(session: session, task: task)
        return PublicIPRequest(task: task) { [weak delegate] in
            delegate?.cancel()
        }
    }
}

private final class PublicIPDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let logger = Logger(subsystem: "com.sskys.dockawake", category: "publicIP")
    private let lock = NSLock()
    private let completion: (Availability<String>) -> Void
    private var delivered = false
    private var data = Data()
    private weak var session: URLSession?
    private weak var task: URLSessionDataTask?

    init(completion: @escaping (Availability<String>) -> Void) {
        self.completion = completion
    }

    func attach(session: URLSession, task: URLSessionDataTask) {
        self.session = session
        self.task = task
    }
    func cancel() {
        lock.lock()
        guard !delivered else { lock.unlock(); return }
        delivered = true
        let session = self.session
        lock.unlock()
        session?.invalidateAndCancel()
        logger.info("public IP request cancelled")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !delivered else { lock.unlock(); return }
        self.data.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == PublicIPClient.endpoint.host?.lowercased() else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Availability<String>
        if error != nil {
            result = .unavailable
        } else if let response = task.response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode),
                  let ip = validatedIPAddress(from: data) {
            result = .available(ip)
        } else {
            result = .unavailable
        }
        deliver(result, session: session)
        logger.info("public IP request completed with availability \(result.value == nil ? "unavailable" : "available", privacy: .public)")
    }

    private func deliver(_ result: Availability<String>, session: URLSession) {
        lock.lock()
        guard !delivered else { lock.unlock(); return }
        delivered = true
        lock.unlock()
        session.finishTasksAndInvalidate()
        completion(result)
    }

    private func validatedIPAddress(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = object["ip"] as? String,
              !ip.isEmpty else {
            return nil
        }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET, ip, &ipv4) == 1 || inet_pton(AF_INET6, ip, &ipv6) == 1 else {
            return nil
        }
        return ip
    }
}
