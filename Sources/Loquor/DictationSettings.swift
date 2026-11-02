import Foundation
import LoquorCore

/// The longest dictation: 1 minute by default, up to 3 (Settings › General).
@MainActor
final class DictationSettings: ObservableObject {
    @Published var maxSeconds: Int {
        didSet { UserDefaults.standard.set(maxSeconds, forKey: "maxDictationSeconds") }
    }

    init() {
        let saved = UserDefaults.standard.integer(forKey: "maxDictationSeconds")
        maxSeconds = DictationLimits.clamp(saved == 0 ? DictationLimits.defaultSeconds : saved)
    }
}
