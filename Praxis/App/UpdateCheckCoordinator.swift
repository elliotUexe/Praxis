import Foundation
import AppKit

/// Checks GitHub Releases for a newer build than the one currently running and, when one
/// exists, downloads the .dmg and installs it over itself automatically — no Sparkle
/// framework (would need a paid Apple Developer account for notarization to be fully
/// silent-safe), so this is a hand-rolled equivalent. Safe here specifically because the
/// download is always Pierre's own build from his own GitHub Releases over HTTPS, never
/// arbitrary third-party content — clearing the quarantine flag on our own freshly built
/// update is self-maintenance, not a Gatekeeper bypass on untrusted input.
@MainActor
final class UpdateCheckCoordinator: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var latestReleaseURL: URL?
    @Published private(set) var latestDMGURL: URL?
    @Published private(set) var lastError: String?
    /// True once a check has completed and found no release published on GitHub yet — a
    /// normal, expected state during early alpha (before the first tag push), distinct
    /// from `lastError` which means the check itself failed (network, malformed response).
    @Published private(set) var noReleasePublished = false
    @Published private(set) var isUpdating = false
    @Published private(set) var updateStatusText: String?

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
        latestVersion = nil
        latestReleaseURL = nil
        latestDMGURL = nil
        noReleasePublished = false
        lastError = nil
        do {
            var request = URLRequest(url: Self.apiURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "Vérification impossible : réponse inattendue du serveur."
                return
            }
            // 404 means the repo has no published release yet — normal before the first
            // tag push (see .github/workflows/release.yml), not a failure.
            if httpResponse.statusCode == 404 {
                noReleasePublished = true
                return
            }
            guard httpResponse.statusCode == 200 else {
                lastError = "Vérification impossible : le serveur a répondu \(httpResponse.statusCode)."
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            latestReleaseURL = URL(string: release.htmlURL)
            latestDMGURL = release.assets
                .first { $0.name.hasSuffix(".dmg") }
                .flatMap { URL(string: $0.browserDownloadURL) }
        } catch {
            lastError = "Vérification impossible : \(error.localizedDescription)"
        }
    }

    /// Downloads the .dmg, mounts it, stages the .app, then hands off to a detached shell
    /// script (see `launchSwapScriptAndQuit`) that waits for this process to actually
    /// exit before swapping `/Applications/Praxis.app` and relaunching — can't replace our
    /// own running executable in place, so a helper outside our process tree does it.
    func downloadAndInstallUpdate() async {
        guard let dmgURL = latestDMGURL, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            updateStatusText = "Téléchargement de la mise à jour…"
            let (downloadedURL, _) = try await URLSession.shared.download(from: dmgURL)
            let dmgPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("PraxisUpdate-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: downloadedURL, to: dmgPath)

            updateStatusText = "Installation…"
            let mountPoint = FileManager.default.temporaryDirectory
                .appendingPathComponent("PraxisUpdateMount-\(UUID().uuidString)")
            try await run("/usr/bin/hdiutil", ["attach", dmgPath.path, "-nobrowse", "-mountpoint", mountPoint.path])

            let mountedApp = mountPoint.appendingPathComponent("Praxis.app")
            guard FileManager.default.fileExists(atPath: mountedApp.path) else {
                try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
                lastError = "Mise à jour impossible : Praxis.app introuvable dans l'image téléchargée."
                updateStatusText = nil
                return
            }

            let stagedApp = FileManager.default.temporaryDirectory
                .appendingPathComponent("Praxis-\(UUID().uuidString).app")
            try FileManager.default.copyItem(at: mountedApp, to: stagedApp)
            try await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])

            updateStatusText = "Redémarrage…"
            try launchSwapScriptAndQuit(stagedApp: stagedApp, dmgPath: dmgPath)
        } catch {
            lastError = "Mise à jour impossible : \(error.localizedDescription)"
            updateStatusText = nil
        }
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "Praxis.Update",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "\(executable) a échoué (code \(proc.terminationStatus))."]
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Writes a tiny shell script to a temp file and spawns it detached from our process,
    /// then quits — the script polls our PID until it's actually gone, then replaces
    /// `/Applications/Praxis.app`, clears the quarantine flag (see type doc for why that's
    /// safe here), and relaunches. It also cleans up its own staging files and itself.
    private func launchSwapScriptAndQuit(stagedApp: URL, dmgPath: URL) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("praxis-update-\(UUID().uuidString).sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf /Applications/Praxis.app
        cp -R "\(stagedApp.path)" /Applications/Praxis.app
        xattr -cr /Applications/Praxis.app
        rm -rf "\(stagedApp.path)" "\(dmgPath.path)"
        open /Applications/Praxis.app
        rm -f "\(scriptURL.path)"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        try process.run()

        NSApplication.shared.terminate(nil)
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
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private struct ReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
