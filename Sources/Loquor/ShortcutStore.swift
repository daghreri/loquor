import Foundation
import LoquorCore

/// The chosen dictation shortcut, kept in the app's preferences.
@MainActor
final class ShortcutStore: ObservableObject {
    private static let key = "shortcut"

    @Published var shortcut: Shortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = .default
        }
    }
}
