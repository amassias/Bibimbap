import BibimbapLocalization
import AppKit
import BibimbapFeatures
import SwiftUI

/// L'étiquette de l'accessoire : uniquement l'icône carrée, jamais de texte à côté.
///
/// Un libellé textuel élargirait l'emprise à chaque changement de valeur et pousserait les
/// accessoires voisins. L'information passe donc par le dessin, et le détail par le menu.
public struct MenuBarLabel: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Image(nsImage: MenuBarIcon.image(
            batteryPercent: model.snapshot?.battery?.percentage,
            isCharging: model.snapshot?.battery?.isCharging ?? false,
            isConnected: model.snapshot != nil
        ))
        // En mode barre des menus seule, la fenêtre peut ne jamais s'ouvrir : la connexion
        // ne peut donc pas dépendre d'elle. Le garde-fou évite un double balayage quand la
        // fenêtre est là et a déjà lancé la sienne.
        .task {
            if model.connection == .idle { await model.connect() }
        }
    }
}

/// Le menu déroulant de la barre des menus.
///
/// Il ne rejoue pas la fenêtre : il tient les gestes qu'on fait sans s'asseoir — changer de
/// palier DPI, de fréquence, de profil, voir la batterie, rouvrir l'application. Tout ce qui
/// demande un réglage fin reste dans la fenêtre, à un clic d'ici.
public struct MenuBarMenu: View {
    @Bindable private var model: AppModel
    @Bindable private var preferences: MenuBarPreferences
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel, preferences: MenuBarPreferences = .shared) {
        self.model = model
        self.preferences = preferences
    }

    public var body: some View {
        header
        Divider()
        synchronizationStatus
        quickSettings
        Divider()
        deviceActions
        Divider()
        applicationActions
    }

    // MARK: En-tête

    @ViewBuilder
    private var header: some View {
        if let snapshot = model.snapshot {
            Text(snapshot.productName)
            Text(statusLine(for: snapshot))
            if let battery = snapshot.battery {
                Text(batteryLine(battery.percentage, isCharging: battery.isCharging))
            }
        } else {
            Text(disconnectedLabel)
        }
    }

    private func statusLine(for snapshot: DeviceSnapshot) -> String {
        "\(snapshot.connection.label) · \(snapshot.settings.reportRateHertz) Hz"
    }

    private func batteryLine(_ percentage: Int, isCharging: Bool) -> String {
        isCharging
            ? L10n.format("Battery %d%% — charging", percentage)
            : L10n.format("Battery %d%%", percentage)
    }

    private var disconnectedLabel: String {
        switch model.connection {
        case .scanning, .connecting, .reading: L10n.string( "Recherche d'un périphérique…")
        case .selectingDevice: L10n.string( "Plusieurs périphériques détectés")
        case .reconnecting(let attempt): L10n.format("Reconnecting… (attempt %d of 5)", attempt)
        case .permissionDenied: L10n.string( "Accès HID refusé")
        case .handshakeTimedOut: L10n.string( "Pas de réponse du périphérique")
        case .offline: L10n.string( "Souris endormie")
        case .unrecognised: L10n.string( "Modèle non reconnu")
        case .failed(let reason): reason
        default: L10n.string( "Aucune souris détectée")
        }
    }

    // MARK: Réglages rapides

    @ViewBuilder
    private var quickSettings: some View {
        if let snapshot = model.snapshot, let capabilities = model.capabilities {
            dpiMenu(snapshot: snapshot)
            reportRateMenu(snapshot: snapshot, capabilities: capabilities)

            if capabilities.supportsProfiles, let profile = snapshot.activeProfile {
                profileMenu(active: profile)
            }
        }
    }

    private func dpiMenu(snapshot: DeviceSnapshot) -> some View {
        let stages = Array(snapshot.settings.dpiStages.prefix(snapshot.settings.enabledStageCount))
        return Menu(L10n.string( "Palier DPI")) {
            ForEach(stages) { stage in
                Toggle(
                    stageLabel(stage),
                    isOn: binding(isOn: stage.index == snapshot.settings.activeStage) {
                        Task { await model.applyDirect { $0.activeStage = stage.index } }
                    }
                )
            }
        }
        .disabled(!model.canApplyDirectly || stages.isEmpty)
    }

    private func stageLabel(_ stage: DeviceSettings.DPIStage) -> String {
        let value = stage.isSymmetric
            ? "\(stage.x)"
            : "\(stage.x) × \(stage.y)"
        return L10n.format("Stage %d — %@ DPI", stage.index + 1, value)
    }

    private func reportRateMenu(snapshot: DeviceSnapshot, capabilities: DeviceCapabilities) -> some View {
        Menu(L10n.string( "Fréquence de rapport")) {
            ForEach(capabilities.availableReportRates, id: \.self) { rate in
                Toggle(
                    "\(rate) Hz",
                    isOn: binding(isOn: rate == snapshot.settings.reportRateHertz) {
                        Task { await model.applyDirect { $0.reportRateHertz = rate } }
                    }
                )
            }
        }
        .disabled(!model.canApplyDirectly)
    }

    private func profileMenu(active: Int) -> some View {
        Menu(L10n.string( "Profil")) {
            ForEach(model.supportedProfileIndices, id: \.self) { index in
                Toggle(
                    L10n.format("Profile %d", index + 1),
                    isOn: binding(isOn: index == active) {
                        Task { await model.selectProfile(index) }
                    }
                )
            }
        }
        .disabled(!model.canChangeProfile)
    }

    /// Une bascule de menu se comporte ici comme un choix dans une liste : cocher une
    /// entrée en sélectionne une autre, décocher la ligne déjà active ne veut rien dire.
    private func binding(isOn: Bool, select: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isOn }, set: { newValue in if newValue { select() } })
    }

    @ViewBuilder
    private var synchronizationStatus: some View {
        Text(synchronizationLabel)
        if model.draftRecovery != nil || model.requiresExplicitReread || model.hasPendingChanges {
            Button(L10n.string("Review in Bibimbap")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityHint(L10n.string("Open the window to review changes or recover device settings"))
        }
    }

    private var synchronizationLabel: String {
        if model.requiresExplicitReread { return L10n.string("Quick actions unavailable: device verification required") }
        if model.draftRecovery != nil { return L10n.string("Quick actions unavailable: resolve pending recovery") }
        if model.connection.isBusy { return L10n.string("Quick actions unavailable: operation in progress") }
        if model.connection != .connected || model.snapshot == nil {
            return L10n.string("Quick actions unavailable: device disconnected")
        }
        if model.hasPendingChanges { return L10n.string("Quick actions unavailable: unapplied changes") }
        return L10n.string("Settings synchronized")
    }

    // MARK: Périphérique

    @ViewBuilder
    private var deviceActions: some View {
        if model.hasPendingChanges {
            Button(L10n.string( "Appliquer les modifications")) {
                Task { await model.apply() }
            }
            .disabled(!model.canApply)
        }

        // La fenêtre et ce menu peuvent déclencher la même reconnexion en même temps :
        // `retryConnection` partage la tâche en vol plutôt que d'en ouvrir une seconde.
        if model.connection == .selectingDevice {
            Button(L10n.string( "Choisir un périphérique")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Button(model.snapshot == nil
            ? L10n.string( "Rechercher une souris")
            : model.requiresExplicitReread
                ? L10n.string("Récupérer l'état matériel")
                : model.hasPendingChanges
                    ? L10n.string("Relire et comparer")
                    : L10n.string( "Relire le périphérique")
        ) {
            Task {
                if model.snapshot == nil {
                    await model.retryConnection()
                } else if model.requiresExplicitReread {
                    await model.recoverUncertainHardware()
                } else {
                    await model.rereadAndCompare()
                }
            }
        }
        .disabled(model.connection.isBusy)
    }

    // MARK: Application

    @ViewBuilder
    private var applicationActions: some View {
        Button(L10n.string( "Ouvrir Bibimbap")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Toggle(L10n.string( "Masquer l'icône du Dock"), isOn: $preferences.isDockIconHidden)

        Divider()

        Button(L10n.string( "Quitter Bibimbap")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
