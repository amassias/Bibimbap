import BibimbapFeatures
import BibimbapLocalization
import PulsarHID
import SwiftUI

/// Choix explicite de la cible lorsque plusieurs collections de configuration répondent.
///
/// Prendre la première de l'énumération suffirait tant qu'il n'y a qu'une souris Pulsar sur
/// la machine. Dès qu'il y en a deux — une filaire et un récepteur, deux exemplaires du même
/// modèle, un poste partagé — écrire dans la mauvaise flash n'est plus une hypothèse
/// théorique. L'utilisateur voit donc de quoi les distinguer : nom, transport, VID/PID et
/// emplacement physique.
struct DeviceSelectionView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.large) {
            header

            VStack(spacing: Theme.Space.small) {
                ForEach(model.availableCandidates, id: \.self) { candidate in
                    CandidateRow(candidate: candidate) {
                        Task { await model.connect(to: candidate) }
                    }
                }
            }

            HStack(spacing: Theme.Space.large) {
                Button(L10n.string("Actualiser")) {
                    Task { await model.retryConnection() }
                }
                Button(L10n.string("Annuler")) {
                    model.cancelDeviceSelection()
                }
                .buttonStyle(.link)
                Spacer()
            }
        }
        .padding(Theme.Space.section)
        .frame(maxWidth: Theme.Shell.detailMaximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text(L10n.string("Choisir un périphérique"))
                .font(.title3.weight(.semibold))
            Text(L10n.string("Plusieurs interfaces de configuration Pulsar répondent. Aucune n'est ouverte tant que vous n'avez pas choisi."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CandidateRow: View {
    let candidate: HIDDeviceIdentifier
    let connect: () -> Void

    var body: some View {
        PremiumPanel(padding: Theme.Space.large) {
            HStack(spacing: Theme.Space.large) {
                Image(systemName: candidate.transport == .usb ? "cable.connector" : "dot.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text(candidate.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Theme.Space.large)

                Button(L10n.string("Connecter"), action: connect)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(L10n.format("Connect to %@", candidate.displayName))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(candidate.displayName)
        .accessibilityValue(details)
    }

    private var details: String {
        [
            candidate.transportLabel,
            candidate.vendorProductLabel,
            L10n.format("Location %@", candidate.locationLabel),
        ].joined(separator: " · ")
    }
}

/// macOS a refusé l'accès aux rapports HID.
///
/// Le seul geste utile est dans les Réglages Système : ni un réessai ni une redemande
/// d'autorisation ne peuvent aboutir une fois le refus enregistré.
struct PermissionDeniedView: View {
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label(L10n.string("Accès HID refusé"), systemImage: "lock.shield")
        } description: {
            Text(L10n.string("Bibimbap doit être autorisé dans Réglages Système › Confidentialité et sécurité › Surveillance de l'entrée, puis relancé."))
        } actions: {
            Button(L10n.string("Ouvrir les réglages de Surveillance de l'entrée")) {
                BibimbapApplicationActions.openInputMonitoringSettings()
            }
            .buttonStyle(.borderedProminent)
            Button(L10n.string("Réessayer")) {
                Task { await model.retryConnection() }
            }
            .buttonStyle(.link)
        }
    }
}

/// Le périphérique est ouvert mais ne répond pas au dialogue d'identification.
struct HandshakeTimeoutView: View {
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label(L10n.string("Pas de réponse du périphérique"), systemImage: "clock.badge.exclamationmark")
        } description: {
            Text(L10n.string("L'interface s'est ouverte, mais aucune réponse n'est arrivée. Bougez ou cliquez la souris pour la réveiller, puis réessayez."))
        } actions: {
            Button(L10n.string("Réessayer")) {
                Task { await model.retryConnection() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Tentative de reprise après un débranchement ou un réveil de macOS.
struct ReconnectingView: View {
    let attempt: Int
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: Theme.Space.medium) {
            ProgressView()
                .controlSize(.large)
            Text(label)
                .foregroundStyle(.secondary)
            if model.hasPendingChanges {
                Text(L10n.string("Vos modifications non appliquées sont conservées."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        L10n.format("Reconnecting… (attempt %d of 5)", attempt)
    }
}
