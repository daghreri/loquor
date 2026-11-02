import Foundation

/// Release checks against GitHub. Pure: the app does the request.
public enum Updates {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/daghreri/loquor/releases/latest")!
    /// How often the app checks on its own.
    public static let interval: TimeInterval = 24 * 60 * 60

    public struct Release: Equatable, Sendable {
        public let version: String   // "0.1.1" (no leading v)
        public let page: URL         // the release page, with the downloads

        public init(version: String, page: URL) {
            self.version = version
            self.page = page
        }
    }

    /// Reads GitHub's "latest release" JSON. Drafts and pre-releases don't count.
    public static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true
        else { return nil }
        return Release(version: normalize(tag), page: page)
    }

    /// True when `candidate` is a later version than `current` ("0.1.10" > "0.1.9").
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    static func parts(_ version: String) -> [Int] {
        normalize(version).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
