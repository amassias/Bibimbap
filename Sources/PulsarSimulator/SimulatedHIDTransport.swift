import Foundation
import PulsarCatalog
import PulsarHID
import PulsarProtocol

/// Transport HID simulé, exposant strictement la même interface que le matériel.
///
/// Sert à trois choses : faire tourner l'application sans souris branchée, rejouer des
/// scénarios de panne qu'on ne peut pas provoquer à volonté sur du vrai matériel
/// (checksum faux, timeout, écriture partielle, relecture divergente), et donner aux
/// tests un périphérique déterministe.
public actor SimulatedHIDTransport: HIDTransport {
    /// Défauts injectables, pour éprouver les chemins d'erreur.
    public struct Faults: Sendable {
        /// Ne répond pas aux commandes listées.
        public var silentCommands: Set<PulsarCommand> = []
        /// Répond `status = 1` aux commandes listées, comme un modèle qui ne les gère pas.
        public var unsupportedCommands: Set<PulsarCommand> = []
        /// Corrompt le checksum d'une réponse sur `n`.
        public var corruptEveryNthResponse: Int?
        /// Accepte l'écriture mais n'applique rien, ce qui fait diverger la relecture.
        public var dropWrites = false
        /// Interrompt la connexion après ce nombre de trames reçues.
        public var disconnectAfterFrames: Int?
        /// Latence ajoutée à chaque réponse.
        public var latency: Duration = .zero

        /// Collections supplémentaires énumérées à côté du périphérique simulé.
        ///
        /// Elles ne répondent à rien : leur seul rôle est de reproduire une machine où
        /// plusieurs souris Pulsar sont branchées en même temps.
        public var extraCandidates: [HIDDeviceIdentifier] = []
        /// Nombre d'interrogations « en ligne ? » répondant « le récepteur cherche encore »
        /// avant que la souris ne se signale.
        public var pollsBeforeOnline = 0
        /// La souris ne se signale jamais : le récepteur répond pour lui seul.
        public var staysOffline = false
        /// Le périphérique n'est plus énuméré du tout.
        public var isMissing = false
        /// Erreur renvoyée par `discover()`, pour rejouer une permission refusée.
        public var discoveryFailure: HIDTransportError?
        /// Erreur renvoyée par `open()`.
        public var openFailure: HIDTransportError?
        /// Ouvertures qui échouent avant que le périphérique n'accepte, pour rejouer une
        /// interface qui disparaît un instant puis revient — un rebranchement, typiquement.
        public var transientOpenFailures = 0

        public init() {}
    }

    private let identifier: HIDDeviceIdentifier
    private let family: DeviceFamily
    private let identity: DeviceIdentity
    private let firmwareVersion: String

    private var faults: Faults
    private var flash = FlashImage()
    private var isOpen = false
    private var receivedFrames = 0
    private var responseCount = 0
    private var onlinePolls = 0
    /// Nombre d'ouvertures réussies, pour vérifier qu'aucune session ne fuit après un échec.
    private var openCount = 0
    private var closeCount = 0
    private var battery = BatteryState(percentage: 78, isCharging: false, millivolts: 3980)
    private var activeProfile = 0
    private var longDistance = false
    private var dongleLighting = DongleLightingState(
        mode: 1,
        colors: [255, 255, 255, 255, 255, 255, 255, 255, 255]
    )

    private var inputContinuations: [UUID: AsyncStream<HIDInputReport>.Continuation] = [:]
    private var eventContinuations: [UUID: AsyncStream<HIDDeviceEvent>.Continuation] = [:]

    /// Simule le modèle indiqué, réglages usine chargés en flash.
    public init(
        catalog: DeviceCatalog = .embedded,
        cid: Int = 87,
        mid: Int = 10,
        connectionType: PulsarConnectionType = .wireless4k,
        faults: Faults = Faults()
    ) {
        guard let family = catalog.family(cid: cid, mid: mid) else {
            preconditionFailure("CID \(cid) / MID \(mid) absent du catalogue")
        }
        self.family = family
        self.identity = DeviceIdentity(cid: cid, mid: mid, connectionType: connectionType, dongleType: 1)
        self.firmwareVersion = family.firmware.deviceVersion ?? "v1.00"
        self.faults = faults
        self.identifier = HIDDeviceIdentifier(
            vendorID: catalog.vendorIDs.first ?? 0x3710,
            productID: connectionType.isWired
                ? (catalog.mouseProductIDs.wired.first ?? 0x3414)
                : (catalog.mouseProductIDs.wireless.first ?? 0x5406),
            locationID: 0,
            usagePage: 0xFF05,
            usage: 0,
            productName: "Pulsar \(family.theme) (simulé)",
            manufacturer: "Pulsar",
            transport: connectionType.isWired ? .usb : .other,
            maxInputReportSize: PulsarFrame.length + 1,
            maxOutputReportSize: PulsarFrame.length + 1
        )
        self.flash = Self.factoryImage(catalog: catalog, family: family)
        self.longDistance = family.power.defaultLongDistance
    }

    public func setFaults(_ faults: Faults) {
        self.faults = faults
    }

    /// Image de flash courante, pour qu'un test vérifie ce qui a réellement été écrit.
    public func flashImage() -> FlashImage { flash }

    // MARK: Réglages usine

    private static func factoryImage(catalog: DeviceCatalog, family: DeviceFamily) -> FlashImage {
        var flash = FlashImage()
        func scalar(_ value: UInt8, at address: UInt16) {
            flash.write(ScalarSetting(address: address, value: value).encoded, at: address)
        }

        scalar(ReportRateCodec.code(from: min(1000, family.maximumReportRate)) ?? 1, at: FlashMap.reportRate)
        scalar(UInt8(family.dpi.stages.count), at: FlashMap.maxDPIStage)
        scalar(UInt8(family.dpi.defaultStage), at: FlashMap.currentDPI)
        scalar(UInt8(family.sensor.defaultLiftOff), at: FlashMap.liftOffDistance)
        scalar(UInt8(family.debounce.default), at: FlashMap.debounceTime)
        scalar(family.sensor.supportsMotionSync ? 1 : 0, at: FlashMap.motionSync)
        scalar(0, at: FlashMap.angleSnap)
        scalar(family.sensor.supportsRippleControl ? 1 : 0, at: FlashMap.rippleControl)
        scalar(UInt8(family.power.defaultSleepTimeCode), at: FlashMap.sleepTime)
        scalar(family.sensor.supportsPerformanceMode ? 1 : 0, at: FlashMap.performanceState)
        scalar(UInt8(family.power.defaultSleepTimeCode), at: FlashMap.performance)
        scalar(UInt8(family.sensor.defaultSensorMode), at: FlashMap.sensorMode)
        scalar(0, at: FlashMap.angleTune)
        scalar(0, at: FlashMap.angleTuneState)
        scalar(UInt8(family.power.defaultPowerSaveBattery), at: FlashMap.powerSaveBattery)
        scalar(0, at: FlashMap.dpiEffectMode)

        if let codec = DPICodec(family: family, catalog: catalog) {
            for (index, stage) in family.dpi.stages.enumerated() {
                if let block = try? codec.encodeStage(x: stage.value, y: stage.value) {
                    flash.write(block, at: FlashMap.dpiValue(stage: index, extended: codec.usesExtendedBlock))
                }
                let colour = [UInt8(stage.color.red), UInt8(stage.color.green), UInt8(stage.color.blue)]
                flash.write(colour + [PulsarFrame.blockChecksum(over: colour)],
                            at: FlashMap.dpiColor(stage: index))
            }
        }

        for button in family.buttons {
            let head: [UInt8] = [
                UInt8(button.defaultType),
                UInt8(truncatingIfNeeded: button.defaultParameter >> 8),
                UInt8(truncatingIfNeeded: button.defaultParameter),
            ]
            flash.write(
                head + [PulsarFrame.blockChecksum(over: head)],
                at: FlashMap.keyFunction(button: button.index)
            )
        }
        return flash
    }

    private func loadFactoryDefaults(catalog: DeviceCatalog) {
        flash = Self.factoryImage(catalog: catalog, family: family)
        longDistance = family.power.defaultLongDistance
    }

    // MARK: HIDTransport

    public func discover() async throws -> [HIDDeviceIdentifier] {
        if let failure = faults.discoveryFailure { throw failure }
        return (faults.isMissing ? [] : [identifier]) + faults.extraCandidates
    }

    public func open(_ identifier: HIDDeviceIdentifier) async throws {
        if let failure = faults.openFailure { throw failure }
        if faults.transientOpenFailures > 0 {
            faults.transientOpenFailures -= 1
            throw HIDTransportError.deviceNotFound
        }
        guard !faults.isMissing, identifier == self.identifier else {
            throw HIDTransportError.deviceNotFound
        }
        isOpen = true
        openCount += 1
        receivedFrames = 0
        onlinePolls = 0
    }

    public func close() async {
        if isOpen { closeCount += 1 }
        isOpen = false
        inputContinuations.values.forEach { $0.finish() }
        inputContinuations.removeAll()
    }

    /// Identité du périphérique simulé, pour piloter la sélection depuis un test.
    public func deviceIdentifier() -> HIDDeviceIdentifier { identifier }

    /// Vrai si une collection est encore ouverte : c'est ce qu'un test vérifie après un
    /// échec de connexion, pour s'assurer que rien n'est resté saisi en arrière-plan.
    public func isCurrentlyOpen() -> Bool { isOpen }

    public func openSessionCount() -> Int { openCount - closeCount }
    public func totalOpenCount() -> Int { openCount }

    public func currentDevice() async -> HIDDeviceIdentifier? { isOpen ? identifier : nil }

    public func inputReports() async -> AsyncStream<HIDInputReport> {
        let id = UUID()
        return AsyncStream { continuation in
            inputContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropInput(id) }
            }
        }
    }

    public func deviceEvents() async -> AsyncStream<HIDDeviceEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.yield(.attached(identifier))
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropEvent(id) }
            }
        }
    }

    private func dropInput(_ id: UUID) { inputContinuations.removeValue(forKey: id) }
    private func dropEvent(_ id: UUID) { eventContinuations.removeValue(forKey: id) }

    public func send(reportID: UInt8, payload: [UInt8]) async throws {
        guard isOpen else { throw HIDTransportError.notOpen }
        guard reportID == PulsarFrame.reportID else { return }

        // Le transport reçoit le tampon complet, identifiant de rapport en tête.
        var bytes = payload
        if bytes.first == PulsarFrame.reportID, bytes.count == PulsarFrame.length + 1 {
            bytes.removeFirst()
        }
        guard let frame = try? PulsarFrame(decoding: bytes) else { return }

        receivedFrames += 1
        if let limit = faults.disconnectAfterFrames, receivedFrames > limit {
            await close()
            throw HIDTransportError.disconnected
        }
        guard !faults.silentCommands.contains(frame.command) else { return }

        if faults.latency > .zero {
            try? await Task.sleep(for: faults.latency)
        }
        if let response = respond(to: frame) {
            emit(response)
        }
    }

    // MARK: Logique du périphérique

    private func respond(to frame: PulsarFrame) -> PulsarFrame? {
        if faults.unsupportedCommands.contains(frame.command) {
            return PulsarFrame(command: frame.command, status: 1)
        }

        switch frame.command {
        case .encryptionData:
            // Le défi doit être présent, comme sur le matériel.
            guard frame.effectiveLength >= 4 else {
                return PulsarFrame(command: .encryptionData, status: 1)
            }
            var payload = [UInt8](repeating: 0, count: 8)
            payload[4] = UInt8(identity.cid)
            payload[5] = UInt8(identity.mid)
            payload[6] = identity.connectionType.rawValue
            payload[7] = UInt8(identity.dongleType)
            return PulsarFrame(command: .encryptionData, payload: payload)

        case .pcDriverStatus:
            return PulsarFrame(command: .pcDriverStatus)

        case .deviceOnline:
            // Sans charge utile, la commande interroge l'état ; avec, elle prend ou rend
            // le verrou d'écriture. Seule l'interrogation doit subir le délai simulé.
            guard frame.effectiveLength == 0 else {
                return PulsarFrame(command: .deviceOnline, payload: [1, 0, 0, 0, 0])
            }
            onlinePolls += 1
            if onlinePolls <= faults.pollsBeforeOnline {
                // Octet 9 à 1 : le récepteur est encore en train de joindre la souris.
                return PulsarFrame(command: .deviceOnline, payload: [0, 0, 0, 0, 1])
            }
            return PulsarFrame(
                command: .deviceOnline, payload: [faults.staysOffline ? 0 : 1, 0, 0, 0, 0]
            )

        case .batteryLevel:
            return PulsarFrame(command: .batteryLevel, payload: [
                UInt8(battery.percentage),
                battery.isCharging ? 1 : 0,
                UInt8(truncatingIfNeeded: battery.millivolts >> 8),
                UInt8(truncatingIfNeeded: battery.millivolts),
            ])

        case .readVersionID, .getDongleVersion:
            // "v3.05" : majeur en décimal, mineur en hexadécimal.
            let parts = firmwareVersion.dropFirst().split(separator: ".")
            let major = parts.count > 0 ? (UInt8(parts[0]) ?? 1) : 1
            let minor = parts.count > 1 ? (UInt8(parts[1], radix: 16) ?? 0) : 0
            return PulsarFrame(command: frame.command, payload: [major, minor])

        case .getCurrentConfig:
            return PulsarFrame(command: .getCurrentConfig, payload: [UInt8(activeProfile)])

        case .setCurrentConfig:
            activeProfile = Int(frame[byte: 5])
            return PulsarFrame(command: .setCurrentConfig)

        case .getLongRangeMode:
            guard family.power.supportsLongDistance else {
                return PulsarFrame(command: .getLongRangeMode, status: 1)
            }
            return PulsarFrame(command: .getLongRangeMode, payload: [longDistance ? 1 : 0])

        case .setLongRangeMode:
            longDistance = frame[byte: 5] == 1
            return PulsarFrame(command: .setLongRangeMode)

        case .get4KDongleRGBValue:
            guard !identity.connectionType.isWired else {
                return PulsarFrame(command: .get4KDongleRGBValue, status: 1)
            }
            return PulsarFrame(
                command: .get4KDongleRGBValue,
                payload: [dongleLighting.mode] + dongleLighting.colors
            )

        case .set4KDongleRGB:
            guard !identity.connectionType.isWired else {
                return PulsarFrame(command: .set4KDongleRGB, status: 1)
            }
            dongleLighting = DongleLightingState(
                mode: frame[byte: 5],
                colors: (6...14).map { frame[byte: $0] }
            )
            return PulsarFrame(command: .set4KDongleRGB)

        case .getRSSIValue:
            guard !identity.connectionType.isWired else {
                return PulsarFrame(command: .getRSSIValue, status: 1)
            }
            return PulsarFrame(command: .getRSSIValue, payload: [4])

        case .readFlashData:
            let count = Int(frame.effectiveLength)
            let data = flash.slice(at: frame.address, count: count)
            return PulsarFrame(
                command: .readFlashData,
                address: frame.address,
                payload: data,
                declaredLength: UInt8(data.count)
            )

        case .writeFlashData:
            if !faults.dropWrites {
                flash.write(frame.payload, at: frame.address)
            }
            return PulsarFrame(
                command: .writeFlashData,
                address: frame.address,
                declaredLength: frame.effectiveLength
            )

        case .clearSetting:
            flash = FlashImage()
            loadFactoryDefaults(catalog: .embedded)
            return PulsarFrame(command: .clearSetting)

        case .dongleEnterPair:
            return PulsarFrame(command: .dongleEnterPair)

        case .getPairState:
            return PulsarFrame(command: .getPairState, payload: [PulsarPairState.succeeded.rawValue, 0])

        default:
            return PulsarFrame(command: frame.command, status: 1)
        }
    }

    private func emit(_ frame: PulsarFrame) {
        responseCount += 1
        var bytes = frame.encoded()
        if let every = faults.corruptEveryNthResponse, every > 0, responseCount % every == 0 {
            bytes[PulsarFrame.length - 1] = bytes[PulsarFrame.length - 1] &+ 1
        }
        let report = HIDInputReport(reportID: PulsarFrame.reportID, bytes: bytes)
        inputContinuations.values.forEach { $0.yield(report) }
    }

    // MARK: Pilotage depuis les tests

    /// Pousse une notification de changement, comme si l'utilisateur avait agi sur la souris.
    public func pushChangeNotification(primary: UInt8, secondary: UInt8) {
        emit(PulsarFrame(command: .statusChanged, payload: [primary, secondary]))
    }

    public func setBattery(_ state: BatteryState) {
        battery = state
    }

    /// Débranche le périphérique : la collection disparaît de l'énumération, la session
    /// ouverte est refermée et l'évènement part, exactement comme le fait IOKit.
    public func detachDevice() async {
        faults.isMissing = true
        await close()
        eventContinuations.values.forEach { $0.yield(.detached(identifier)) }
    }

    /// Rebranche le périphérique et signale son retour.
    public func attachDevice() {
        faults.isMissing = false
        eventContinuations.values.forEach { $0.yield(.attached(identifier)) }
    }

    /// Change un réglage dans la flash sans passer par le protocole, comme le ferait
    /// l'utilisateur en agissant directement sur la souris.
    public func changeSettingOnDevice(_ value: UInt8, at address: UInt16) {
        flash.write(ScalarSetting(address: address, value: value).encoded, at: address)
    }

    /// Rejoue un évènement déjà émis, pour vérifier que les doublons sont absorbés.
    public func replayEvent(_ event: HIDDeviceEvent) {
        eventContinuations.values.forEach { $0.yield(event) }
    }
}
