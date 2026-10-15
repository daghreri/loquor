import Foundation
import FluidAudio

/// Where the speech model lives, so a release controls exactly what it runs:
///
/// 1. Inside the app (`Contents/Resources/Models`), for an offline build made
///    with `scripts/build-app.sh --bundle-model`. Nothing is downloaded.
/// 2. Otherwise in Loquor's own folder, ~/Library/Application Support/Loquor/Models,
///    downloaded once on first launch from Hugging Face at a pinned commit.
///
/// The model is pinned to one Hugging Face commit, so an upstream change can't
/// silently swap what a released Loquor runs.
enum ModelStore {
    static let repo = "FluidInference/parakeet-tdt-0.6b-v2-coreml"
    /// Hugging Face commit of `repo` (2025-09-25). Change only together with a test.
    static let pinnedRevision = "ee09c569f73759e6d44c9bd16766f477b2b36d39"
    static let folderName = "parakeet-tdt-0.6b-v2"

    static var bundled: URL? {
        guard let dir = Bundle.main.resourceURL?.appending(path: "Models/\(folderName)"),
              FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return dir
    }

    static let downloadRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Loquor/Models")

    static var downloaded: URL { downloadRoot.appending(path: folderName) }

    /// The folder in use (for Settings › About).
    static var location: URL { bundled ?? downloaded }

    static func pin() {
        ModelRegistry.revisionOverrides[repo] = pinnedRevision
    }

    /// Developer Macs from before this change have the model in FluidAudio's shared
    /// cache; copy it instead of downloading 450 MB again. FluidAudio checks the
    /// copy against the pinned commit and downloads anything that doesn't match.
    static func adoptSharedCache() {
        let fm = FileManager.default
        let shared = AsrModels.defaultCacheDirectory(for: .v2)
        guard !fm.fileExists(atPath: downloaded.path), fm.fileExists(atPath: shared.path) else { return }
        try? fm.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
        try? fm.copyItem(at: shared, to: downloaded)
    }
}
