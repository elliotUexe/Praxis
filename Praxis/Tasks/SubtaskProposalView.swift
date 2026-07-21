import SwiftUI

/// Review screen for the LLM's subtask breakdown — nothing is written to SwiftData until
/// "Valider", same review-before-commit spirit as `needsReview` elsewhere in Praxis.
/// "Régénérer" re-runs the proposal against `task`'s already-*persisted* subtasks (title +
/// done state), not against in-progress edits on this screen — keeps the mental model
/// simple ("the model sees committed progress, not a hypothetical draft") at the cost of
/// re-editing a still-uncommitted draft before regenerating; if Pierre wants that, "Valider"
/// once and reopen instead.
struct SubtaskProposalView: View {
    @EnvironmentObject private var taskStore: TaskStoreCoordinator
    @EnvironmentObject private var localLLM: LocalLLMCoordinator
    @Environment(\.dismiss) private var dismiss

    let task: PraxisTask

    @State private var proposals: [ProposedSubtask] = []
    @State private var hasGeneratedOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Découper avec l'IA").font(.title3)
            Text(task.title).font(.subheadline).foregroundStyle(.secondary)

            if localLLM.isUserDisabled {
                Text("IA locale désactivée (case à cocher dans Enregistrement) — réactivez-la pour générer une proposition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if localLLM.isProposingSubtasks {
                ProgressView("Génération en cours…")
            } else if proposals.isEmpty && hasGeneratedOnce {
                Text("Aucune proposition obtenue — réessayez, ou ajoutez des sous-tâches manuellement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = localLLM.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            List {
                ForEach($proposals) { $proposal in
                    HStack {
                        TextField("Titre", text: $proposal.title)
                            .textFieldStyle(.plain)
                        Spacer()
                        Stepper(
                            "\(proposal.estimatedMinutes) min",
                            value: $proposal.estimatedMinutes,
                            in: 5...480,
                            step: 5
                        )
                        .fixedSize()
                    }
                }
                .onDelete { proposals.remove(atOffsets: $0) }
            }
            .frame(minHeight: 220)

            Button {
                proposals.append(ProposedSubtask(title: "", estimatedMinutes: 30))
            } label: {
                Label("Ajouter une ligne", systemImage: "plus")
            }
            .font(.caption)

            HStack {
                Button("Régénérer") {
                    Task { await generate() }
                }
                .disabled(localLLM.isProposingSubtasks || localLLM.isUserDisabled)

                Spacer()
                Button("Annuler") { dismiss() }
                Button("Valider") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(proposals.isEmpty || proposals.contains { $0.title.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding()
        .frame(width: 460, height: 480)
        .task {
            guard !hasGeneratedOnce else { return }
            await generate()
        }
    }

    private func generate() async {
        let existing = task.subtasks
            .sorted { $0.order < $1.order }
            .map { (title: $0.title, isDone: $0.isDone) }
        let result = await localLLM.proposeSubtasks(
            taskTitle: task.title,
            taskDetail: task.detail,
            taskType: task.type,
            dueDate: task.dueDate,
            existingSubtasks: existing
        )
        hasGeneratedOnce = true
        if !result.isEmpty {
            proposals = result
        }
    }

    private func commit() {
        let baseOrder = task.subtasks.count
        for (index, proposal) in proposals.enumerated() {
            let trimmed = proposal.title.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let subtask = Subtask(
                title: trimmed,
                estimatedMinutes: proposal.estimatedMinutes,
                order: baseOrder + index,
                origin: "llm_local",
                parentTask: task
            )
            taskStore.modelContext.insert(subtask)
        }
        taskStore.save()
        dismiss()
    }
}
