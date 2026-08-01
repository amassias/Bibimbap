import AppKit
import BibimbapLocalization
import Foundation
import Observation
import PulsarCatalog
import PulsarHID
import PulsarProtocol
import PulsarSimulator

/// État de l'application, observé par les vues.
@MainActor
@Observable
public final class AppModel {
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
        return WritePlanner(family: snapshot.family, catalog: catalog)
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
        if capabilities.supportsBattery || capabilities.supportsLongDistance || capabilities.supportsFanMode {
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
        let plan = WritePlanner(family: snapshot.family, catalog: catalog)
            .plan(from: snapshot.settings, to: draft)
        guard !plan.isEmpty else { return }

        connection = .writing(progress: 0)
        do {
            let result = try await controller.apply(plan)
            lastResult = result
            let refreshed = try await controller.readSnapshot()
            adopt(refreshed)
            if case .failedAndUncertain(_, let uncertain) = result.outcome {
                connection = .disconnectedDuringWrite(uncertain: uncertain)
                requiresExplicitReread = true
            } else {
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

    /// Relecture demandée explicitement : c'est elle qui lève un état matériel incertain.
    public func reload() async {
        guard snapshot != nil else { return }
        connection = .reading
        do {
            adopt(try await controller.readSnapshot())
            requiresExplicitReread = false
            connection = .connected
        } catch {
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
        do {
            try await controller.setActiveProfile(profile)
            await reload()
        } catch {
            connection = .failed(message(for: error))
        }
    }

    public func setDongleLightEnabled(_ enabled: Bool) async {
        guard snapshot?.dongleLighting != nil, !connection.isBusy else { return }
        connection = .writing(progress: 0)
        do {
            adopt(try await controller.setDongleLightEnabled(enabled))
            connection = .connected
        } catch {
            connection = .failed(message(for: error))
        }
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

    /// Exporte les réglages relus, dans un format versionné et relisible.
    public func exportProfile() -> ProfileArchive? {
        guard let snapshot else { return nil }
        return ProfileArchive(snapshot: snapshot)
    }

    /// Charge une sauvegarde dans le brouillon, sans rien écrire.
    ///
    /// Les réglages qu'un modèle ne sait pas représenter sont écartés plutôt qu'appliqués
    /// de force : restaurer une sauvegarde de X2 sur un autre capteur ne doit pas produire
    /// des paliers DPI impossibles.
    public func importProfile(_ archive: ProfileArchive) -> [String] {
        guard let snapshot, let capabilities else { return [] }
        let (settings, skipped) = archive.settings(
            fittingFamily: snapshot.family,
            capabilities: capabilities,
            catalog: catalog,
            current: snapshot.settings
        )
        draft = settings
        return skipped
    }

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
            ]
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
    }

    /// Adopte un instantané relu sans toucher au brouillon ni à sa base.
    private func adoptKeepingDraft(_ snapshot: DeviceSnapshot) {
        self.snapshot = snapshot
        self.capabilities = controllerCapabilities(for: snapshot)
        revalidate()
    }

    private func controllerCapabilities(for snapshot: DeviceSnapshot) -> DeviceCapabilities {
        DeviceCapabilities(
            family: snapshot.family,
            catalog: catalog,
            connection: snapshot.identity.connectionType,
            supportsProfiles: snapshot.activeProfile != nil,
            supportsLongDistance: snapshot.family.power.supportsLongDistance,
            supportsSignalStrength: snapshot.signalStrength != nil
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

        let planner = WritePlanner(family: refreshed.family, catalog: catalog)
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
