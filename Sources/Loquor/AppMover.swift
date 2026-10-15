import AppKit

/// Permissions and the login item belong to the copy of the app that asked for
/// them. Run from the DMG or Downloads, they'd point at a copy that goes away,
/// so offer to move to /Applications first.
@MainActor
enum AppMover {
    /// Returns true if the app is relaunching from /Applications and this copy should stop.
    static func offerMoveIfNeeded() -> Bool {
        let here = Bundle.main.bundleURL
        let applications = ["/Applications/", FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/"]
        guard !applications.contains(where: { here.path.hasPrefix($0) }),
              !CommandLine.arguments.contains("--no-move"),
              here.pathExtension == "app"  // not `swift run`
        else { return false }

        let alert = NSAlert()
        alert.messageText = "Move Loquor to your Applications folder?"
        alert.informativeText = "macOS ties the Microphone and Accessibility permissions to where the app lives. Running it from here, they'd be lost when this copy goes away."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let target = URL(fileURLWithPath: "/Applications").appending(path: here.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.trashItem(at: target, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: here, to: target)
        } catch {
            let failed = NSAlert(error: error)
            failed.runModal()
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }
}
