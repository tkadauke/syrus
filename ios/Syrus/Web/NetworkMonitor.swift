import Foundation
import Network

/// Reports whether the device currently has a usable network path, so the web
/// shell can distinguish "this device is offline" from "the server is down".
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.syrus.network-monitor")

    /// Invoked on the main queue whenever reachability changes.
    var onChange: ((Bool) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { self?.onChange?(online) }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
