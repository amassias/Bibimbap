import AppKit
import BibimbapLocalization
import Foundation
import Observation
import PulsarCatalog
import PulsarHID
import PulsarProtocol
import PulsarSimulator

/// Aperçu local d'un import de profil. Tant que cet objet existe, aucune donnée n'a été
/// envoyée au périphérique et le brouillon visible n'a pas changé.
public struct ProfileImportPreview: Equatable, Sendable {
    public var archive: ProfileArchive
    public var targetProfile: Int?
    public var changes: [PendingChange]
    public var skipped: [String]
    public var settings: DeviceSettings

    public init(
        archive: ProfileArchive,
        targetProfile: Int?,
        changes: [PendingChange],
        skipped: [String],
        settings: DeviceSettings
    ) {
        self.archive = archive
        self.targetProfile = targetProfile
        self.changes = changes
        self.skipped = skipped
        self.settings = settings
    }
}

/// Aperçu local d'une copie inter-profils. Le plan n'est appliqué qu'après l'action
/// explicite de confirmation ; la comparaison peut donc être consultée sans écriture.
public struct ProfileCopyPreview: Equatable, Sendable {
    public var sourceProfile: Int
    public var targetProfile: Int
    public var source: ProfileArchive
    public var target: ProfileArchive
    public var changes: [PendingChange]

    public init(
        sourceProfile: Int,
        targetProfile: Int,
        source: ProfileArchive,
        target: ProfileArchive,
        changes: [PendingChange]
    ) {
        self.sourceProfile = sourceProfile
        self.targetProfile = targetProfile
        self.source = source
        self.target = target
        self.changes = changes
    }
}

/// État de l'application, observé par les vues.
@MainActor
@Observable
public final class AppModel {
    public static let profileCount = DeviceController.profileCount

    public enum ConnectionState: Equatable, Sendable {
        case idle
        case scanning
        /// Plusieurs candidats répondent au critère : l'utilisateur tranche.
        case selectingDevice
        case connecting
        case reading
        case connected
        case writing(progress: Double)
        /// Tentative de reprise automatique après un débranchement ou un réveil.
        case reconnecting(attempt: Int)
        case noDevice
        case offline
        /// macOS refuse l'accès HID : aucun réessai automatique ne peut aboutir.
        case permissionDenied
        /// Le périphérique a été ouvert mais n'a pas répondu au dialogue d'identification.
        case handshakeTimedOut
        case unrecognised(cid: Int, mid: Int)
        case failed(String)
        case disconnectedDuringWrite(uncertain: [String])

        /// La sélection n'est pas une occupation : l'interface attend l'utilisateur,
        /// elle ne travaille pas. Elle ne doit donc ni afficher de progression ni
        /// bloquer les actions qui n'écrivent rien.
        public var isBusy: Bool {
            switch self {
            case .scanning, .connecting, .reading, .reconnecting, .writing: true
            default: false
            }
        }
    }

    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case overview, customize, performance, macros, power, settings

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .overview: L10n.string( "Vue d'ensemble")
            case .customize: L10n.string( "Personnaliser")
            case .performance: L10n.string( "Performance")
            case .macros: L10n.string( "Macros")
            case .power: L10n.string( "Alimentation et dongle")
            case .settings: L10n.string( "Réglages")
            }
        }

        public var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .customize: "cursorarrow.click.2"
            case .performance: "chart.bar"
            case .macros: "list.bullet.rectangle"
            case .power: "bolt"
            case .settings: "gearshape"
            }
        }
    }

    // MARK: État observable

    public private(set) var connection: ConnectionState = .idle
    public private(set) var snapshot: DeviceSnapshot?
    public private(set) var capabilities: DeviceCapabilities?
    public private(set) var lastResult: WriteResult?
    /// Progression de l'opération courante, dont le compteur n'avance qu'après relecture.
    public private(set) var writeProgress: WriteProgress?
    public private(set) var validationIssues: [DraftValidator.Issue] = []
    public private(set) var isSimulated: Bool

    /// Candidats détectés lors du dernier balayage. Vide tant qu'aucun n'a été énuméré.
    public private(set) var availableCandidates: [HIDDeviceIdentifier] = []
    /// Cible retenue, sous une forme qui survit à un rebranchement sur un autre port.
    public private(set) var selectedStableKey: String?
    /// Comparaison en attente entre le brouillon local et l'état relu.
    public private(set) var draftRecovery: DraftRecovery?
    /// Vrai tant qu'une écriture interrompue n'a pas été suivie d'une relecture explicite.
    public private(set) var requiresExplicitReread = false
    /// Prévisualisations locales, jamais appliquées implicitement.
    public private(set) var profileImportPreview: ProfileImportPreview?
    public private(set) var profileCopyPreview: ProfileCopyPreview?
    public private(set) var profileComparison: ProfileComparison?
    /// Emplacement HID de la cible choisie, distinct de la clé stable qui ignore le port.
    public private(set) var hardwareLocation: String?
    public private(set) var hardwareTransport: String?

    /// La section d'entrée est une décision de lancement, pas une préférence persistée.
    /// La navigation reste ensuite entièrement pilotée par l'utilisateur.
    public var section: Section = .overview
    /// Brouillon local. Rien n'atteint le matériel avant `apply()`.
    public var draft = DeviceSettings() {
        didSet { revalidate() }
    }

    /// Réglages qui ont servi de point de départ au brouillon.
    ///
    /// Distinct de `snapshot.settings` : après une reconnexion, l'instantané est le nouvel
    /// état du matériel alors que le brouillon, lui, se compare toujours à ce qu'il a
    /// quitté. Sans cette base, un conflit ressemblerait à une modification de l'utilisateur.
    private var draftBase: DeviceSettings?
    /// Dernière lecture connue de chaque profil, utilisée uniquement pour l'affichage ;
    /// toute opération d'application relit le matériel avant d'écrire.
    private var knownProfileArchives: [Int: ProfileArchive] = [:]

    private let controller: DeviceController
    private let catalog: DeviceCatalog
    private var notificationTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    /// Unique tâche de connexion ou de reconnexion en vol.
    private var connectionTask: Task<Void, Never>?
    /// Dernier évènement HID traité, pour absorber les doublons d'attachement.
    private var lastDeviceEvent: (event: HIDDeviceEvent, at: ContinuousClock.Instant)?
    /// Un débranchement demandé par l'utilisateur ne doit rien relancer.
    private var isUserInitiatedDisconnect = false
    /// Vrai tant qu'une session HID est réellement ouverte. `snapshot` ne suffit pas :
    /// il survit volontairement à un débranchement, pour ne pas vider l'écran.
    private var hasLiveSession = false

    public init(controller: DeviceController, catalog: DeviceCatalog = .embedded, isSimulated: Bool) {
        self.controller = controller
        self.catalog = catalog
        self.isSimulated = isSimulated
    }

    /// Modèle branché sur le matériel réel.
    public static func live(catalog: DeviceCatalog = .embedded) -> AppModel {
        let transport = IOKitHIDTransport(vendorIDs: Set(catalog.vendorIDs))
        return AppModel(
            controller: DeviceController(transport: transport, catalog: catalog),
            catalog: catalog,
            isSimulated: false
        )
    }

    /// Modèle branché sur le transport simulé, pour travailler sans souris.
    public static func simulated(
        cid: Int = 87,
        mid: Int = 10,
        connectionType: PulsarConnectionType = .wireless4k,
        catalog: DeviceCatalog = .embedded
    ) -> AppModel {
        let transport = SimulatedHIDTransport(
            catalog: catalog, cid: cid, mid: mid, connectionType: connectionType
        )
        return AppModel(
            controller: DeviceController(transport: transport, catalog: catalog),
            catalog: catalog,
            isSimulated: true
        )
    }

    /// Modèle branché sur un transport simulé déjà configuré, pour piloter les pannes.
    public static func simulated(
        transport: SimulatedHIDTransport,
        catalog: DeviceCatalog = .embedded
    ) -> AppModel {
        AppModel(
            controller: DeviceController(transport: transport, catalog: catalog),
            catalog: catalog,
            isSimulated: true
        )
    }

    // MARK: Dérivés

    public var pendingChanges: [PendingChange] {
        guard let snapshot else { return [] }
        return WritePlanner(
            family: snapshot.family,
            catalog: catalog,
            capabilities: capabilities
        )
            .changes(from: draftBase ?? snapshot.settings, to: draft)
    }

    public var hasPendingChanges: Bool { !pendingChanges.isEmpty }

    /// Présentation officielle correspondant au CID/MID réellement lu.
    public var deviceModel: DeviceModel? {
        guard let snapshot else { return nil }
        return catalog.model(cid: snapshot.identity.cid, mid: snapshot.identity.mid)
    }

    public var deviceDisplayName: String {
        if let name = deviceModel?.name { return name }
        guard let productName = snapshot?.productName, !productName.isEmpty else {
            return L10n.string( "Souris Pulsar")
        }
        return productName
    }

    public var deviceImageName: String? { deviceModel?.imageName }

    public var buttonProfiles: [ButtonProfile] {
        snapshot?.family.orderedButtons ?? []
    }

    /// Les commandes du modèle connecté, dans l'ordre officiel et numérotées de 1 à N.
    ///
    /// Source unique des lignes d'affectation et des repères de la carte : les deux ne
    /// peuvent pas diverger. Vide tant qu'aucun modèle reconnu n'est branché.
    public var buttonPresentations: [ButtonPresentation] {
        guard let family = snapshot?.family else { return [] }
        return ButtonPresentation.list(family: family, settings: draft)
    }

    /// Position dans `draft.buttons` de l'affectation portant cet index firmware.
    public func draftButtonPosition(firmwareIndex: Int) -> Int? {
        draft.buttons.firstIndex { $0.index == firmwareIndex }
    }

    /// Emplacement matériel réellement relu, jamais déduit du nom de fichier.
    public var activeProfileIndex: Int? { snapshot?.activeProfile }

    public var activeProfileLabel: String {
        guard let activeProfileIndex else { return L10n.string("Profil non indiqué") }
        return L10n.format("Profil %d", activeProfileIndex + 1)
    }

    public var activeHardwareLocationLabel: String {
        var parts = [deviceDisplayName]
        if let hardwareTransport, !hardwareTransport.isEmpty {
            parts.append(hardwareTransport)
        }
        if let hardwareLocation, !hardwareLocation.isEmpty {
            parts.append(L10n.format("emplacement %@", hardwareLocation))
        }
        return parts.joined(separator: " · ")
    }

    public var supportedProfileIndices: [Int] {
        capabilities?.supportsProfiles == true
            ? Array(0..<Self.profileCount)
            : []
    }

    public var knownProfileSlots: [Int] {
        knownProfileArchives.keys.sorted()
    }

    public func knownProfileArchive(at index: Int) -> ProfileArchive? {
        knownProfileArchives[index]
    }

    public var canChangeProfile: Bool {
        snapshot?.activeProfile != nil
            && connection == .connected
            && !connection.isBusy
            && !hasPendingChanges
            && draftRecovery == nil
            && !requiresExplicitReread
    }

    /// Rien ne part vers le matériel tant qu'un conflit n'est pas tranché, et tant qu'une
    /// écriture interrompue n'a pas été suivie d'une relecture demandée explicitement.
    public var canApply: Bool {
        hasPendingChanges
            && !validationIssues.contains(where: \.isBlocking)
            && !connection.isBusy
            && draftRecovery == nil
            && !requiresExplicitReread
    }

    /// Les sections effectivement affichables pour le modèle connecté.
    public var availableSections: [Section] {
        guard let capabilities else { return [.overview, .settings] }
        var sections: [Section] = [.overview, .customize, .performance, .macros]
        if capabilities.supportsBattery || capabilities.supportsLongDistance
            || capabilities.supportsFanMode || capabilities.receiver != .none {
            sections.append(.power)
        }
        sections.append(.settings)
        return sections
    }

    // MARK: Actions

    /// Balaye, puis connecte ou demande à choisir.
    ///
    /// Un seul candidat se connecte tout seul, parce qu'il n'y a rien à décider. Plusieurs
    /// candidats ne se départagent pas au hasard : prendre le premier de l'énumération
    /// reviendrait à ouvrir la souris du voisin de bureau ou le mauvais récepteur.
    public func connect() async {
        await runConnection { await self.scanAndConnect() }
    }

    /// Connecte un candidat explicitement choisi.
    public func connect(to candidate: HIDDeviceIdentifier) async {
        await runConnection { await self.connectDirectly(to: candidate) }
    }

    /// Revient à la liste après l'échec d'un candidat.
    ///
    /// Enchaîner tout seul sur le candidat suivant reviendrait à ouvrir un autre
    /// périphérique physique que celui qu'on visait.
    public func showDeviceSelection() {
        guard availableCandidates.count > 1 else { return }
        connection = .selectingDevice
    }

    /// Abandonne la sélection sans rien ouvrir.
    public func cancelDeviceSelection() {
        guard connection == .selectingDevice else { return }
        availableCandidates = []
        connection = .idle
    }

    /// Relance explicitement une tentative, en annulant proprement celle en cours.
    public func retryConnection() async {
        connectionTask?.cancel()
        connectionTask = nil
        isUserInitiatedDisconnect = false
        await connect()
    }

    /// Sérialise connexions et reconnexions.
    ///
    /// La fenêtre et l'accessoire de barre des menus lancent la même action sans se
    /// concerter. Deux balayages concurrents ouvriraient deux fois la même collection et
    /// produiraient deux instantanés dont on ne saurait plus lequel fait foi : les appels
    /// simultanés partagent donc la tâche déjà en vol.
    private func runConnection(_ body: @escaping @MainActor () async -> Void) async {
        if let existing = connectionTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in await body() }
        connectionTask = task
        await task.value
        if connectionTask == task { connectionTask = nil }
    }

    private func scanAndConnect() async {
        connection = .scanning
        do {
            let candidates = try await controller.availableDevices()
            availableCandidates = candidates

            switch candidates.count {
            case 0:
                connection = .noDevice
            case 1:
                await connectDirectly(to: candidates[0])
            default:
                // Si une cible a déjà été retenue et qu'elle est seule à porter sa clé,
                // la reprendre n'est pas un choix arbitraire : c'est le même périphérique.
                let matching = candidates.filter { $0.stableKey == selectedStableKey }
                if matching.count == 1 {
                    await connectDirectly(to: matching[0])
                } else {
                    connection = .selectingDevice
                }
            }
        } catch {
            report(error)
        }
    }

    private func connectDirectly(to candidate: HIDDeviceIdentifier) async {
        connection = .connecting
        do {
            let snapshot = try await controller.connect(to: candidate)
            connection = .reading
            selectedStableKey = candidate.stableKey
            hardwareLocation = candidate.locationLabel
            hardwareTransport = candidate.transportLabel
            adopt(snapshot)
            hasLiveSession = true
            connection = .connected
            await observeDevice()
        } catch {
            // La liste reste affichable : un candidat qui refuse la connexion ne doit pas
            // faire disparaître les autres, et surtout pas en faire ouvrir un autre tout seul.
            report(error)
        }
    }

    /// Traduit une cause de connexion en état affichable.
    private func report(_ error: any Error) {
        switch error {
        case DeviceController.ControllerError.unrecognisedDevice(let cid, let mid):
            connection = .unrecognised(cid: cid, mid: mid)
        case DeviceController.ControllerError.deviceOffline:
            connection = .offline
        case DeviceController.ControllerError.noConfigurationInterface,
             DeviceController.ControllerError.interfaceDisappeared:
            connection = .noDevice
        case DeviceController.ControllerError.permissionDenied:
            connection = .permissionDenied
        case DeviceController.ControllerError.handshakeTimedOut:
            connection = .handshakeTimedOut
        default:
            connection = .failed(message(for: error))
        }
    }

    public func disconnect() async {
        isUserInitiatedDisconnect = true
        hasLiveSession = false
        connectionTask?.cancel()
        connectionTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        eventTask?.cancel()
        eventTask = nil
        wakeTask?.cancel()
        wakeTask = nil
        await controller.disconnect()
        snapshot = nil
        capabilities = nil
        draftBase = nil
        draftRecovery = nil
        requiresExplicitReread = false
        profileImportPreview = nil
        profileCopyPreview = nil
        profileComparison = nil
        writeProgress = nil
        hardwareLocation = nil
        hardwareTransport = nil
        knownProfileArchives = [:]
        availableCandidates = []
        draft = DeviceSettings()
        connection = .idle
    }

    /// Abandonne le brouillon et revient à l'état lu.
    public func revert() {
        guard let snapshot else { return }
        draft = snapshot.settings
        draftBase = snapshot.settings
        draftRecovery = nil
        lastResult = nil
    }

    /// Valide, écrit, relit.
    public func apply() async {
        guard let snapshot, canApply else { return }
        let plan = WritePlanner(
            family: snapshot.family,
            catalog: catalog,
            capabilities: capabilities
        )
            .plan(from: snapshot.settings, to: draft)
        guard !plan.isEmpty else { return }

        writeProgress = WriteProgress(
            completed: 0,
            total: plan.count,
            currentOperation: plan.operations.first?.label
        )
        connection = .writing(progress: 0)
        do {
            let result = try await controller.apply(plan) { [weak self] progress in
                await self?.receiveWriteProgress(progress)
            }
            lastResult = result
            let refreshed = try await controller.readSnapshot()
            if case .failedAndUncertain(_, let uncertain) = result.outcome {
                // Une lecture de contrôle ne tranche pas l'incertitude créée par le lot :
                // elle rafraîchit l'instantané, mais le brouillon reste nécessaire pour
                // comparer explicitement ce que le matériel porte désormais.
                adoptKeepingDraft(refreshed)
                connection = .disconnectedDuringWrite(uncertain: uncertain)
                requiresExplicitReread = true
            } else {
                adopt(refreshed)
                connection = .connected
            }
        } catch {
            // L'échec de la relecture est le pire cas : on ne sait plus ce que porte
            // le matériel, et on le dit plutôt que d'afficher un état inventé.
            lastResult = WriteResult(
                outcome: .failedAndUncertain(
                    failure: message(for: error),
                    uncertain: plan.operations.map(\.label)
                ),
                applied: []
            )
            connection = .disconnectedDuringWrite(uncertain: plan.operations.map(\.label))
            requiresExplicitReread = true
        }
    }

    private func receiveWriteProgress(_ progress: WriteProgress) {
        writeProgress = progress
        connection = .writing(progress: progress.fraction)
    }

    /// Applique une modification ponctuelle, décidée hors de la fenêtre.
    ///
    /// Le menu de la barre des menus écrit sans passer par le brouillon visible. Deux
    /// sources d'écriture simultanées pour la même zone produiraient un état qu'on ne
    /// saurait plus nommer : tant que le brouillon porte des modifications non appliquées,
    /// la voie rapide est refusée, et le menu le dit plutôt que d'écrire les deux à la fois.
    public func applyDirect(_ mutate: (inout DeviceSettings) -> Void) async {
        guard let snapshot, !connection.isBusy, !hasPendingChanges else { return }
        var target = snapshot.settings
        mutate(&target)
        guard target != snapshot.settings else { return }
        draft = target
        await apply()
    }

    /// Relecture simple quand aucun brouillon n'attend. Avec un brouillon, l'action
    /// devient automatiquement « relire et comparer » pour ne jamais l'écraser.
    public func reload() async {
        if requiresExplicitReread {
            await recoverUncertainHardware()
            return
        }
        if hasPendingChanges {
            await rereadAndCompare()
            return
        }
        guard snapshot != nil else { return }
        connection = .reading
        do {
            adopt(try await controller.readSnapshot())
            requiresExplicitReread = false
            connection = .connected
        } catch {
            if requiresExplicitReread {
                await reconnectAndRecoverUncertainHardware()
            } else {
                report(error)
            }
        }
    }

    /// Relit le périphérique puis compare la lecture à la base du brouillon. Cette action
    /// est toujours sans écriture ; elle est aussi le seul chemin de récupération d'un
    /// état matériel incertain.
    public func rereadAndCompare() async {
        guard snapshot != nil, !connection.isBusy else { return }
        connection = .reading
        do {
            let refreshed = try await controller.readSnapshot()
            requiresExplicitReread = false
            if hasPendingChanges {
                await reconcile(with: refreshed, cause: .explicitComparison)
            } else {
                adopt(refreshed)
                connection = .connected
            }
        } catch {
            if requiresExplicitReread {
                await reconnectAndRecoverUncertainHardware()
            } else {
                report(error)
            }
        }
    }

    /// Récupération dédiée après une écriture interrompue. Aucun plan n'est recalculé et
    /// aucune valeur du brouillon n'est envoyée automatiquement.
    public func recoverUncertainHardware() async {
        guard requiresExplicitReread else { return }
        if hasLiveSession {
            await rereadAndCompare()
        } else {
            await reconnectAndRecoverUncertainHardware()
        }
    }

    private func reconnectAndRecoverUncertainHardware() async {
        guard !connection.isBusy || connection == .reading else { return }
        await controller.closeForRecovery()
        hasLiveSession = false
        connection = .reconnecting(attempt: 1)
        do {
            let candidates = try await controller.availableDevices()
            availableCandidates = candidates
            let matching = selectedStableKey.map { key in
                candidates.filter { $0.stableKey == key }
            } ?? candidates
            guard matching.count == 1, let target = matching.first else {
                connection = matching.count > 1 ? .selectingDevice : .offline
                return
            }
            let refreshed = try await controller.connect(to: target)
            selectedStableKey = target.stableKey
            hardwareLocation = target.locationLabel
            hardwareTransport = target.transportLabel
            hasLiveSession = true
            requiresExplicitReread = false
            await observeDevice()
            if hasPendingChanges {
                await reconcile(with: refreshed, cause: .explicitComparison)
            } else {
                adopt(refreshed)
                connection = .connected
            }
        } catch {
            // L'incertitude reste volontairement visible : aucun essai de réécriture ne
            // peut être lancé tant qu'une lecture complète n'a pas réussi.
            requiresExplicitReread = true
            report(error)
        }
    }

    public func factoryReset() async {
        connection = .writing(progress: 0)
        do {
            adopt(try await controller.factoryReset())
            lastResult = WriteResult(outcome: .succeeded, applied: [L10n.string( "Réinitialisation")])
            connection = .connected
        } catch {
            connection = .failed(message(for: error))
        }
    }

    public func selectProfile(_ profile: Int) async {
        guard (0..<Self.profileCount).contains(profile), canChangeProfile else { return }
        guard profile != snapshot?.activeProfile else { return }
        let original = snapshot?.activeProfile
        connection = .reading
        do {
            let selected = try await controller.readProfile(profile)
            adopt(selected)
            profileComparison = nil
            profileCopyPreview = nil
            connection = .connected
        } catch {
            if let original {
                await failProfileOperation(error, restoring: original)
            } else {
                report(error)
            }
        }
    }

    public func setDongleLightEnabled(_ enabled: Bool) async {
        guard !connection.isBusy, var receiver = draft.receiver,
              var lighting = receiver.rgbLighting else { return }
        lighting = lighting.setting(enabled: enabled)
        receiver.rgbLighting = lighting
        draft.receiver = receiver
        await apply()
    }

    // MARK: Appairage

    public enum PairingPhase: Equatable, Sendable {
        case idle
        case searching(secondsRemaining: Int)
        case succeeded
        case failed(String)
    }

    public private(set) var pairing: PairingPhase = .idle
    private var pairingTask: Task<Void, Never>?

    /// Met le récepteur en appairage et suit son état jusqu'à l'issue.
    ///
    /// Le périphérique ne pousse pas de notification : il faut l'interroger. Le compte à
    /// rebours vient du récepteur lui-même, pas d'une minuterie locale, pour que
    /// l'affichage reflète ce que le matériel fait réellement.
    public func startPairing() async {
        pairingTask?.cancel()
        pairing = .searching(secondsRemaining: 20)
        do {
            try await controller.startPairing()
        } catch {
            pairing = .failed(message(for: error))
            return
        }

        pairingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let state = try await self.controller.pairingState()
                    switch state.state {
                    case .pairing:
                        await self.setPairing(.searching(secondsRemaining: state.secondsRemaining))
                    case .succeeded:
                        await self.setPairing(.succeeded)
                        await self.reload()
                        return
                    case .failed:
                        await self.setPairing(.failed(L10n.string( "Aucune souris ne s'est présentée.")))
                        return
                    }
                } catch {
                    await self.setPairing(.failed(self.message(for: error)))
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairing = .idle
    }

    private func setPairing(_ phase: PairingPhase) {
        pairing = phase
    }

    // MARK: Sauvegardes

    /// Exporte le profil actif relu, dans un format versionné et relisible. L'archive
    /// porte explicitement son emplacement matériel pour qu'un fichier ne soit jamais
    /// confondu avec un autre profil.
    public func exportProfile() -> ProfileArchive? {
        guard let snapshot, connection == .connected, !requiresExplicitReread else { return nil }
        return profileArchive(for: snapshot)
    }

    /// Prépare un import sans rien écrire ni modifier le brouillon courant.
    public func previewProfileImport(_ archive: ProfileArchive) -> ProfileImportPreview? {
        guard let snapshot, let capabilities else { return nil }

        let targetProfile = snapshot.activeProfile
        let mismatch = archive.cid != snapshot.identity.cid || archive.mid != snapshot.identity.mid
        let settings: DeviceSettings
        var skipped: [String]
        if mismatch {
            // Un autre modèle peut partager des champs de même nom avec des limites
            // différentes. On affiche l'écart mais on ne fabrique aucun plan d'écriture.
            settings = snapshot.settings
            skipped = [L10n.format(
                "Archive from CID %d / MID %d does not match this device (CID %d / MID %d).",
                archive.cid, archive.mid, snapshot.identity.cid, snapshot.identity.mid
            )]
        } else {
            let fitted = archive.settings(
                fittingFamily: snapshot.family,
                capabilities: capabilities,
                catalog: catalog,
                current: snapshot.settings
            )
            settings = fitted.settings
            skipped = fitted.skipped
        }

        let changes = WritePlanner(family: snapshot.family, catalog: catalog)
            .changes(from: snapshot.settings, to: settings)
        let preview = ProfileImportPreview(
            archive: archive,
            targetProfile: targetProfile,
            changes: changes,
            skipped: skipped,
            settings: settings
        )
        profileImportPreview = preview
        return preview
    }

    /// Confirme le prévisualiseur d'import en remplissant le brouillon. Même ici, aucune
    /// écriture n'est lancée : l'utilisateur doit encore passer par Apply et sa relecture.
    public func confirmProfileImportPreview() {
        guard let preview = profileImportPreview, draftRecovery == nil else { return }
        draft = preview.settings
        profileImportPreview = nil
    }

    public func dismissProfileImportPreview() {
        profileImportPreview = nil
    }

    /// Compatibilité avec l'API précédente : l'appelant explicite confirme immédiatement
    /// l'aperçu, mais le matériel reste inchangé jusqu'à `apply()`.
    @discardableResult
    public func importProfile(_ archive: ProfileArchive) -> [String] {
        guard let preview = previewProfileImport(archive) else { return [] }
        confirmProfileImportPreview()
        return preview.skipped
    }

    // MARK: Profils matériels

    /// Relit deux emplacements et restaure le profil actif d'origine. Les commandes de
    /// sélection sont confirmées par relecture ; les réglages ne sont jamais écrits.
    public func compareProfiles(_ left: Int, _ right: Int) async -> ProfileComparison? {
        guard canReadProfiles, left != right,
              (0..<Self.profileCount).contains(left),
              (0..<Self.profileCount).contains(right),
              let original = snapshot?.activeProfile else { return nil }

        profileComparison = nil
        connection = .reading
        do {
            let current = try await controller.readSnapshot()
            let leftSnapshot = left == original
                ? current
                : try await controller.readProfile(left)
            let rightSnapshot = right == left
                ? leftSnapshot
                : try await controller.readProfile(right)
            let restored = right == original
                ? rightSnapshot
                : try await controller.readProfile(original)

            let comparison = profileArchive(for: leftSnapshot)
                .comparison(with: profileArchive(for: rightSnapshot))
            adopt(restored)
            profileComparison = comparison
            connection = .connected
            return comparison
        } catch {
            await failProfileOperation(error, restoring: original)
            return nil
        }
    }

    /// Prévisualise la copie du profil actif vers `target` en relisant la cible puis en
    /// restaurant l'actif d'origine. Tant que l'aperçu est affiché, aucune écriture de
    /// réglage n'est exécutée.
    public func previewProfileCopy(to target: Int) async -> ProfileCopyPreview? {
        guard canReadProfiles,
              (0..<Self.profileCount).contains(target),
              let original = snapshot?.activeProfile,
              target != original else { return nil }

        profileCopyPreview = nil
        connection = .reading
        do {
            let sourceSnapshot = try await controller.readSnapshot()
            let targetSnapshot = try await controller.readProfile(target)
            let restored = try await controller.readProfile(original)
            let source = profileArchive(for: sourceSnapshot)
            let targetArchive = profileArchive(for: targetSnapshot)
            let changes = WritePlanner(family: sourceSnapshot.family, catalog: catalog)
                .changes(from: targetSnapshot.settings, to: sourceSnapshot.settings)
            let preview = ProfileCopyPreview(
                sourceProfile: original,
                targetProfile: target,
                source: source,
                target: targetArchive,
                changes: changes
            )
            adopt(restored)
            profileCopyPreview = preview
            connection = .connected
            return preview
        } catch {
            await failProfileOperation(error, restoring: original)
            return nil
        }
    }

    /// Applique la copie après une action explicite. Le profil source et la cible sont
    /// relus juste avant le plan afin qu'un aperçu ancien ne puisse écrire sur une base
    /// devenue obsolète.
    public func applyProfileCopyPreview() async {
        guard let preview = profileCopyPreview else { return }
        await copyProfile(to: preview.targetProfile)
    }

    public func discardProfileCopyPreview() {
        profileCopyPreview = nil
    }

    public func copyProfile(to target: Int) async {
        guard canReadProfiles,
              (0..<Self.profileCount).contains(target),
              let original = snapshot?.activeProfile,
              target != original else { return }

        profileCopyPreview = nil
        connection = .reading
        do {
            let sourceSnapshot = try await controller.readSnapshot()
            let targetSnapshot = try await controller.readProfile(target)
            let plan = WritePlanner(family: sourceSnapshot.family, catalog: catalog)
                .plan(from: targetSnapshot.settings, to: sourceSnapshot.settings)

            if plan.isEmpty {
                let restored = try await controller.readProfile(original)
                adopt(restored)
                lastResult = WriteResult(outcome: .succeeded, applied: [])
                connection = .connected
                return
            }

            writeProgress = WriteProgress(
                completed: 0,
                total: plan.count,
                currentOperation: plan.operations.first?.label
            )
            connection = .writing(progress: 0)
            let result = try await controller.apply(plan) { [weak self] progress in
                await self?.receiveWriteProgress(progress)
            }
            lastResult = result

            if result.isUncertain {
                requiresExplicitReread = true
                connection = .disconnectedDuringWrite(
                    uncertain: resultUncertainLabels(result, fallback: plan.operations.map(\.label))
                )
                return
            }

            // La relecture de la cible confirme le résultat avant de revenir à la source.
            _ = try await controller.readSnapshot()
            let restored = try await controller.readProfile(original)
            adopt(restored)
            connection = .connected
        } catch {
            await failProfileOperation(error, restoring: original)
        }
    }

    private var canReadProfiles: Bool {
        snapshot?.activeProfile != nil
            && capabilities?.supportsProfiles == true
            && connection == .connected
            && !connection.isBusy
            && !hasPendingChanges
            && draftRecovery == nil
            && !requiresExplicitReread
    }

    private func profileArchive(for snapshot: DeviceSnapshot) -> ProfileArchive {
        ProfileArchive(
            snapshot: snapshot,
            profileSlot: snapshot.activeProfile,
            hardwareLocation: hardwareLocation,
            hardwareTransport: hardwareTransport
        )
    }

    private func resultUncertainLabels(_ result: WriteResult, fallback: [String]) -> [String] {
        if case .failedAndUncertain(_, let uncertain) = result.outcome, !uncertain.isEmpty {
            return uncertain
        }
        return fallback
    }

    private func failProfileOperation(_ error: any Error, restoring original: Int) async {
        do {
            let restored = try await controller.readProfile(original)
            adopt(restored)
            report(error)
        } catch {
            // On ne sait plus quel emplacement est actif ni si une sélection a abouti.
            // La récupération dédiée exigera une relecture explicite avant toute action.
            requiresExplicitReread = true
            lastResult = WriteResult(
                outcome: .failedAndUncertain(
                    failure: message(for: error),
                    uncertain: [L10n.string("Profil actif")]
                ),
                applied: []
            )
            connection = .disconnectedDuringWrite(uncertain: [L10n.string("Profil actif")])
        }
    }

    /// Charge une sauvegarde dans le brouillon, sans rien écrire.
    ///
    /// Les réglages qu'un modèle ne sait pas représenter sont écartés plutôt qu'appliqués
    /// de force : restaurer une sauvegarde de X2 sur un autre capteur ne doit pas produire
    /// des paliers DPI impossibles.
    public func diagnosticReport() async -> String {
        var lines: [String] = [
            "Bibimbap — rapport de diagnostic",
            "Date : \(ISO8601DateFormatter().string(from: Date()))",
            "Catalogue : v\(catalog.sourceVersion) (\(catalog.families.count) familles)",
            "Transport : \(isSimulated ? "simulé" : "IOKit")",
        ]
        if let snapshot {
            lines += [
                "",
                "Périphérique : \(snapshot.productName)",
                "CID/MID : \(snapshot.identity.cid)/\(snapshot.identity.mid)",
                "Connexion : \(snapshot.connection.label) (max \(snapshot.connection.maximumReportRate) Hz)",
                "Firmware : \(snapshot.firmwareVersion)",
                "Capteur : \(snapshot.family.sensor.type)",
                "Profil actif : \(activeProfileLabel)",
                "Emplacement matériel : \(activeHardwareLocationLabel)",
            ]
        }
        if let writeProgress {
            lines += [
                "",
                "Progression d'écriture : \(writeProgress.completed)/\(writeProgress.total)",
                "Opération : \(writeProgress.currentOperation ?? "terminée")",
            ]
        }
        if !pendingChanges.isEmpty {
            lines += ["", "Modifications en attente :"]
            lines += pendingChanges.map {
                "  \($0.label) : \($0.before) → \($0.after)"
            }
        }
        if let profileImportPreview {
            lines += ["", "Aperçu d'import (sans écriture) :"]
            lines += profileImportPreview.changes.map {
                "  \($0.label) : \($0.before) → \($0.after)"
            }
            if !profileImportPreview.skipped.isEmpty {
                lines += profileImportPreview.skipped.map { "  Ignoré : \($0)" }
            }
        }
        if let profileCopyPreview {
            lines += [
                "",
                "Aperçu de copie (sans écriture) : \(profileCopyPreview.sourceProfile + 1) → \(profileCopyPreview.targetProfile + 1)",
            ]
            lines += profileCopyPreview.changes.map {
                "  \($0.label) : \($0.before) → \($0.after)"
            }
        }
        if requiresExplicitReread {
            lines += ["", "Récupération requise : relecture explicite avant toute nouvelle écriture."]
        }
        // Le journal de connexion vient avant les trames : lorsque l'échec précède la
        // création de la session, c'est la seule partie du rapport qui contient quoi que
        // ce soit d'exploitable.
        let connectionLog = await controller.connectionLog()
        lines += ["", "Journal de connexion (\(connectionLog.count)) :"]
        lines += connectionLog.suffix(64).map { "  " + $0.line }
        if let selectedStableKey {
            lines += ["Cible retenue : \(selectedStableKey)"]
        }
        if !availableCandidates.isEmpty {
            lines += ["Candidats (\(availableCandidates.count)) :"]
            lines += availableCandidates.map {
                "  \($0.displayName) — \($0.transportLabel), \($0.vendorProductLabel), \($0.locationLabel)"
            }
        }

        let log = await controller.diagnosticLog()
        lines += ["", "Dernières trames (\(log.count)) :"]
        lines += log.suffix(64).map { entry in
            let direction = entry.outgoing ? "→" : "←"
            let bytes = entry.frame.encoded().map { String(format: "%02X", $0) }.joined(separator: " ")
            return "  \(direction) \(bytes)"
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Interne

    private func adopt(_ snapshot: DeviceSnapshot) {
        self.snapshot = snapshot
        self.capabilities = controllerCapabilities(for: snapshot)
        self.draft = snapshot.settings
        self.draftBase = snapshot.settings
        self.draftRecovery = nil
        profileImportPreview = nil
        profileCopyPreview = nil
        if let profile = snapshot.activeProfile {
            knownProfileArchives[profile] = profileArchive(for: snapshot)
        }
    }

    /// Adopte un instantané relu sans toucher au brouillon ni à sa base.
    private func adoptKeepingDraft(_ snapshot: DeviceSnapshot) {
        self.snapshot = snapshot
        self.capabilities = controllerCapabilities(for: snapshot)
        if let profile = snapshot.activeProfile {
            knownProfileArchives[profile] = profileArchive(for: snapshot)
        }
        revalidate()
    }

    private func controllerCapabilities(for snapshot: DeviceSnapshot) -> DeviceCapabilities {
        DeviceCapabilities(
            family: snapshot.family,
            catalog: catalog,
            connection: snapshot.identity.connectionType,
            supportsProfiles: snapshot.activeProfile != nil,
            supportsLongDistance: snapshot.family.power.supportsLongDistance,
            supportsSignalStrength: snapshot.signalStrength != nil,
            flashCapabilities: snapshot.flashCapabilities,
            receiver: snapshot.receiverCapabilities
        )
    }

    private func revalidate() {
        guard let snapshot, let capabilities else {
            validationIssues = []
            return
        }
        validationIssues = DraftValidator(
            capabilities: capabilities, family: snapshot.family, catalog: catalog
        ).validate(draft)
    }

    /// Suit les changements provoqués depuis la souris elle-même et les débranchements.
    ///
    /// Les flux sont ouverts ici, et non dans la tâche qui les consomme : sinon la
    /// souscription se ferait après le retour de `connect()`, et un débranchement survenu
    /// entre les deux ne serait jamais remonté — c'est précisément l'évènement qu'on ne
    /// peut pas se permettre de rater.
    private func observeDevice() async {
        notificationTask?.cancel()
        isUserInitiatedDisconnect = false

        let notifications = await controller.changeNotifications()
        notificationTask = Task { @MainActor [weak self] in
            for await notification in notifications {
                guard !notification.isEmpty else { continue }
                await self?.handleDeviceReportedChange()
            }
        }

        // Le flux d'évènements HID ne dépend d'aucune session : il est souscrit une seule
        // fois et reste vivant pendant les coupures, pour voir revenir le périphérique.
        if eventTask == nil {
            let events = await controller.deviceEvents()
            eventTask = Task { @MainActor [weak self] in
                for await event in events {
                    await self?.handle(event)
                }
            }
        }

        if wakeTask == nil {
            let wakes = NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.didWakeNotification)
            wakeTask = Task { @MainActor [weak self] in
                for await _ in wakes {
                    await self?.handleWake()
                }
            }
        }
    }

    /// Une modification faite sur la souris elle-même.
    ///
    /// Sans brouillon, la relecture est la bonne réponse. Avec un brouillon, relire et
    /// remplacer reviendrait à effacer le travail en cours : on relit quand même, mais
    /// pour comparer, pas pour écraser.
    private func handleDeviceReportedChange() async {
        guard !connection.isBusy else { return }
        if hasPendingChanges {
            await reconcile(cause: .deviceReportedChange)
        } else {
            await reload()
        }
    }

    // MARK: Évènements HID et reconnexion

    private func handle(_ event: HIDDeviceEvent) async {
        guard !isDuplicate(event) else { return }
        switch event {
        case .detached(let identifier):
            guard matchesTarget(identifier) else { return }
            await handleDetachment()
        case .attached(let identifier):
            guard matchesTarget(identifier) else { return }
            guard !hasLiveSession, !isUserInitiatedDisconnect, connection != .selectingDevice else { return }
            startReconnection()
        }
    }

    /// Un même branchement remonte plusieurs fois : une par collection HID exposée par le
    /// périphérique. Les traiter toutes lancerait autant de reconnexions concurrentes.
    private func isDuplicate(_ event: HIDDeviceEvent) -> Bool {
        let now = ContinuousClock.now
        defer { lastDeviceEvent = (event, now) }
        guard let last = lastDeviceEvent, last.event == event else { return false }
        return last.at.duration(to: now) < .milliseconds(400)
    }

    /// Sans cible retenue, tout candidat concerne l'application ; avec une cible, seuls les
    /// évènements du même périphérique comptent.
    private func matchesTarget(_ identifier: HIDDeviceIdentifier) -> Bool {
        guard let selectedStableKey else { return true }
        return identifier.stableKey == selectedStableKey
    }

    private func handleDetachment() async {
        hasLiveSession = false
        if case .writing = connection {
            // Une écriture coupée en plein vol laisse un état qu'aucune relecture
            // automatique ne doit trancher, et surtout aucune réécriture.
            connection = .disconnectedDuringWrite(uncertain: pendingChanges.map(\.label))
            requiresExplicitReread = true
            await controller.closeForRecovery()
            return
        }

        // Volontairement pas `disconnect()` : cette méthode efface le brouillon, et un
        // câble qui bouge n'est pas une demande d'abandonner ce qu'on préparait.
        await controller.closeForRecovery()
        notificationTask?.cancel()
        notificationTask = nil

        guard !isUserInitiatedDisconnect else {
            connection = .idle
            return
        }
        startReconnection()
    }

    /// Au réveil, le récepteur a pu être ré-énuméré sans qu'aucun évènement HID n'arrive.
    private func handleWake() async {
        guard !isUserInitiatedDisconnect, !hasLiveSession else { return }
        startReconnection()
    }

    /// Politique de reprise : bornée, non concurrente, et jamais silencieuse.
    ///
    /// Cinq tentatives, un délai qui monte de 250 ms à 2 s, dix secondes au total. Au-delà,
    /// insister n'apporte rien : le périphérique est parti pour de bon et l'utilisateur
    /// reprend la main avec le bouton Réessayer.
    ///
    /// La reprise ne bloque pas son appelant : elle est déclenchée depuis le flux
    /// d'évènements HID, qui doit continuer d'être consommé pendant ces dix secondes —
    /// sinon le rebranchement qu'on attend resterait en file jusqu'à l'abandon.
    private func startReconnection() {
        guard connectionTask == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performReconnection()
        }
        connectionTask = task
        Task { @MainActor [weak self] in
            await task.value
            guard let self, self.connectionTask == task else { return }
            self.connectionTask = nil
        }
    }

    private static let reconnectionDelays: [Duration] = [
        .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(2),
    ]
    private static let reconnectionBudget: Duration = .seconds(10)

    private func performReconnection() async {
        let deadline = ContinuousClock.now + Self.reconnectionBudget

        for (index, delay) in Self.reconnectionDelays.enumerated() {
            guard !Task.isCancelled, !isUserInitiatedDisconnect else { return }
            connection = .reconnecting(attempt: index + 1)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, ContinuousClock.now < deadline else { break }

            let candidates: [HIDDeviceIdentifier]
            do {
                candidates = try await controller.availableDevices()
            } catch DeviceController.ControllerError.permissionDenied {
                // Réessayer une permission refusée cinq fois de suite ne fait que
                // retarder le seul message utile.
                connection = .permissionDenied
                return
            } catch {
                continue
            }
            availableCandidates = candidates

            let matching = selectedStableKey.map { key in
                candidates.filter { $0.stableKey == key }
            } ?? candidates

            // Deux exemplaires du même modèle partagent la clé stable : reprendre le
            // premier reviendrait à choisir à la place de l'utilisateur.
            if matching.count > 1 {
                connection = .selectingDevice
                return
            }
            guard let target = matching.first else { continue }

            do {
                let refreshed = try await controller.connect(to: target)
                selectedStableKey = target.stableKey
                hardwareLocation = target.locationLabel
                hardwareTransport = target.transportLabel
                hasLiveSession = true
                await reconcile(with: refreshed, cause: .reconnected)
                await observeDevice()
                return
            } catch DeviceController.ControllerError.permissionDenied {
                connection = .permissionDenied
                return
            } catch {
                continue
            }
        }

        connection = availableCandidates.isEmpty ? .noDevice : .offline
    }

    // MARK: Récupération du brouillon

    /// Relit le périphérique et compare, sans jamais écrire.
    private func reconcile(cause: DraftRecovery.Cause) async {
        do {
            await reconcile(with: try await controller.readSnapshot(), cause: cause)
        } catch {
            report(error)
        }
    }

    private func reconcile(with refreshed: DeviceSnapshot, cause: DraftRecovery.Cause) async {
        guard let base = draftBase else {
            adopt(refreshed)
            connection = .connected
            return
        }

        let planner = WritePlanner(
            family: refreshed.family,
            catalog: catalog,
            capabilities: controllerCapabilities(for: refreshed)
        )
        let local = planner.changes(from: base, to: draft)
        guard !local.isEmpty else {
            // Aucun travail local en cours : l'état relu fait foi, comme d'habitude.
            adopt(refreshed)
            connection = .connected
            return
        }

        let remote = planner.changes(from: base, to: refreshed.settings)
        if let recovery = DraftRecovery.between(local: local, remote: remote, cause: cause) {
            adoptKeepingDraft(refreshed)
            draftRecovery = recovery
        } else {
            // Le matériel n'a pas bougé sous le brouillon : il n'y a rien à trancher.
            adoptKeepingDraft(refreshed)
            draftBase = refreshed.settings
            draftRecovery = nil
        }
        connection = .connected
    }

    /// Garde les valeurs préparées et repart de l'état relu comme nouvelle base.
    ///
    /// N'écrit rien : le plan est simplement recalculé, et c'est Apply qui décide.
    public func keepDraftAfterRecovery() {
        guard draftRecovery != nil, let snapshot else { return }
        draftBase = snapshot.settings
        draftRecovery = nil
        revalidate()
    }

    /// Abandonne le brouillon au profit de ce que porte réellement le matériel.
    public func adoptRemoteAfterRecovery() {
        guard draftRecovery != nil, let snapshot else { return }
        draft = snapshot.settings
        draftBase = snapshot.settings
        draftRecovery = nil
        lastResult = nil
    }

    private func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
