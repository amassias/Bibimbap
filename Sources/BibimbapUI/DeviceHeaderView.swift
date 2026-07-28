import BibimbapFeatures
import SwiftUI

/// En-tête permanent : périphérique, connexion, batterie, signal, profil, synchronisation.
struct DeviceHeaderView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let snapshot = model.snapshot {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.productName)
                        .font(.headline)
                    HStack(spacing: 6) {
                        syncIndicator
                        Text(syncLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)

                metric(
                    systemImage: snapshot.connection.isWired ? "cable.connector" : "wifi",
                    title: snapshot.connection.label,
                    detail: snapshot.settings.reportRateHertz.formatted(.number) + " Hz"
                )

                if let battery = snapshot.battery {
                    metric(
                        systemImage: batterySymbol(battery.percentage, charging: battery.isCharging),
                        title: String(localized: "Batterie"),
                        detail: "\(battery.percentage) %"
                    )
                }

                if let signal = snapshot.signalStrength {
                    metric(
                        systemImage: "antenna.radiowaves.left.and.right",
                        title: String(localized: "Signal"),
                        detail: "\(signal)/5"
                    )
                }

                if let profile = snapshot.activeProfile, model.capabilities?.supportsProfiles == true {
                    profilePicker(current: profile)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Éléments

    private func metric(systemImage: String, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.callout.monospacedDigit())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) : \(detail)")
    }

    private func profilePicker(current: Int) -> some View {
        Picker(String(localized: "Profil"), selection: Binding(
            get: { current },
            set: { profile in Task { await model.selectProfile(profile) } }
        )) {
            ForEach(0..<3, id: \.self) { index in
                Text("Profil \(index + 1)").tag(index)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 130)
        .accessibilityLabel(String(localized: "Profil actif"))
    }

    @ViewBuilder
    private var syncIndicator: some View {
        switch model.connection {
        case .writing, .reading:
            ProgressView()
                .controlSize(.mini)
        case .disconnectedDuringWrite:
            Circle().fill(.orange).frame(width: 7, height: 7)
        case .connected where model.hasPendingChanges:
            Circle().fill(.blue).frame(width: 7, height: 7)
        default:
            Circle().fill(.green).frame(width: 7, height: 7)
        }
    }

    private var syncLabel: String {
        switch model.connection {
        case .reading: String(localized: "Lecture…")
        case .writing: String(localized: "Écriture…")
        case .disconnectedDuringWrite: String(localized: "État matériel incertain")
        case .connected where model.hasPendingChanges: String(localized: "Modifications non appliquées")
        default: String(localized: "Synchronisé")
        }
    }

    private func batterySymbol(_ percentage: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percentage {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<70: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Barre d'actions, visible uniquement quand il y a quelque chose à appliquer ou à signaler.
struct PendingChangesBar: View {
    @Bindable var model: AppModel
    @State private var isShowingDetail = false

    var body: some View {
        VStack(spacing: 0) {
            if let result = model.lastResult, !model.hasPendingChanges {
                resultBanner(result)
            }

            if model.hasPendingChanges {
                HStack(spacing: Theme.Space.large) {
                    Button {
                        isShowingDetail.toggle()
                    } label: {
                        HStack(spacing: Theme.Space.small) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 7, height: 7)
                            Text(changeCountLabel)
                            Image(systemName: "chevron.up")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isShowingDetail ? 180 : 0))
                                .animates(isShowingDetail)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(String(localized: "Affiche le détail des modifications"))

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

                    // Les raccourcis sont affichés à côté des boutons : ils existaient
                    // déjà, mais un raccourci qu'on ne voit pas n'est un raccourci pour
                    // personne.
                    Button { model.revert() } label: {
                        HStack(spacing: Theme.Space.snug) {
                            Text("Annuler")
                            ShortcutHint("⌘R")
                        }
                    }
                    .keyboardShortcut("r", modifiers: .command)

                    Button { Task { await model.apply() } } label: {
                        HStack(spacing: Theme.Space.snug) {
                            Text("Appliquer")
                            ShortcutHint("⌘↩", onAccent: model.canApply)
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canApply)
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, Theme.Space.medium)
            }

            if isShowingDetail, model.hasPendingChanges {
                detailList
            }
        }
        .background(.bar)
        .animates(model.hasPendingChanges, using: Theme.Motion.layout)
        .animates(isShowingDetail, using: Theme.Motion.layout)
    }

    private var changeCountLabel: String {
        let count = model.pendingChanges.count
        return count == 1
            ? String(localized: "1 modification en attente")
            : String(localized: "\(count) modifications en attente")
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
                title: String(localized: "Réglages appliqués et relus."),
                detail: nil
            )
        case .failedAndRestored(let failure):
            banner(
                systemImage: "arrow.uturn.backward.circle.fill",
                tint: .orange,
                title: String(localized: "Échec de l'écriture — l'état précédent a été restauré."),
                detail: failure
            )
        case .failedAndUncertain(let failure, let uncertain):
            // Le cas qu'il ne faut surtout pas édulcorer : on nomme précisément les
            // réglages dont on ne connaît plus l'état côté matériel.
            banner(
                systemImage: "exclamationmark.triangle.fill",
                tint: .red,
                title: String(localized: "État matériel incertain."),
                detail: failure + "\n" + String(localized: "Réglages non restaurés : ")
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
            Button("Relire") { Task { await model.reload() } }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
