import BibimbapFeatures
import BibimbapLocalization
import SwiftUI

/// Le choix à faire lorsqu'un brouillon local a survécu à une relecture divergente.
///
/// La bannière reste affichée tant que rien n'est tranché, y compris depuis Réglages : la
/// question n'appartient pas à une section, elle bloque l'application des modifications
/// partout. Aucun de ses deux boutons n'écrit au périphérique — seul Apply le fait.
struct DraftRecoveryBanner: View {
    @Bindable var model: AppModel
    @State private var isShowingConflicts = false

    var body: some View {
        if let recovery = model.draftRecovery {
            VStack(alignment: .leading, spacing: Theme.Space.small) {
                HStack(alignment: .top, spacing: Theme.Space.medium) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        Text(recovery.cause.label)
                            .font(.callout.weight(.medium))
                        Text(summary(recovery))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: Theme.Space.large)

                    if !recovery.conflicts.isEmpty {
                        Button(isShowingConflicts
                               ? L10n.string("Masquer le détail")
                               : L10n.string("Voir le détail")) {
                            isShowingConflicts.toggle()
                        }
                        .buttonStyle(.link)
                    }

                    Button(L10n.string("Conserver mon brouillon")) {
                        model.keepDraftAfterRecovery()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(L10n.string("Adopter les réglages relus")) {
                        model.adoptRemoteAfterRecovery()
                    }

                    Button(L10n.string("Relire et comparer")) {
                        Task { await model.rereadAndCompare() }
                    }
                    .disabled(model.connection.isBusy)
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, Theme.Space.medium)

                if isShowingConflicts, !recovery.conflicts.isEmpty {
                    conflictList(recovery.conflicts)
                }
            }
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .top) { Divider() }
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.string("Modifications non appliquées à trancher"))
            .accessibilityValue(summary(recovery))
            .animates(isShowingConflicts, using: Theme.Motion.layout)
        }
    }

    private func summary(_ recovery: DraftRecovery) -> String {
        L10n.format(
            "%d local change(s), %d read back from the device, %d in conflict.",
            recovery.localChanges.count,
            recovery.remoteChanges.count,
            recovery.conflicts.count
        )
    }

    private func conflictList(_ conflicts: [DraftConflict]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(L10n.string("Réglage")).frame(width: 180, alignment: .leading)
                    Text(L10n.string("Avant")).frame(width: 90, alignment: .leading)
                    Text(L10n.string("Votre brouillon")).frame(width: 120, alignment: .leading)
                    Text(L10n.string("Sur la souris")).frame(width: 120, alignment: .leading)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(conflicts) { conflict in
                    HStack(spacing: 10) {
                        Text(conflict.label).frame(width: 180, alignment: .leading)
                        Text(conflict.baseValue)
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text(conflict.localValue).frame(width: 120, alignment: .leading)
                        Text(conflict.remoteValue).frame(width: 120, alignment: .leading)
                        Spacer()
                    }
                    .font(.callout.monospacedDigit())
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.bottom, Theme.Space.medium)
        }
        .frame(maxHeight: 150)
    }
}

/// Une écriture interrompue laisse le matériel dans un état que seule une relecture
/// explicite peut lever. Tant qu'elle n'a pas eu lieu, Apply reste fermé.
struct UncertainHardwareBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.requiresExplicitReread {
            HStack(alignment: .top, spacing: Theme.Space.medium) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text(L10n.string("État matériel incertain."))
                        .font(.callout.weight(.medium))
                    Text(L10n.string("Une écriture a été interrompue. Relisez le périphérique avant toute nouvelle application ; rien ne sera réécrit automatiquement."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.large)
                Button(L10n.string("Relire et comparer")) {
                    Task { await model.recoverUncertainHardware() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.connection.isBusy)
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.vertical, Theme.Space.medium)
            .background(Color.red.opacity(0.1))
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }
}
