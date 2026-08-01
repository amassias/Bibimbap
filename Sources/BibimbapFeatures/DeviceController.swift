import BibimbapLocalization
import Foundation
import PulsarCatalog
import PulsarHID
import PulsarProtocol

/// Enchaîne les opérations protocolaires pour le compte de l'interface.
///
/// C'est ici que vit la règle centrale du projet : rien n'est réputé écrit tant que
/// la relecture ne l'a pas confirmé, et un lot qui échoue est défait au mieux.
public actor DeviceController {
    /// Les modèles actuellement décrits par le protocole exposent trois emplacements
    /// sélectionnables. On ne déduit jamais ce nombre d'un octet arbitraire relu.
    public static let profileCount = 3

    private let transport: any HIDTransport
    private let catalog: DeviceCatalog
    private var session: PulsarSession?
    private var identifier: HIDDeviceIdentifier?
    private var connectionLogEntries: [ConnectionLogEntry] = []

    public init(transport: any HIDTransport, catalog: DeviceCatalog = .embedded) {
        self.transport = transport
        self.catalog = catalog
    }

    public enum ControllerError: Error, Equatable, Sendable {
        case noConfigurationInterface
        case unrecognisedDevice(cid: Int, mid: Int)
        case deviceOffline
        case notConnected
        /// macOS refuse l'accès HID : réessayer en boucle ne servirait à rien.
        case permissionDenied
        /// La collection visée n'est plus énumérée : câble retiré, dongle rebranché ailleurs.
        case interfaceDisappeared
        /// Le périphérique n'a pas répondu au dialogue d'identification.
        case handshakeTimedOut
        /// L'ouverture a été refusée pour une raison autre qu'une permission manquante.
        case openFailed(code: Int32)
        /// Tout le reste : le dialogue a eu lieu mais n'a pas abouti.
        case communicationFailure(String)
        /// La commande de sélection a été acquittée mais la relecture ne confirme pas
        /// l'emplacement demandé.
        case profileSelectionReadbackMismatch(expected: Int, actual: Int?)
    }

    // MARK: Journal de connexion


    /// Trace des tentatives de connexion, distincte du journal de trames.
    ///
    /// Un échec avant `identify` ne produit aucune trame : sans ce journal, le rapport de
    /// diagnostic serait vide précisément dans les cas les plus opaques (permission
    /// refusée, ouverture refusée, interface disparue).
    public struct ConnectionLogEntry: Sendable, Equatable {
        public enum Phase: String, Sendable, CaseIterable {
            case discover, permission, open, identify, online, snapshot
        }

        public enum Outcome: Equatable, Sendable {
            case started
            case succeeded(String)
            case failed(String)
        }

        public var phase: Phase
        /// Candidat concerné, `nil` tant qu'aucun n'est choisi.
        public var candidate: String?
        public var outcome: Outcome
        /// Code système remonté par IOKit, lorsqu'il y en a un.
        public var systemCode: Int32?
        public var timestamp: Date

        public var line: String {
            let time = ISO8601DateFormatter().string(from: timestamp)
            let result = switch outcome {
            case .started: "…"
            case .succeeded(let detail): detail.isEmpty ? "ok" : "ok — \(detail)"
            case .failed(let reason): "échec — \(reason)"
            }
            let code = systemCode.map { " [code \($0)]" } ?? ""
            return "\(time)  \(phase.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + "\(candidate ?? "—")  \(result)\(code)"
        }
    }

    public func connectionLog() -> [ConnectionLogEntry] { connectionLogEntries }

    private func log(
        _ phase: ConnectionLogEntry.Phase,
        candidate: HIDDeviceIdentifier?,
        _ outcome: ConnectionLogEntry.Outcome,
        systemCode: Int32? = nil
    ) {
        connectionLogEntries.append(ConnectionLogEntry(
            phase: phase,
            candidate: candidate.map { "\($0.displayName) (\($0.vendorProductLabel), \($0.locationLabel))" },
            outcome: outcome,
            systemCode: systemCode,
            timestamp: Date()
        ))
        if connectionLogEntries.count > 128 {
            connectionLogEntries.removeFirst(connectionLogEntries.count - 128)
        }
    }

    // MARK: Connexion

    /// Collections susceptibles de porter une souris Pulsar configurable.
    public func availableDevices() async throws -> [HIDDeviceIdentifier] {
        do {
            let all = try await transport.discover()
            let candidates = all.filter {
                $0.matchesConfigurationInterface(frameLength: PulsarFrame.length)
            }
            log(.discover, candidate: nil, .succeeded(
                "\(candidates.count) candidat(s) sur \(all.count) collection(s)"
            ))
            return candidates
        } catch {
            let mapped = Self.mapped(error)
            log(
                mapped == .permissionDenied ? .permission : .discover,
                candidate: nil,
                .failed(Self.describe(error)),
                systemCode: Self.systemCode(error)
            )
            throw mapped
        }
    }

    /// Ouvre un candidat et ne rend la main qu'une fois l'état complet relu.
    ///
    /// La séquence est stricte et volontairement séquentielle : découvrir, ouvrir, démarrer
    /// la session, identifier, vérifier le catalogue, attendre la souris derrière son
    /// récepteur, signaler le driver, relire. Chaque échec après l'ouverture referme la
    /// session **et** le transport : une collection laissée ouverte en arrière-plan empêche
    /// la tentative suivante et retient l'autorisation macOS pour rien.
    public func connect(to identifier: HIDDeviceIdentifier? = nil) async throws -> DeviceSnapshot {
        do {
            return try await attemptConnection(to: identifier)
        } catch ControllerError.interfaceDisappeared {
            // Un rebranchement en cours d'ouverture invalide l'énumération précédente.
            // Une seule ré-énumération : au-delà, c'est une panne, pas un aléa.
            log(.discover, candidate: identifier, .started)
            return try await attemptConnection(rediscoveringKeyOf: identifier)
        }
    }

    private func attemptConnection(
        to identifier: HIDDeviceIdentifier? = nil,
        rediscoveringKeyOf previous: HIDDeviceIdentifier? = nil
    ) async throws -> DeviceSnapshot {
        // 1. Découvrir.
        let target: HIDDeviceIdentifier
        if let previous {
            let candidates = try await availableDevices()
            guard let refreshed = candidates.first(where: { $0.stableKey == previous.stableKey }) else {
                throw ControllerError.interfaceDisappeared
            }
            target = refreshed
        } else if let identifier {
            target = identifier
        } else {
            let candidates = try await availableDevices()
            guard let first = candidates.first else {
                throw ControllerError.noConfigurationInterface
            }
            target = first
        }

        // 2. Ouvrir.
        log(.open, candidate: target, .started)
        do {
            try await transport.open(target)
        } catch {
            let mapped = Self.mapped(error)
            log(
                mapped == .permissionDenied ? .permission : .open,
                candidate: target,
                .failed(Self.describe(error)),
                systemCode: Self.systemCode(error)
            )
            throw mapped
        }
        log(.open, candidate: target, .succeeded(""))

        // 3. Démarrer la session. À partir d'ici, tout échec doit refermer.
        let session = PulsarSession(transport: transport)
        await session.start()
        self.session = session
        self.identifier = target

        do {
            // 4. Identifier CID/MID.
            log(.identify, candidate: target, .started)
            let identity = try await session.identify()
            log(.identify, candidate: target, .succeeded("CID \(identity.cid) / MID \(identity.mid)"))

            // 5. Vérifier le catalogue.
            guard catalog.family(cid: identity.cid, mid: identity.mid) != nil else {
                throw ControllerError.unrecognisedDevice(cid: identity.cid, mid: identity.mid)
            }

            // 6. Derrière un dongle, le récepteur répond au handshake avant que la souris ne
            // soit jointe. Lire la flash à ce moment-là expire sans explication utile.
            log(.online, candidate: target, .started)
            guard try await session.waitUntilOnline() else {
                throw ControllerError.deviceOffline
            }
            log(.online, candidate: target, .succeeded(""))

            // 7. Signale au périphérique qu'un logiciel prend la main.
            try? await session.setDriverOnline(true)

            // 8. Relire l'instantané complet.
            log(.snapshot, candidate: target, .started)
            let snapshot = try await readSnapshot()
            log(.snapshot, candidate: target, .succeeded(snapshot.family.theme))
            return snapshot
        } catch {
            let mapped = Self.mapped(error)
            log(
                phase(for: mapped),
                candidate: target,
                .failed(Self.describe(error)),
                systemCode: Self.systemCode(error)
            )
            await closeAfterFailure()
            throw mapped
        }
    }

    private func phase(for error: ControllerError) -> ConnectionLogEntry.Phase {
        switch error {
        case .permissionDenied: .permission
        case .interfaceDisappeared, .openFailed: .open
        case .handshakeTimedOut, .unrecognisedDevice: .identify
        case .deviceOffline: .online
        default: .snapshot
        }
    }

    /// Referme sans dialoguer : le périphérique vient de refuser le dialogue.
    private func closeAfterFailure() async {
        if let session { await session.stop() }
        session = nil
        identifier = nil
        await transport.close()
    }

    /// Traduit une erreur de transport ou de session en cause nommable.
    private static func mapped(_ error: any Error) -> ControllerError {
        if let controller = error as? ControllerError { return controller }
        if let transport = error as? HIDTransportError {
            return switch transport {
            case .permissionDenied: .permissionDenied
            case .deviceNotFound, .disconnected, .notOpen: .interfaceDisappeared
            case .managerOpenFailed(let code), .openFailed(let code): .openFailed(code: code)
            case .writeFailed, .reportTooLarge: .communicationFailure(describe(error))
            }
        }
        if let session = error as? PulsarSession.SessionError {
            return switch session {
            case .timedOut, .notStarted: .handshakeTimedOut
            default: .communicationFailure(describe(error))
            }
        }
        return .communicationFailure(describe(error))
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func systemCode(_ error: any Error) -> Int32? {
        guard let transport = error as? HIDTransportError else { return nil }
        return switch transport {
        case .managerOpenFailed(let code), .openFailed(let code), .writeFailed(let code): code
        default: nil
        }
    }

    public func disconnect() async {
        if let session {
            try? await session.setDriverOnline(false)
            await session.stop()
        }
        session = nil
        identifier = nil
        await transport.close()
    }

    /// Ferme la session en gardant l'énumération vivante, pour préparer une reconnexion.
    ///
    /// Distinct de `disconnect()` : ici le périphérique est déjà parti, il n'y a rien à lui
    /// dire, et le flux d'évènements HID doit rester ouvert pour voir son retour.
    public func closeForRecovery() async {
        if let session { await session.stop() }
        session = nil
        identifier = nil
        await transport.close()
    }

    /// Identité de la collection actuellement ouverte.
    public func currentIdentifier() -> HIDDeviceIdentifier? { identifier }

    public func changeNotifications() async -> AsyncStream<PulsarChangeNotification> {
        guard let session else { return AsyncStream { $0.finish() } }
        return await session.changeNotifications()
    }

    public func deviceEvents() async -> AsyncStream<HIDDeviceEvent> {
        await transport.deviceEvents()
    }

    // MARK: Lecture

    /// Relit intégralement l'état du périphérique.
    public func readSnapshot() async throws -> DeviceSnapshot {
        guard let session, let identifier else { throw ControllerError.notConnected }

        try await session.waitUntilOnline()
        let identity = try await session.identify()
        guard let family = catalog.family(cid: identity.cid, mid: identity.mid) else {
            throw ControllerError.unrecognisedDevice(cid: identity.cid, mid: identity.mid)
        }

        let firmware = (try? await session.readFirmwareVersion()) ?? "—"
        let dongle = identity.connectionType.isWired ? nil : try? await session.readDongleVersion()
        let receiverReadback = identity.connectionType.isWired
            ? nil
            : await session.readReceiverSettings(dongleType: identity.dongleType)
        let battery = identity.connectionType.isWired ? nil : try? await session.readBattery()
        let signal = try? await session.readSignalStrength()
        let profile = try? await session.readActiveProfile()
        let longDistance = try? await session.readLongDistanceMode()

        var image = try await session.readFlash(FlashMap.coreRegion)
        let codec = DPICodec(family: family, catalog: catalog)
        if codec?.usesExtendedBlock == true {
            let start = FlashMap.sensor3955DPI
            image = try await session.readFlash(start..<(start + 48), into: image)
        }

        var settings = decodeSettings(
            from: image,
            family: family,
            codec: codec,
            longDistance: longDistance ?? false
        )
        settings.buttons = try await readShortcuts(for: settings.buttons, using: session)
        settings.receiver = receiverReadback?.settings
        settings.macros = try await readMacros(for: settings.buttons, using: session)

        let flashCapabilities = DeviceFlashCapabilities(
            supportsFanMode: family.supportsFanMode
                && ScalarSetting.decode(from: image, at: FlashMap.fanMode) != nil,
            supportsSensorMode: ScalarSetting.decode(from: image, at: FlashMap.sensorMode) != nil,
            supportsPerformanceLevel: ScalarSetting.decode(from: image, at: FlashMap.performance) != nil
        )

        return DeviceSnapshot(
            identity: identity,
            family: family,
            productName: identifier.productName,
            connection: HIDConnectionSummary(connectionType: identity.connectionType),
            firmwareVersion: firmware,
            dongleVersion: dongle ?? nil,
            dongleLighting: receiverReadback?.settings.rgbLighting,
            receiverCapabilities: receiverReadback?.capabilities ?? .none,
            flashCapabilities: flashCapabilities,
            battery: battery,
            signalStrength: signal ?? nil,
            activeProfile: profile ?? nil,
            settings: settings
        )
    }

    /// Relit les macros des boutons qui en portent une.
    ///
    /// Seuls ces emplacements sont lus : parcourir les huit blocs de 384 octets coûterait
    /// plus de trois cents trames pour, le plus souvent, ne trouver que du `0xFF`.
    private func readMacros(
        for buttons: [DeviceSettings.ButtonAssignment],
        using session: PulsarSession
    ) async throws -> [DeviceSettings.MacroBinding] {
        var bindings: [DeviceSettings.MacroBinding] = []
        for button in buttons where button.function == .macro {
            let slot = (button.parameter >> 8) & 0xFF
            let repeatCount = max(1, button.parameter & 0xFF)
            guard let macro = try await session.readMacro(slot: slot) else { continue }
            bindings.append(DeviceSettings.MacroBinding(
                slot: slot, macro: macro, repeatCount: repeatCount
            ))
        }
        return bindings
    }

    /// Relit les blocs de raccourcis de tous les boutons connus.
    ///
    /// Une zone absente ou mal formée reste `nil` : l'interface affiche alors un état
    /// indisponible et le validateur interdit l'écriture tant qu'une combinaison valide
    /// n'a pas été choisie.
    private func readShortcuts(
        for buttons: [DeviceSettings.ButtonAssignment],
        using session: PulsarSession
    ) async throws -> [DeviceSettings.ButtonAssignment] {
        var result = buttons
        // Lire chaque emplacement permet de disposer d'une ancienne valeur restaurable
        // même quand le bouton n'utilise pas encore la fonction clavier.
        for index in result.indices {
            result[index].shortcut = try await session.readShortcut(slot: result[index].index)
        }
        return result
    }

    public func capabilities(for snapshot: DeviceSnapshot) -> DeviceCapabilities {
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

    func decodeSettings(
        from image: FlashImage,
        family: DeviceFamily,
        codec: DPICodec?,
        longDistance: Bool
    ) -> DeviceSettings {
        var settings = DeviceSettings()

        func scalar(_ address: UInt16, default fallback: Int) -> Int {
            ScalarSetting.decode(from: image, at: address).map(Int.init) ?? fallback
        }

        if let code = ScalarSetting.decode(from: image, at: FlashMap.reportRate),
           let hertz = ReportRateCodec.hertz(from: code) {
            settings.reportRateHertz = hertz
        }
        settings.enabledStageCount = scalar(FlashMap.maxDPIStage, default: family.dpi.stages.count)
        settings.activeStage = scalar(FlashMap.currentDPI, default: family.dpi.defaultStage)
        settings.liftOffMillimetres = scalar(FlashMap.liftOffDistance, default: family.sensor.defaultLiftOff)
        settings.debounceMilliseconds = scalar(FlashMap.debounceTime, default: family.debounce.default)
        settings.motionSync = scalar(FlashMap.motionSync, default: 0) == 1
        settings.angleSnap = scalar(FlashMap.angleSnap, default: 0) == 1
        settings.rippleControl = scalar(FlashMap.rippleControl, default: 0) == 1
        settings.performanceMode = scalar(FlashMap.performanceState, default: 0) == 1
        settings.performanceLevel = scalar(FlashMap.performance, default: family.sensor.defaultPerformance)
        settings.sensorMode = scalar(FlashMap.sensorMode, default: family.sensor.defaultSensorMode)
        settings.fanMode = scalar(FlashMap.fanMode, default: 0)
        settings.sleepTimeCode = scalar(
            FlashMap.sleepTime, default: family.power.defaultSleepTimeCode
        )
        settings.powerSaveBatteryPercent = scalar(
            FlashMap.powerSaveBattery, default: family.power.defaultPowerSaveBattery
        )
        settings.longDistance = longDistance

        let rotationByte = UInt8(clamping: scalar(FlashMap.angleTune, default: 0))
        settings.rotationDegrees = Int(Int8(bitPattern: rotationByte))

        let effectCodec = DPIEffectCodec()
        let modeRaw = scalar(FlashMap.dpiEffectMode, default: 0)
        if let mode = try? effectCodec.decode(UInt8(clamping: modeRaw), for: .mode) {
            settings.dpiEffect.mode = DeviceSettings.DPIEffect.Mode(rawValue: mode) ?? .off
        }
        let brightnessRaw = scalar(
            FlashMap.dpiEffectBrightness,
            default: DPIEffectCodec.defaultBrightness
        )
        settings.dpiEffect.brightness = (try? effectCodec.decode(
            UInt8(clamping: brightnessRaw), for: .brightness
        )) ?? DPIEffectCodec.defaultBrightness
        let speedRaw = scalar(FlashMap.dpiEffectSpeed, default: DPIEffectCodec.defaultSpeed)
        settings.dpiEffect.speed = (try? effectCodec.decode(
            UInt8(clamping: speedRaw), for: .speed
        )) ?? DPIEffectCodec.defaultSpeed
        let stateRaw = scalar(FlashMap.dpiEffectState, default: 1)
        settings.dpiEffect.enabled = ((try? effectCodec.decode(
            UInt8(clamping: stateRaw), for: .state
        )) ?? 1) == 1

        if let codec {
            let width = codec.usesExtendedBlock
                ? FlashMap.extendedDPIStageStride
                : FlashMap.dpiStageStride
            var stages: [DeviceSettings.DPIStage] = []
            for (index, profile) in family.dpi.stages.enumerated() {
                let address = FlashMap.dpiValue(stage: index, extended: codec.usesExtendedBlock)
                let block = image.slice(at: address, count: width)
                let decoded: (x: Int, y: Int) = (try? codec.decodeStage(block))
                    ?? (x: profile.value, y: profile.value)
                let colourBlock = image.slice(at: FlashMap.dpiColor(stage: index), count: 4)
                stages.append(DeviceSettings.DPIStage(
                    index: index,
                    x: decoded.x,
                    y: decoded.y,
                    color: (try? DPIColorCodec().decode(colourBlock)) ?? profile.color
                ))
            }
            settings.dpiStages = stages
        }

        settings.buttons = family.buttons.map { button in
            let block = image.slice(at: FlashMap.keyFunction(button: button.index), count: 4)
            let function = PulsarKeyFunction(rawValue: block.first ?? 0)
                ?? PulsarKeyFunction(rawValue: UInt8(button.defaultType)) ?? .disabled
            let parameter: Int
            if function == .dpiLock {
                parameter = Int(block.count > 1 ? block[1] : 0) | Int(block.count > 2 ? block[2] : 0) << 8
            } else {
                parameter = Int(block.count > 1 ? block[1] : 0) << 8 | Int(block.count > 2 ? block[2] : 0)
            }
            return DeviceSettings.ButtonAssignment(
                index: button.index, function: function, parameter: parameter
            )
        }
        return settings
    }

    // MARK: Écriture

    /// Applique un plan, relit, et restaure au mieux en cas d'échec.
    ///
    /// Le déroulé est volontairement pessimiste :
    /// 1. le périphérique est verrouillé pour la durée du lot ;
    /// 2. chaque opération est écrite puis relue individuellement ;
    /// 3. la première divergence interrompt le lot ;
    /// 4. les opérations déjà appliquées sont défaites dans l'ordre inverse ;
    /// 5. toute restauration qui échoue est nommée dans le résultat, parce que l'état
    ///    matériel correspondant n'est alors plus connu.
    public func apply(
        _ plan: WritePlan,
        progress: @escaping @Sendable (WriteProgress) async -> Void = { _ in }
    ) async throws -> WriteResult {
        guard let session else { throw ControllerError.notConnected }
        guard !plan.isEmpty else { return WriteResult(outcome: .succeeded, applied: []) }

        try? await session.hold(true)
        defer { Task { try? await session.hold(false) } }

        var applied: [WriteOperation] = []
        for (index, operation) in plan.operations.enumerated() {
            await progress(WriteProgress(
                completed: applied.count,
                total: plan.count,
                currentOperation: operation.label
            ))
            do {
                try await perform(operation, using: session)
                applied.append(operation)
                await progress(WriteProgress(
                    completed: applied.count,
                    total: plan.count,
                    currentOperation: index + 1 < plan.count
                        ? plan.operations[index + 1].label
                        : nil
                ))
            } catch {
                // La commande courante peut avoir été acceptée puis avoir divergé à la
                // relecture. On tente donc aussi son rollback avant de défaire le lot
                // précédent ; l'absence de rollback est déclarée incertaine.
                let currentUncertain = await rollback([operation], using: session)
                let previousUncertain = await rollback(applied, using: session)
                let uncertain = currentUncertain + previousUncertain
                let message = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                let failure = L10n.format("%@ : %@", operation.label, message)
                return WriteResult(
                    outcome: uncertain.isEmpty
                        ? .failedAndRestored(failure: failure)
                        : .failedAndUncertain(failure: failure, uncertain: uncertain),
                    applied: applied.map(\.label)
                )
            }
        }
        return WriteResult(outcome: .succeeded, applied: applied.map(\.label))
    }

    private func perform(_ operation: WriteOperation, using session: PulsarSession) async throws {
        switch operation.payload {
        case .scalar(let value):
            // `writeScalar` relit et compare : la vérification est incluse.
            try await session.writeScalar(value, at: operation.address)

        case .block(let bytes):
            try await session.writeFlash(bytes, at: operation.address)
            let image = try await session.readFlash(
                operation.address..<(operation.address + UInt16(bytes.count))
            )
            guard image.slice(at: operation.address, count: bytes.count) == bytes else {
                throw PulsarSession.SessionError.readbackMismatch(address: operation.address)
            }

        case .command(let command, let payload):
            try await session.request(PulsarFrame(command: command, payload: payload))
            try await verifyCommand(command, payload: payload, using: session)
        }
    }

    /// Les commandes hors flash n'ont pas de bloc checksum à relire : leur getter
    /// correspondant est donc obligatoire avant de considérer l'opération appliquée.
    private func verifyCommand(
        _ command: PulsarCommand,
        payload: [UInt8],
        using session: PulsarSession
    ) async throws {
        switch command {
        case .set4KDongleRGB:
            guard payload.count == 10,
                  let actual = try await session.readDongleLighting(),
                  actual == DongleLightingState(mode: payload[0], colors: Array(payload.dropFirst()))
            else { throw PulsarSession.SessionError.commandReadbackMismatch(command) }

        case .setPulsarDongleLightParam:
            guard payload.count == 7,
                  let actual = try await session.readReceiverEffect(),
                  actual == ReceiverLightEffect(
                    mode: Int(payload[0]),
                    color: CatalogColor(
                        red: Int(payload[1]), green: Int(payload[2]), blue: Int(payload[3])
                    ),
                    speed: Int(payload[4]),
                    brightness: Int(payload[5]),
                    duration: Int(payload[6])
                  )
            else { throw PulsarSession.SessionError.commandReadbackMismatch(command) }

        case .setPulsarDongleDPILightParam:
            guard let expected = payload.first,
                  let actual = try await session.readReceiverDPILight(),
                  actual == (expected == 1)
            else { throw PulsarSession.SessionError.commandReadbackMismatch(command) }

        case .setPulsarDongleKeyFunction:
            guard let expected = payload.first,
                  let actual = try await session.readReceiverButtonMode(kind: .keyFunction),
                  actual == Int(expected)
            else { throw PulsarSession.SessionError.commandReadbackMismatch(command) }

        case .setPulsarDongleOButtonCurrentMode:
            guard let expected = payload.first,
                  let actual = try await session.readReceiverButtonMode(kind: .oButton),
                  actual == Int(expected)
            else { throw PulsarSession.SessionError.commandReadbackMismatch(command) }

        case .setPulsarDongleOButtonFunction:
            guard payload.count == 8,
                  let actual = try await session.readReceiverButtonFunction(index: Int(payload[0])),
                  actual == ReceiverButtonFunction(
                    index: Int(payload[0]),
                    mode: Int(payload[1]),
                    color: CatalogColor(
                        red: Int(payload[2]), green: Int(payload[3]), blue: Int(payload[4])
                    ),
                    speed: Int(payload[5]),
                    brightness: Int(payload[6]),
                    duration: Int(payload[7])
                  )
            else { throw PulsarSession.SessionError.commandReadbackMismatch(command) }

        case .setLongRangeMode:
            guard let expected = payload.first,
                  let actual = try await session.readLongDistanceMode(),
                  actual == (expected == 1)
            else { throw PulsarSession.SessionError.commandReadbackMismatch(command) }

        default:
            throw PulsarSession.SessionError.malformedResponse(command)
        }
    }

    /// Défait les opérations déjà appliquées. Renvoie celles dont la restauration a échoué.
    private func rollback(
        _ applied: [WriteOperation],
        using session: PulsarSession
    ) async -> [String] {
        var uncertain: [String] = []
        for operation in applied.reversed() {
            guard let restore = operation.rollback else {
                uncertain.append(operation.label)
                continue
            }
            var reverted = operation
            reverted.payload = restore
            do {
                try await perform(reverted, using: session)
            } catch {
                uncertain.append(operation.label)
            }
        }
        return uncertain
    }

    // MARK: Autres actions

    public func setActiveProfile(_ profile: Int) async throws {
        guard let session else { throw ControllerError.notConnected }
        guard (0..<Self.profileCount).contains(profile) else {
            throw ControllerError.profileSelectionReadbackMismatch(expected: profile, actual: nil)
        }
        try await session.setActiveProfile(profile)
        let confirmed = try await session.readActiveProfile()
        guard confirmed == profile else {
            throw ControllerError.profileSelectionReadbackMismatch(
                expected: profile,
                actual: confirmed
            )
        }
    }

    /// Sélectionne un emplacement, confirme le choix par une lecture indépendante, puis
    /// relit son instantané complet. La lecture est nécessaire même si la commande a été
    /// acquittée : l'interface ne doit jamais afficher un profil supposé.
    public func readProfile(_ profile: Int) async throws -> DeviceSnapshot {
        try await setActiveProfile(profile)
        return try await readSnapshot()
    }

    /// Bascule l'éclairage du récepteur en conservant les couleurs actuellement stockées.
    public func setDongleLightEnabled(_ enabled: Bool) async throws -> DeviceSnapshot {
        guard let session else { throw ControllerError.notConnected }
        guard let current = try await session.readDongleLighting() else {
            throw PulsarSession.SessionError.unsupported(.get4KDongleRGBValue)
        }

        let target = current.setting(enabled: enabled)
        try await session.setDongleLighting(target)

        guard let confirmed = try await session.readDongleLighting(), confirmed == target else {
            // Même cette action ponctuelle conserve le contrat de restauration si le
            // setter a répondu mais que sa relecture diverge.
            try? await session.setDongleLighting(current)
            guard let restored = try? await session.readDongleLighting(), restored == current else {
                throw PulsarSession.SessionError.commandReadbackMismatch(.set4KDongleRGB)
            }
            throw PulsarSession.SessionError.commandReadbackMismatch(.set4KDongleRGB)
        }
        return try await readSnapshot()
    }

    /// Réinitialisation complète. Le périphérique recharge ses réglages d'usine.
    public func factoryReset() async throws -> DeviceSnapshot {
        guard let session else { throw ControllerError.notConnected }
        try await session.clearSettings()
        return try await readSnapshot()
    }

    public func startPairing() async throws {
        guard let session else { throw ControllerError.notConnected }
        try await session.enterPairing()
    }

    public func pairingState() async throws -> (state: PulsarPairState, secondsRemaining: Int) {
        guard let session else { throw ControllerError.notConnected }
        return try await session.pairState()
    }

    public func diagnosticLog() async -> [PulsarSession.LoggedFrame] {
        guard let session else { return [] }
        return await session.diagnosticLog()
    }
}

extension DeviceController.ControllerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noConfigurationInterface:
            L10n.string("Aucune interface de configuration Pulsar n'est présente.")
        case .unrecognisedDevice(let cid, let mid):
            L10n.format("Model CID %d / MID %d is not in the bundled catalog.", cid, mid)
        case .deviceOffline:
            L10n.string("Le récepteur répond, mais la souris ne se signale pas.")
        case .notConnected:
            L10n.string("Aucun périphérique connecté.")
        case .permissionDenied:
            L10n.string("macOS refuse l'accès aux rapports HID. Autorisez Bibimbap dans Réglages Système › Confidentialité et sécurité › Surveillance de l'entrée.")
        case .interfaceDisappeared:
            L10n.string("L'interface a disparu pendant la connexion.")
        case .handshakeTimedOut:
            L10n.string("Le périphérique n'a pas répondu au dialogue d'identification.")
        case .openFailed(let code):
            L10n.format("Device opening denied (code %d).", code)
        case .profileSelectionReadbackMismatch(let expected, let actual):
            L10n.format(
                "Le profil demandé (%d) n'a pas été confirmé par la relecture (reçu %@).",
                expected + 1,
                actual.map { String($0 + 1) } ?? "—"
            )
        case .communicationFailure(let reason):
            reason
        }
    }
}
