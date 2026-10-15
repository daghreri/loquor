import Foundation
import Security

/// The Anthropic API key, in the login Keychain only. Never logged, never
/// written to a file, never shown again after it's saved.
///
/// Reading the secret can make macOS ask for the login password: without an Apple
/// Developer Team ID the item's partition list holds the build's cdhash, which every
/// update changes. So the secret is read at most once per launch and kept in memory
/// (for the app's lifetime), and "is there a key?" reads only the item's attributes,
/// which never prompts. A locked login keychain also reads as "needs approval".
@MainActor
enum Keychain {
    private static var cached: String?
    private static let service = "com.daghreri.loquor"
    private static let account = "anthropic-api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ key: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        // Not synced: kSecAttrSynchronizable isn't set, so it stays in this Mac's login
        // keychain. (The "ThisDeviceOnly" accessibility is only enforced by the
        // data-protection keychain, which needs a Team ID; kept for when Loquor has one.)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
        cached = key
        return true
    }

    static func load() -> String? {
        if let cached { return cached }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        cached = String(data: data, encoding: .utf8)
        return cached
    }

    enum Access {
        case noKey, allowed, needsApproval
    }

    /// Reads the key only if macOS lets Loquor do so without asking. Used during
    /// dictation, so a password prompt never appears mid-sentence.
    static func loadSilently() -> String? {
        if let cached { return cached }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        // The login keychain's per-app prompt ignores kSecUseAuthenticationUIFail (tested:
        // it still asked). Turning user interaction off for this one read makes a read
        // that would prompt fail with errSecInteractionNotAllowed instead. The API is
        // deprecated but it's the only switch for file-based keychain ACL prompts.
        SecKeychainSetUserInteractionAllowed(false)
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        SecKeychainSetUserInteractionAllowed(true)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        cached = String(data: data, encoding: .utf8)
        return cached
    }

    /// The Settings step: is there a key, and can Loquor read it without a prompt?
    static var access: Access {
        guard hasKey else { return .noKey }
        return loadSilently() != nil ? .allowed : .needsApproval
    }

    /// Whether a key is saved, without reading the secret (no password prompt).
    static var hasKey: Bool {
        if cached != nil { return true }
        var q = query
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
        cached = nil
    }
}
