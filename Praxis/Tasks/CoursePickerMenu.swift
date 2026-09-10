import SwiftUI

/// One node of the folder tree the picker walks.
struct CourseFolderNode: Identifiable {
    let url: URL
    let name: String
    let relativePath: String
    var children: [CourseFolderNode]

    var id: String { relativePath }
}

/// Browses the real folder tree, with **"choisir ce dossier" offered at every level**.
///
/// The previous cascade was hardcoded to Année → Pôle → Cours and could only ever return a
/// folder three levels down. That fails on a real vault in both directions: a course folder
/// is never a leaf — it holds `Transcriptions`, `Resumes`, `01 - Cours` and the rest, so
/// stopping at leaves would offer those instead — and some branches sit one level
/// shallower than the others, so stopping at a fixed depth misses them entirely.
///
/// Offering the current folder alongside its subfolders solves both without a rule to
/// learn: descend as far as the course you want, and take it.
struct CoursePickerMenu<Trailing: View>: View {
    let tree: [CourseFolderNode]
    let onSelect: (String) -> Void
    /// Extra items after a divider — "Aucun" for a task, "Autre dossier…" for a recording.
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ForEach(tree) { node in
            CourseFolderMenu(node: node, onSelect: onSelect)
        }
        Divider()
        trailing()
    }
}

/// One folder and, recursively, its subfolders.
///
/// A nominal type rather than a `@ViewBuilder` function: a function returning `some View`
/// that calls itself defines its own opaque type in terms of itself, which the compiler
/// refuses. A struct referring to itself is fine.
private struct CourseFolderMenu: View {
    let node: CourseFolderNode
    let onSelect: (String) -> Void

    var body: some View {
        if node.children.isEmpty {
            Button(node.name) { onSelect(node.relativePath) }
        } else {
            Menu(node.name) {
                Button("Choisir « \(node.name) »") { onSelect(node.relativePath) }
                Divider()
                ForEach(node.children) { child in
                    CourseFolderMenu(node: child, onSelect: onSelect)
                }
            }
        }
    }
}

extension CoursePickerMenu where Trailing == EmptyView {
    init(tree: [CourseFolderNode], onSelect: @escaping (String) -> Void) {
        self.init(tree: tree, onSelect: onSelect, trailing: { EmptyView() })
    }
}

enum CourseFolderTree {
    /// Builds the browsable tree under the root.
    ///
    /// Stops one level below the configured course depth: deep enough to reach a course and
    /// the odd one that sits deeper, shallow enough that the menu does not open onto the
    /// hundreds of `01 - Cours` and `Transcriptions` folders underneath them. On the real
    /// vault that is 3 levels of menu over 50 courses, instead of 300 entries.
    static func build(
        root: URL = VaultSettings.root,
        maxDepth: Int = VaultSettings.courseDepth
    ) -> [CourseFolderNode] {
        children(of: root, root: root, remainingDepth: maxDepth)
    }

    private static func children(of folder: URL, root: URL, remainingDepth: Int) -> [CourseFolderNode] {
        guard remainingDepth > 0 else { return [] }
        return CourseDirectoryScanner.children(of: folder)
            .compactMap { url -> CourseFolderNode? in
                guard let relative = VaultSettings.relativePath(for: url), !relative.isEmpty else { return nil }
                return CourseFolderNode(
                    url: url,
                    name: url.lastPathComponent,
                    relativePath: relative,
                    children: children(of: url, root: root, remainingDepth: remainingDepth - 1)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
