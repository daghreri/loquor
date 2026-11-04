import Carbon
import Foundation
import LoquorCore

/// The language of the current keyboard layout, kept up to date as the user
/// switches layouts. Only consulted when Arabic is turned on.
@MainActor
final class KeyboardLayout: ObservableObject {
    @Published private(set) var language: DictationLanguage = .english
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        var languages: [String] = []
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String] ?? []
        }
        let now = DictationLanguage.forKeyboard(languages: languages)
        if now != language { language = now }
    }
}
