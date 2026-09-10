import SwiftUI
import AppKit

/// Picks the vault root and the depth courses sit at, and — the part that matters — shows
/// what that combination is about to mean.
///
/// Choosing a root one level too high is a silent mistake otherwise: with the wrong root,
/// the same depth quietly turns intermediate folders into subjects and nothing says so
/// until recordings start landing in the wrong place. The preview names the count and lists
/// examples, so a real vault immediately shows its own oddities — a branch shaped
/// differently shows up in the sample as folders nobody would call a subject.
struct VaultSetupView: View {
    /// True on the first run, where the sheet cannot be dismissed without a usable root.
    let isInitialSetup: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var rootPath: String = VaultSettings.root.path
    @State private var depth: Int = VaultSettings.courseDepth
    @State private var preview: [CourseOption] = []
    @State private var rootExists = true

    private var root: URL { URL(fileURLWithPath: rootPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isInitialSetup ? "Choisissez votre dossier de cours" : "Dossier de cours")
                .font(.title3)

            if isInitialSetup {
                Text("Praxis lit vos matières directement dans l'arborescence de ce dossier. Créer un dossier y crée une matière.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Image(systemName: rootExists ? "folder" : "exclamationmark.triangle")
                    .foregroundStyle(rootExists ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                Text(rootPath)
                    .font(.caption)
                    .foregroundStyle(rootExists ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Choisir…", action: pickRoot)
                    .controlSize(.small)
            }

            Stepper("Profondeur des matières : \(depth)", value: $depth, in: 1...6)
                .onChange(of: depth) { refresh() }
            Text("Nombre de niveaux entre le dossier racine et une matière. « 2A/INP/Automatique » vaut 3. Une matière située ailleurs se choisit à la main dans le sélecteur.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            previewSection

            Spacer(minLength: 0)

            HStack {
                if !rootExists {
                    Button("Créer un squelette ici", action: createSkeleton)
                        .controlSize(.small)
                } else if preview.isEmpty {
                    Button("Créer un squelette de matières", action: createSkeleton)
                        .controlSize(.small)
                }
                Spacer()
                if !isInitialSetup {
                    Button("Annuler") { dismiss() }
                }
                Button("Utiliser ce dossier", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!rootExists)
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
        .onAppear(perform: refresh)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !rootExists {
                Text("Ce dossier n'existe pas.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if preview.isEmpty {
                Text("Aucune matière trouvée à cette profondeur.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("\(preview.count) dossier\(preview.count > 1 ? "s seront traités" : " sera traité") comme matière\(preview.count > 1 ? "s" : "").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(preview.prefix(8)) { course in
                            Text(course.vaultPath)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        if preview.count > 8 {
                            Text("… et \(preview.count - 8) autres")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
            }
        }
    }

    private func refresh() {
        var isDirectory: ObjCBool = false
        rootExists = FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory) && isDirectory.boolValue
        preview = rootExists ? CourseDirectoryScanner.scan(root: root, depth: depth) : []
    }

    private func pickRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        panel.message = "Choisissez le dossier contenant vos matières"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootPath = url.path
        refresh()
    }

    /// Built to the configured depth, not to a fixed shape: a two-level skeleton under a
    /// depth-three setting would produce a vault where nothing is ever detected.
    private func createSkeleton() {
        let sample = ["Année 1", "Groupe A", "Matière 1"]
        var folder = root
        for level in 0..<depth {
            folder.appendPathComponent(level < sample.count ? sample[level] : "Niveau \(level + 1)")
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        refresh()
    }

    private func confirm() {
        VaultSettings.root = root
        VaultSettings.courseDepth = depth
        onConfirm()
        dismiss()
    }
}
