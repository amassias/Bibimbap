import BibimbapFeatures
import SwiftUI

/// Fenêtre principale.
public struct RootView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        AppShell(model: model)
    }
}

/// Le contenu de la section courante, partagé par la fenêtre et le rendu hors écran.
struct SectionContent: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.section {
        case .overview: OverviewSection(model: model)
        case .customize: CustomizeSection(model: model)
        case .performance: PerformanceSection(model: model)
        case .macros: MacrosSection(model: model)
        case .power: PowerSection(model: model)
        case .settings: SettingsSection(model: model)
        }
    }
}

// MARK: - États de connexion

struct ConnectionProgressView: View {
    let state: AppModel.ConnectionState

    private var label: String {
        switch state {
        case .scanning: String(localized: "Recherche d'un périphérique…")
        case .connecting: String(localized: "Connexion…")
        case .reading: String(localized: "Lecture des réglages…")
        case .writing: String(localized: "Écriture en cours…")
        default: String(localized: "Préparation…")
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

struct NoDeviceView: View {
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Aucune souris détectée", systemImage: "magnifyingglass")
        } description: {
            Text("Branchez une souris Pulsar en USB, ou connectez son récepteur 2,4 GHz.")
        } actions: {
            Button("Rechercher à nouveau") {
                Task { await model.connect() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Le récepteur est branché mais la souris ne répond pas derrière lui.
///
/// Sans cette distinction, une souris endormie ressemblerait à une panne de
/// communication, alors qu'il suffit de la réveiller.
struct OfflineView: View {
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Souris hors ligne", systemImage: "wifi.slash")
        } description: {
            Text("Le récepteur répond, mais la souris ne se signale pas. Vérifiez qu'elle est allumée, chargée et à portée, puis réessayez.")
        } actions: {
            Button("Réessayer") {
                Task { await model.connect() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct UnrecognisedDeviceView: View {
    let cid: Int
    let mid: Int
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Périphérique non reconnu", systemImage: "questionmark.circle")
        } description: {
            // Deviner les capacités d'un modèle inconnu reviendrait à écrire des valeurs
            // au hasard dans sa flash. On s'arrête ici volontairement.
            Text("Ce modèle répond au protocole Pulsar (CID \(cid), MID \(mid)) mais ne figure pas dans le catalogue embarqué. Aucun réglage ne sera proposé, faute de connaître ses limites.")
        } actions: {
            Button("Réessayer") {
                Task { await model.connect() }
            }
        }
    }
}

struct FailureView: View {
    let message: String
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Communication interrompue", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Reconnecter") {
                Task { await model.connect() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
