import Foundation

/// The language a dictation is transcribed in. English is always available;
/// Arabic only when the user turns it on (Settings › General › Languages).
public enum DictationLanguage: String, Codable, Sendable, CaseIterable {
    case english = "en"
    case arabic = "ar"

    /// Shown on the indicator while listening.
    public var label: String {
        switch self {
        case .english: "English"
        case .arabic: "عربي"
        }
    }

    /// The language for a keyboard layout's language codes (macOS lists the
    /// primary one first). Anything that isn't Arabic dictates in English.
    public static func forKeyboard(languages: [String]) -> DictationLanguage {
        guard let primary = languages.first?.lowercased() else { return .english }
        return primary == "ar" || primary.hasPrefix("ar-") ? .arabic : .english
    }

    /// Which language a dictation uses: the keyboard decides only when Arabic is
    /// turned on; otherwise the layout is ignored and it's always English.
    public static func choose(arabicEnabled: Bool, keyboard: DictationLanguage) -> DictationLanguage {
        arabicEnabled ? keyboard : .english
    }
}
