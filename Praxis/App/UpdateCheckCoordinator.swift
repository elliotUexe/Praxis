import Foundation

/// Checks GitHub Releases for a newer build than the one currently running — no auto-
/// installer (Praxis isn't notarized/signed with a paid Apple Developer account, so a
/// silent Sparkle-style install isn't viable yet): this only tells Pierre a new version
/// exists and hands him the release page to download/reinstall himself. Runs once per
/// launch (`ContentView.task`) plus on-demand from Settings.
@MainActor
final class UpdateCheckCoordinator: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var latestReleaseURL: URL?
    @Published private(set) var lastError: String?

    /// Matches the repo Praxis is actually published to (see `git remote -v`) — update
    /// this if the GitHub account/repo ever moves again.
    private static let apiURL = URL(string: "https://api.github.com/repos/elliotUexe/Praxis/releases/latest")!

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var updateAvailable: Bool {
        guard let latestVersion else { return false }
        return Self.isNewer(latestVersion, than: currentVersion)
    }

    func checkForUpdates() async {
        isChecking = true
        defer { isChecking = false }
        do {
            var request = URLRequest(url: Self.apiURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            latestReleaseURL = URL(string: release.htmlURL)
            lastError = nil
        } catch {
            // Silent-ish on launch (no release published yet is an expected 404 during
            // early alpha) — surfaced only as `lastError` for the explicit "Vérifier
            // maintenant" button in Settings, never as a blocking alert.
            lastError = "Vérification impossible : \(error.localizedDescription)"
        }
    }

    /// Compares dotted numeric prefixes only (`0.2.0` from `0.2.0-alpha.1`) — good enough
    /// for Praxis's own alpha tags, not a full semver implementation.
    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        func numericComponents(_ version: String) -> [Int] {
            (version.split(separator: "-").first.map(String.init) ?? version)
                .split(separator: ".")
                .compactMap { Int($0) }
        }
        let a = numericComponents(candidate)
        let b = numericComponents(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
