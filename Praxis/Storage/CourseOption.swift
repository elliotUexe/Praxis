import Foundation

/// A course folder, addressed relative to the configured vault root.
///
/// It used to carry `year` and `pole` as stored fields, because the cascade menu was built
/// on a tree shape that was assumed rather than read. With the depth configurable and the
/// shape free, the levels are simply whatever the path says they are.
struct CourseOption: Identifiable, Hashable {
    let vaultPath: String
    var id: String { vaultPath }
    var displayName: String { VaultSettings.displayName(forRelativePath: vaultPath) }
    /// Path components above the course itself — `["2A", "INP"]` for `2A/INP/Automatique`.
    var groupComponents: [String] {
        vaultPath.split(separator: "/").dropLast().map(String.init)
    }
}
