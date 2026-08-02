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
    private static let profileCount = 3

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
        /// Accepte les commandes récepteur mais n'en modifie pas l'état.
        public var dropReceiverWrites = false
        /// Après ce nombre d'écritures flash réussies, les suivantes sont acquittées sans
        /// effet. Cela permet de tester une restauration partielle de façon déterministe.
        public var dropWritesAfterWriteOperations: Int? = nil
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
    /// Une image de flash par profil : le protocole sélectionne l'emplacement avant les
    /// lectures/écritures, comme sur le matériel. Les tests de copie et de comparaison ne
    /// doivent donc pas donner l'illusion que trois profils partagent la même mémoire.
    private var profileImages: [Int: FlashImage] = [:]
    private var isOpen = false
    private var receivedFrames = 0
    private var writeOperations = 0
    private var responseCount = 0
    private var onlinePolls = 0
    /// Nombre d'ouvertures réussies, pour vérifier qu'aucune session ne fuit après un échec.
    private var openCount = 0
    private var closeCount = 0
    private var battery = BatteryState(percentage: 78, isCharging: false, millivolts: 3980)
    private var signalStrength = 4
    private var activeProfile = 0
    private var longDistance = false
    private var dongleLighting = DongleLightingState(
        mode: 1,
        colors: [255, 255, 255, 255, 255, 255, 255, 255, 255]
    )
    private var receiverEffect = ReceiverLightEffect(
        mode: 3,
        color: CatalogColor(red: 80, green: 160, blue: 255),
        speed: 5,
        brightness: 9,
        duration: 0
    )
    private var receiverDPILightEnabled = true
    private var receiverButtonMode = 0
    private var receiverButtonFunctions = (0..<4).map {
        ReceiverButtonFunction(
            index: $0,
            mode: 0,
            color: CatalogColor(red: 255, green: 255, blue: 255),
            speed: 5,
            brightness: 9,
            duration: 0
        )
    }

    private var flash: FlashImage {
        get { profileImages[activeProfile] ?? FlashImage() }
        set { profileImages[activeProfile] = newValue }
    }

    private var inputContinuations: [UUID: AsyncStream<HIDInputReport>.Continuation] = [:]
    private var eventContinuations: [UUID: AsyncStream<HIDDeviceEvent>.Continuation] = [:]

    /// Simule le modèle indiqué, réglages usine chargés en flash.
    public init(
        catalog: DeviceCatalog = .embedded,
        cid: Int = 87,
        mid: Int = 10,
        connectionType: PulsarConnectionType = .wireless4k,
        dongleType: Int = 1,
        faults: Faults = Faults()
    ) {
        guard let family = catalog.family(cid: cid, mid: mid) else {
            preconditionFailure("CID \(cid) / MID \(mid) absent du catalogue")
        }
        self.family = family
        self.identity = DeviceIdentity(
            cid: cid, mid: mid, connectionType: connectionType, dongleType: dongleType
        )
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
        let factory = Self.factoryImage(catalog: catalog, family: family)
        self.profileImages = (0..<Self.profileCount).reduce(into: [:]) { result, index in
            result[index] = factory
        }
        self.longDistance = family.power.defaultLongDistance
    }

    public func setFaults(_ faults: Faults) {
        self.faults = faults
    }

    /// Image de flash courante, pour qu'un test vérifie ce qui a réellement été écrit.
    public func flashImage() -> FlashImage { flash }

    /// Image d'un emplacement donné, sans changer le profil actif. Réservé aux tests :
    /// le modèle applicatif, lui, passe toujours par la sélection et la relecture du
    /// protocole avant de consulter un profil matériel.
    public func flashImage(forProfile profile: Int) -> FlashImage {
        profileImages[profile] ?? FlashImage()
    }

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
        scalar(0, at: FlashMap.fanMode)
        scalar(0, at: FlashMap.angleTune)
        scalar(0, at: FlashMap.angleTuneState)
        scalar(UInt8(family.power.defaultPowerSaveBattery), at: FlashMap.powerSaveBattery)
        scalar(0, at: FlashMap.dpiEffectMode)
        scalar(UInt8(DPIEffectCodec.defaultBrightness), at: FlashMap.dpiEffectBrightness)
        scalar(UInt8(DPIEffectCodec.defaultSpeed), at: FlashMap.dpiEffectSpeed)
        scalar(1, at: FlashMap.dpiEffectState)

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
        writeOperations = 0
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
            let requested = Int(frame[byte: 5])
            guard (0..<Self.profileCount).contains(requested) else {
                return PulsarFrame(command: .setCurrentConfig, status: 1)
            }
            activeProfile = requested
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
            if !faults.dropReceiverWrites {
                dongleLighting = DongleLightingState(
                    mode: frame[byte: 5],
                    colors: (6...14).map { frame[byte: $0] }
                )
            }
            return PulsarFrame(command: .set4KDongleRGB)

        case .getPulsarDongleLightParam:
            guard !identity.connectionType.isWired, identity.dongleType > 0 else {
                return PulsarFrame(command: .getPulsarDongleLightParam, status: 1)
            }
            return PulsarFrame(command: .getPulsarDongleLightParam, payload: receiverEffect.payload)

        case .setPulsarDongleLightParam:
            guard !identity.connectionType.isWired, identity.dongleType > 0,
                  frame.payload.count >= 7 else {
                return PulsarFrame(command: .setPulsarDongleLightParam, status: 1)
            }
            if !faults.dropReceiverWrites {
                receiverEffect = ReceiverLightEffect(
                    mode: Int(frame[byte: 5]),
                    color: CatalogColor(
                        red: Int(frame[byte: 6]),
                        green: Int(frame[byte: 7]),
                        blue: Int(frame[byte: 8])
                    ),
                    speed: Int(frame[byte: 9]),
                    brightness: Int(frame[byte: 10]),
                    duration: Int(frame[byte: 11])
                )
            }
            return PulsarFrame(command: .setPulsarDongleLightParam)

        case .getPulsarDongleDPILightParam:
            guard !identity.connectionType.isWired, identity.dongleType > 0 else {
                return PulsarFrame(command: .getPulsarDongleDPILightParam, status: 1)
            }
            return PulsarFrame(
                command: .getPulsarDongleDPILightParam,
                payload: [receiverDPILightEnabled ? 1 : 0]
            )

        case .setPulsarDongleDPILightParam:
            guard !identity.connectionType.isWired, identity.dongleType > 0,
                  !frame.payload.isEmpty else {
                return PulsarFrame(command: .setPulsarDongleDPILightParam, status: 1)
            }
            if !faults.dropReceiverWrites {
                receiverDPILightEnabled = frame[byte: 5] == 1
            }
            return PulsarFrame(command: .setPulsarDongleDPILightParam)

        case .getPulsarDongleKeyFunction:
            guard !identity.connectionType.isWired, [2, 4].contains(identity.dongleType) else {
                return PulsarFrame(command: .getPulsarDongleKeyFunction, status: 1)
            }
            return PulsarFrame(command: .getPulsarDongleKeyFunction, payload: [UInt8(receiverButtonMode)])

        case .setPulsarDongleKeyFunction:
            guard !identity.connectionType.isWired, [2, 4].contains(identity.dongleType),
                  !frame.payload.isEmpty else {
                return PulsarFrame(command: .setPulsarDongleKeyFunction, status: 1)
            }
            if !faults.dropReceiverWrites {
                receiverButtonMode = Int(frame[byte: 5])
            }
            return PulsarFrame(command: .setPulsarDongleKeyFunction)

        case .getPulsarDongleOButtonCurrentMode:
            guard !identity.connectionType.isWired, identity.dongleType == 1 else {
                return PulsarFrame(command: .getPulsarDongleOButtonCurrentMode, status: 1)
            }
            return PulsarFrame(
                command: .getPulsarDongleOButtonCurrentMode,
                payload: [UInt8(receiverButtonMode)]
            )

        case .setPulsarDongleOButtonCurrentMode:
            guard !identity.connectionType.isWired, identity.dongleType == 1,
                  !frame.payload.isEmpty else {
                return PulsarFrame(command: .setPulsarDongleOButtonCurrentMode, status: 1)
            }
            if !faults.dropReceiverWrites {
                receiverButtonMode = Int(frame[byte: 5])
            }
            return PulsarFrame(command: .setPulsarDongleOButtonCurrentMode)

        case .getPulsarDongleOButtonFunction:
            guard !identity.connectionType.isWired, identity.dongleType == 1 else {
                return PulsarFrame(command: .getPulsarDongleOButtonFunction, status: 1)
            }
            let index = Int(frame[byte: 5])
            guard let function = receiverButtonFunctions.first(where: { $0.index == index }) else {
                return PulsarFrame(command: .getPulsarDongleOButtonFunction, status: 1)
            }
            return PulsarFrame(command: .getPulsarDongleOButtonFunction, payload: [
                UInt8(clamping: function.index),
                UInt8(clamping: function.mode),
                UInt8(clamping: function.color.red),
                UInt8(clamping: function.color.green),
                UInt8(clamping: function.color.blue),
                UInt8(clamping: function.speed),
                UInt8(clamping: function.brightness),
                UInt8(clamping: function.duration),
            ])

        case .setPulsarDongleOButtonFunction:
            guard !identity.connectionType.isWired, identity.dongleType == 1,
                  frame.payload.count >= 8 else {
                return PulsarFrame(command: .setPulsarDongleOButtonFunction, status: 1)
            }
            let function = ReceiverButtonFunction(
                index: Int(frame[byte: 5]),
                mode: Int(frame[byte: 6]),
                color: CatalogColor(
                    red: Int(frame[byte: 7]),
                    green: Int(frame[byte: 8]),
                    blue: Int(frame[byte: 9])
                ),
                speed: Int(frame[byte: 10]),
                brightness: Int(frame[byte: 11]),
                duration: Int(frame[byte: 12])
            )
            guard receiverButtonFunctions.contains(where: { $0.index == function.index }) else {
                return PulsarFrame(command: .setPulsarDongleOButtonFunction, status: 1)
            }
            if !faults.dropReceiverWrites,
               let position = receiverButtonFunctions.firstIndex(where: { $0.index == function.index }) {
                receiverButtonFunctions[position] = function
            }
            return PulsarFrame(command: .setPulsarDongleOButtonFunction)

        case .getRSSIValue:
            guard !identity.connectionType.isWired else {
                return PulsarFrame(command: .getRSSIValue, status: 1)
            }
            return PulsarFrame(command: .getRSSIValue, payload: [UInt8(signalStrength)])

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
            let shouldDrop = faults.dropWrites
                || faults.dropWritesAfterWriteOperations.map { writeOperations >= $0 } == true
            writeOperations += 1
            if !shouldDrop {
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

    /// Change le RSSI relu par `GetRSSIValue`, afin de tester le suivi sans fil en continu.
    public func setSignalStrength(_ strength: Int) {
        signalStrength = min(max(strength, 0), 5)
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
