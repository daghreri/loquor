import AppKit
import LoquorCore
@preconcurrency import UserNotifications

/// Checks GitHub once a day for a newer Loquor release. The only data sent is a
/// plain request for the latest release; nothing about the user or their Mac.
/// Installing stays manual: download the DMG and drag it to Applications.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var automatic: Bool {
        didSet {
            UserDefaults.standard.set(automatic, forKey: "checkForUpdates")
            schedule()
        }
    }
    @Published private(set) var available: Updates.Release?
    @Published private(set) var lastResult: String?

    var onLog: (String) -> Void = { _ in }
    private var timer: Timer?

    /// The running version; `--pretend-version 0.0.1` (development) fakes an old one.
    let current: String = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--pretend-version"), i + 1 < args.count { return args[i + 1] }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }()

    init() {
        automatic = UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true
    }

    /// Call at launch: a first check shortly after, then daily.
    func start() { schedule(firstIn: 10) }

    private func schedule(firstIn delay: TimeInterval = Updates.interval) {
        timer?.invalidate()
        timer = nil
        guard automatic else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.check(manual: false)
                self?.schedule()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func check(manual: Bool) {
        Task {
            var request = URLRequest(url: Updates.latestReleaseURL, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Loquor/\(current)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let latest = Updates.parse(data)
            else {
                lastResult = "Couldn't reach GitHub."
                onLog("update check failed")
                return
            }
            if Updates.isNewer(latest.version, than: current) {
                available = latest
                lastResult = "Loquor \(latest.version) is available."
                onLog("update available: \(latest.version) (running \(current))")
                notifyOnce(latest)
            } else {
                available = nil
                lastResult = "You have the latest version (\(current))."
            }
        }
    }

    func openDownload() {
        if let page = available?.page { NSWorkspace.shared.open(page) }
    }

    /// One quiet notification per new version (delivered to Notification Center
    /// without asking first; the menu shows it too).
    private func notifyOnce(_ release: Updates.Release) {
        let key = "notifiedUpdate"
        guard UserDefaults.standard.string(forKey: key) != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: key)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .provisional]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Loquor \(release.version) is available"
            content.body = "Open the Loquor menu and choose Download Update."
            center.add(UNNotificationRequest(identifier: "update-\(release.version)", content: content, trigger: nil))
        }
    }
}
