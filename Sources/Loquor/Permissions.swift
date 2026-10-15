import AVFoundation
import AppKit
import ApplicationServices

/// The two permissions Loquor needs: Microphone (to record) and Accessibility
/// (to see the dictation key and paste into other apps).
@MainActor
final class Permissions: ObservableObject {
    enum Microphone {
        case notAsked, granted, denied

        var granted: Bool { self == .granted }
    }

    @Published private(set) var microphone: Microphone = .notAsked
    @Published private(set) var accessibility = false
    /// Access to the Anthropic key in the Keychain (only matters when cleanup has a key).
    @Published private(set) var keychain: Keychain.Access = .noKey

    var allGranted: Bool { microphone.granted && accessibility }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notAsked
        default: microphone = .denied
        }
        accessibility = AXIsProcessTrusted()
        keychain = Keychain.access
    }

    /// Reads the key now, in Settings, so macOS asks here and not during a dictation.
    /// Choosing "Always Allow" keeps it quiet until the next update.
    func requestKeychain() {
        _ = Keychain.load()
        refresh()
    }

    /// Asks once with the system prompt; after a denial only System Settings can change it.
    func requestMicrophone() {
        if microphone == .notAsked {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        } else {
            openPrivacyPane("Privacy_Microphone")
        }
    }

    /// Shows the system prompt that leads to Privacy & Security › Accessibility.
    /// macOS doesn't report the change back, so callers poll `refresh()`.
    func requestAccessibility() {
        // The value of kAXTrustedCheckOptionPrompt (that global isn't concurrency-safe in Swift 6).
        let prompt = "AXTrustedCheckOptionPrompt"
        if !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) {
            openPrivacyPane("Privacy_Accessibility")
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
