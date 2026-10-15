import Foundation
import Network

/// Whether the Mac is online. When it isn't, cleanup is skipped and the
/// transcript is typed as heard straight away. Offline, the transcript is typed as heard.
@MainActor
final class Connectivity: ObservableObject {
    @Published private(set) var online = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.online = online }
        }
        monitor.start(queue: DispatchQueue(label: "loquor.connectivity"))
    }
}
