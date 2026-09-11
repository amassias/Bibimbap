import BibimbapLocalization
import BibimbapFeatures
import SwiftUI

/// Barre d'actions, visible uniquement quand il y a quelque chose à appliquer ou à signaler.
struct PendingChangesBar: View {
    @Bindable var model: AppModel
    @State private var isShowingDetail = false

    var body: some View {
        VStack(spacing: 0) {
            if let result = model.lastResult, !model.hasPendingChanges {
                resultBanner(result)
            }

            if let progress = model.writeProgress,
               case .writing = model.connection {
                HStack(spacing: Theme.Space.medium) {
                    ProgressView(value: progress.fraction)
                    Text(L10n.format(
                        "%d/%d · %@",
                        progress.completed,
                        progress.total,
                        progress.currentOperation ?? L10n.string("Vérification terminée")
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, Theme.Space.small)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.string("Write progress"))
            }

            HStack(spacing: Theme.Space.large) {
                Button {
                    isShowingDetail.toggle()
                } label: {
                    HStack(spacing: Theme.Space.small) {
                        Text(L10n.string("Pending Changes"))
                            .font(.callout.weight(.medium))
                        Text("\(model.pendingChanges.count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(
                                Circle().fill(
                                    model.hasPendingChanges
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.45)
                                )
                            )
                        if model.hasPendingChanges {
                            Image(systemName: "chevron.up")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isShowingDetail ? 180 : 0))
                                .animates(isShowingDetail)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!model.hasPendingChanges)
                .accessibilityHint(L10n.string("Show pending change details"))

                if let blocking = model.validationIssues.first(where: \.isBlocking) {
                    Label(blocking.message, systemImage: "exclamationmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                } else if let warning = model.validationIssues.first {
                    Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Spacer()

                // Le raccourci est rappelé dans le bouton qu'il déclenche, pas dans une
                // colonne séparée : une ligne « ⌘R Revert ⌘↩ Apply » posée à côté des
                // boutons se lisait comme une seconde paire de commandes.
                //
                // Les deux raccourcis sont déclarés une seule fois, dans les commandes de
                // la scène. Les redéclarer ici en ferait une paire concurrente, alors que
                // cette barre disparaît dans Réglages et tant qu'aucun périphérique n'est
                // relu.
                Button {
                    model.revert()
                } label: {
                    HStack(spacing: Theme.Space.snug) {
                        Text(L10n.string("Revert"))
                        ShortcutHint("⌘R")
                    }
                }
                .disabled(!model.hasPendingChanges)

                Button {
                    Task { await model.apply() }
                } label: {
                    HStack(spacing: Theme.Space.snug) {
                        Text(L10n.string("Apply"))
                        ShortcutHint("⌘↩", onAccent: true)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canApply)
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.vertical, Theme.Space.medium)

            if isShowingDetail, model.hasPendingChanges {
                detailList
            }
        }
        .background(.bar)
        .animates(model.hasPendingChanges, using: Theme.Motion.layout)
        .animates(isShowingDetail, using: Theme.Motion.layout)
    }

    private var detailList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.pendingChanges) { change in
                    HStack(spacing: 10) {
                        Text(change.group.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text(change.label)
                        Spacer()
                        Text(change.before)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(change.after)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: 160)
    }

    @ViewBuilder
    private func resultBanner(_ result: WriteResult) -> some View {
        switch result.outcome {
        case .succeeded:
            banner(
                systemImage: "checkmark.circle.fill",
                tint: .green,
                title: L10n.string( "Réglages appliqués et relus."),
                detail: nil
            )
        case .failedAndRestored(let failure):
            banner(
                systemImage: "arrow.uturn.backward.circle.fill",
                tint: .orange,
                title: L10n.string( "Échec de l'écriture — l'état précédent a été restauré."),
                detail: failure
            )
        case .failedAndUncertain(let failure, let uncertain):
            // Le cas qu'il ne faut surtout pas édulcorer : on nomme précisément les
            // réglages dont on ne connaît plus l'état côté matériel.
            banner(
                systemImage: "exclamationmark.triangle.fill",
                tint: .red,
                title: L10n.string( "État matériel incertain."),
                detail: failure + "\n" + L10n.string( "Réglages non restaurés : ")
                    + uncertain.joined(separator: ", ")
            )
        }
    }

    private func banner(systemImage: String, tint: Color, title: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(model.requiresExplicitReread
                   ? L10n.string("Récupérer l'état matériel")
                   : model.hasPendingChanges
                       ? L10n.string("Relire et comparer")
                       : L10n.string("Relire")) {
                Task {
                    if model.requiresExplicitReread {
                        await model.recoverUncertainHardware()
                    } else {
                        await model.rereadAndCompare()
                    }
                }
            }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
