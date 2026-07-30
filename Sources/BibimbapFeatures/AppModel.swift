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
        case connecting
        case reading
        case connected
        case writing(progress: Double)
        case noDevice
        case offline
        case unrecognised(cid: Int, mid: Int)
        case failed(String)
        case disconnectedDuringWrite(uncertain: [String])

        public var isBusy: Bool {
            switch self {
            case .scanning, .connecting, .reading, .writing: true
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

    public var section: Section = .performance
    /// Brouillon local. Rien n'atteint le matériel avant `apply()`.
    public var draft = DeviceSettings() {
        didSet { revalidate() }
    }

    private let controller: DeviceController
    private let catalog: DeviceCatalog
    private var notificationTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

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

    // MARK: Dérivés

    public var pendingChanges: [PendingChange] {
        guard let snapshot else { return [] }
        return WritePlanner(family: snapshot.family, catalog: catalog)
            .changes(from: snapshot.settings, to: draft)
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
        snapshot?.family.buttons ?? []
    }

    public var canApply: Bool {
        hasPendingChanges
            && !validationIssues.contains(where: \.isBlocking)
            && !connection.isBusy
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

    public func connect() async {
        connection = .scanning
        do {
            let devices = try await controller.availableDevices()
            guard !devices.isEmpty else {
                connection = .noDevice
                return
            }
            connection = .connecting
            let snapshot = try await controller.connect(to: devices.first)
            connection = .reading
            adopt(snapshot)
            connection = .connected
            observeDevice()
        } catch DeviceController.ControllerError.unrecognisedDevice(let cid, let mid) {
            connection = .unrecognised(cid: cid, mid: mid)
        } catch DeviceController.ControllerError.deviceOffline {
            connection = .offline
        } catch DeviceController.ControllerError.noConfigurationInterface {
            connection = .noDevice
        } catch {
            connection = .failed(message(for: error))
        }
    }

    public func disconnect() async {
        notificationTask?.cancel()
        eventTask?.cancel()
        await controller.disconnect()
        snapshot = nil
        capabilities = nil
        draft = DeviceSettings()
        connection = .idle
    }

    /// Abandonne le brouillon et revient à l'état lu.
    public func revert() {
        guard let snapshot else { return }
        draft = snapshot.settings
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

    public func reload() async {
        guard snapshot != nil else { return }
        connection = .reading
        do {
            adopt(try await controller.readSnapshot())
            connection = .connected
        } catch {
            connection = .failed(message(for: error))
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
    private func observeDevice() {
        notificationTask?.cancel()
        eventTask?.cancel()

        notificationTask = Task { [weak self] in
            guard let self else { return }
            for await notification in await self.controller.changeNotifications() {
                guard !notification.isEmpty else { continue }
                // Une modification en attente ne doit pas être écrasée sans le dire :
                // on ne recharge que si l'utilisateur n'a rien de local en cours.
                if await !self.hasPendingChanges {
                    await self.reload()
                }
            }
        }

        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.controller.deviceEvents() {
                if case .detached = event {
                    await self.handleDetachment()
                }
            }
        }
    }

    private func handleDetachment() async {
        if case .writing = connection {
            connection = .disconnectedDuringWrite(uncertain: pendingChanges.map(\.label))
        } else {
            await disconnect()
            connection = .noDevice
        }
    }

    private func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
