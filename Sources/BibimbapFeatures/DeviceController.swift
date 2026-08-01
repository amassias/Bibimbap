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
    private let transport: any HIDTransport
    private let catalog: DeviceCatalog
    private var session: PulsarSession?
    private var identifier: HIDDeviceIdentifier?

    public init(transport: any HIDTransport, catalog: DeviceCatalog = .embedded) {
        self.transport = transport
        self.catalog = catalog
    }

    public enum ControllerError: Error, Equatable, Sendable {
        case noConfigurationInterface
        case unrecognisedDevice(cid: Int, mid: Int)
        case deviceOffline
        case notConnected
    }

    // MARK: Connexion

    /// Collections susceptibles de porter une souris Pulsar configurable.
    public func availableDevices() async throws -> [HIDDeviceIdentifier] {
        try await transport.discover().filter {
            $0.matchesConfigurationInterface(frameLength: PulsarFrame.length)
        }
    }

    public func connect(to identifier: HIDDeviceIdentifier? = nil) async throws -> DeviceSnapshot {
        let target: HIDDeviceIdentifier
        if let identifier {
            target = identifier
        } else if let first = try await availableDevices().first {
            target = first
        } else {
            throw ControllerError.noConfigurationInterface
        }

        try await transport.open(target)
        let session = PulsarSession(transport: transport)
        await session.start()
        self.session = session
        self.identifier = target

        let identity = try await session.identify()
        guard catalog.family(cid: identity.cid, mid: identity.mid) != nil else {
            throw ControllerError.unrecognisedDevice(cid: identity.cid, mid: identity.mid)
        }
        // Derrière un dongle, le récepteur répond au handshake avant que la souris ne
        // soit jointe. Lire la flash à ce moment-là expire sans explication utile.
        guard try await session.waitUntilOnline() else {
            throw ControllerError.deviceOffline
        }
        // Signale au périphérique qu'un logiciel prend la main.
        try? await session.setDriverOnline(true)
        return try await readSnapshot()
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
        let dongleLighting = identity.connectionType.isWired
            ? nil
            : try? await session.readDongleLighting()
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
        settings.macros = try await readMacros(for: settings.buttons, using: session)

        return DeviceSnapshot(
            identity: identity,
            family: family,
            productName: identifier.productName,
            connection: HIDConnectionSummary(connectionType: identity.connectionType),
            firmwareVersion: firmware,
            dongleVersion: dongle ?? nil,
            dongleLighting: dongleLighting ?? nil,
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

    public func capabilities(for snapshot: DeviceSnapshot) -> DeviceCapabilities {
        DeviceCapabilities(
            family: snapshot.family,
            catalog: catalog,
            connection: snapshot.identity.connectionType,
            supportsProfiles: snapshot.activeProfile != nil,
            supportsLongDistance: snapshot.family.power.supportsLongDistance,
            supportsSignalStrength: snapshot.signalStrength != nil
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
        settings.sleepTimeCode = scalar(
            FlashMap.sleepTime, default: family.power.defaultSleepTimeCode
        )
        settings.powerSaveBatteryPercent = scalar(
            FlashMap.powerSaveBattery, default: family.power.defaultPowerSaveBattery
        )
        settings.longDistance = longDistance

        let rotationByte = UInt8(clamping: scalar(FlashMap.angleTune, default: 0))
        settings.rotationDegrees = Int(Int8(bitPattern: rotationByte))

        settings.dpiEffect.mode = DeviceSettings.DPIEffect.Mode(
            rawValue: scalar(FlashMap.dpiEffectMode, default: 0)
        ) ?? .off
        settings.dpiEffect.brightness = scalar(FlashMap.dpiEffectBrightness, default: 3)
        settings.dpiEffect.speed = scalar(FlashMap.dpiEffectSpeed, default: 5)
        settings.dpiEffect.enabled = scalar(FlashMap.dpiEffectState, default: 1) == 1

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
                let colour = image.slice(at: FlashMap.dpiColor(stage: index), count: 3)
                stages.append(DeviceSettings.DPIStage(
                    index: index,
                    x: decoded.x,
                    y: decoded.y,
                    color: colour.count == 3
                        ? CatalogColor(red: Int(colour[0]), green: Int(colour[1]), blue: Int(colour[2]))
                        : profile.color
                ))
            }
            settings.dpiStages = stages
        }

        // Une entrée par bouton déclaré, dans l'ordre officiel, et rien d'autre : aucun
        // emplacement n'est ajouté pour combler un index firmware manquant.
        settings.buttons = family.orderedButtons.map { button in
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
    public func apply(_ plan: WritePlan) async throws -> WriteResult {
        guard let session else { throw ControllerError.notConnected }
        guard !plan.isEmpty else { return WriteResult(outcome: .succeeded, applied: []) }

        try? await session.hold(true)
        defer { Task { try? await session.hold(false) } }

        var applied: [WriteOperation] = []
        for operation in plan.operations {
            do {
                try await perform(operation, using: session)
                applied.append(operation)
            } catch {
                let uncertain = await rollback(applied, using: session)
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
        try await session.setActiveProfile(profile)
    }

    /// Bascule l'éclairage du récepteur en conservant les couleurs actuellement stockées.
    public func setDongleLightEnabled(_ enabled: Bool) async throws -> DeviceSnapshot {
        guard let session else { throw ControllerError.notConnected }
        guard let current = try await session.readDongleLighting() else {
            throw PulsarSession.SessionError.unsupported(.get4KDongleRGBValue)
        }

        let target = current.setting(enabled: enabled)
        try await session.setDongleLighting(target)

        guard let confirmed = try await session.readDongleLighting(),
              confirmed.isEnabled == enabled else {
            throw PulsarSession.SessionError.unsupported(.set4KDongleRGB)
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
