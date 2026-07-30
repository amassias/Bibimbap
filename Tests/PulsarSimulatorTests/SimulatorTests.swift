import Foundation
import Testing
@testable import PulsarCatalog
@testable import PulsarHID
@testable import PulsarProtocol
@testable import PulsarSimulator

/// Ouvre une session sur un transport simulé.
private func makeSession(
    faults: SimulatedHIDTransport.Faults = .init(),
    connectionType: PulsarConnectionType = .wireless4k,
    timing: PulsarSession.Timing = {
        var timing = PulsarSession.Timing()
        timing.responseTimeout = .milliseconds(60)
        timing.attempts = 3
        timing.retryDelay = .milliseconds(1)
        return timing
    }()
) async throws -> (SimulatedHIDTransport, PulsarSession) {
    let transport = SimulatedHIDTransport(connectionType: connectionType, faults: faults)
    let identifier = try #require(try await transport.discover().first)
    try await transport.open(identifier)
    let session = PulsarSession(transport: transport, timing: timing)
    await session.start()
    return (transport, session)
}

@Suite("Simulateur — chemin nominal")
struct SimulatorHappyPathTests {
    @Test("Le handshake renvoie le modèle simulé")
    func handshake() async throws {
        let (_, session) = try await makeSession()
        let identity = try await session.identify()
        #expect(identity.cid == 87)
        #expect(identity.mid == 10)
        #expect(identity.connectionType == .wireless4k)
        await session.stop()
    }

    @Test("Un handshake sans défi est rejeté, comme sur le matériel")
    func handshakeRequiresChallenge() async throws {
        let (_, session) = try await makeSession()
        // Le périphérique acquitte, mais sans données : pour une lecture c'est un refus.
        let acknowledged = try await session.request(PulsarFrame(command: .encryptionData))
        #expect(acknowledged.isUnsupported)
        await #expect(throws: PulsarSession.SessionError.unsupported(.encryptionData)) {
            try await session.requestData(PulsarFrame(command: .encryptionData))
        }
        await session.stop()
    }

    @Test("Un statut 1 sur une commande d'action est un acquittement, pas un refus")
    func actionCommandsTolerateStatusOne() async throws {
        // La prise de verrou répond `status = 1` sur certains modèles : la traiter comme
        // « non supporté » bloquerait toute écriture derrière un dongle.
        let (_, session) = try await makeSession()
        let response = try await session.request(PulsarFrame(command: .deviceOnline, payload: [1]))
        #expect(response.command == .deviceOnline)
        await session.stop()
    }

    @Test("La flash usine se relit aux valeurs du catalogue")
    func factoryDefaults() async throws {
        let (_, session) = try await makeSession()
        let image = try await session.readFlash(FlashMap.coreRegion)
        let family = try #require(DeviceCatalog.embedded.family(cid: 87, mid: 10))

        #expect(ScalarSetting.decode(from: image, at: FlashMap.maxDPIStage)
                == UInt8(family.dpi.stages.count))
        #expect(ScalarSetting.decode(from: image, at: FlashMap.debounceTime)
                == UInt8(family.debounce.default))

        let codec = try #require(DPICodec(family: family, catalog: .embedded))
        for (index, stage) in family.dpi.stages.enumerated() {
            let block = image.slice(at: FlashMap.dpiValue(stage: index, extended: false), count: 4)
            #expect(try codec.decodeStage(block).x == stage.value)
        }
        await session.stop()
    }

    @Test("Une écriture scalaire est relue avec succès")
    func writeAndReadBack() async throws {
        let (transport, session) = try await makeSession()
        try await session.writeScalar(9, at: FlashMap.debounceTime)
        let image = await transport.flashImage()
        #expect(ScalarSetting.decode(from: image, at: FlashMap.debounceTime) == 9)
        await session.stop()
    }

    @Test("Une écriture de plus de dix octets est découpée en plusieurs trames")
    func chunkedWrite() async throws {
        let (transport, session) = try await makeSession()
        let payload = (0..<25).map { UInt8($0) }
        try await session.writeFlash(payload, at: FlashMap.shortcutKey)
        let image = await transport.flashImage()
        #expect(image.slice(at: FlashMap.shortcutKey, count: 25) == payload)
        await session.stop()
    }

    @Test("Le mode longue portée est absent en filaire")
    func capabilityProbing() async throws {
        let (_, wired) = try await makeSession(connectionType: .wired1k)
        #expect(try await wired.readSignalStrength() == nil)
        await wired.stop()
    }

    @Test("L'éclairage du dongle conserve ses couleurs lors d'une extinction")
    func dongleLighting() async throws {
        let (_, session) = try await makeSession()
        let initial = try #require(try await session.readDongleLighting())
        let disabled = initial.setting(enabled: false)
        try await session.setDongleLighting(disabled)
        let readBack = try #require(try await session.readDongleLighting())

        #expect(!readBack.isEnabled)
        #expect(readBack.colors == initial.colors)
        await session.stop()
    }
}

@Suite("Simulateur — chemins d'erreur")
struct SimulatorFaultTests {
    @Test("Une commande muette finit en timeout après les tentatives prévues")
    func timeout() async throws {
        var faults = SimulatedHIDTransport.Faults()
        faults.silentCommands = [.batteryLevel]
        let (_, session) = try await makeSession(faults: faults)

        await #expect(throws: PulsarSession.SessionError.timedOut(.batteryLevel)) {
            _ = try await session.readBattery()
        }
        await session.stop()
    }

    @Test("Une réponse au checksum corrompu est ignorée puis réémise avec succès")
    func retriesAfterCorruption() async throws {
        var faults = SimulatedHIDTransport.Faults()
        faults.corruptEveryNthResponse = 2
        let (_, session) = try await makeSession(faults: faults)

        // La première réponse passe, la deuxième est corrompue, la réémission aboutit.
        _ = try await session.identify()
        let battery = try await session.readBattery()
        #expect(battery.percentage == 78)
        await session.stop()
    }

    @Test("Une commande non supportée est signalée sans être confondue avec un échec")
    func unsupportedCommand() async throws {
        var faults = SimulatedHIDTransport.Faults()
        faults.unsupportedCommands = [.getCurrentConfig]
        let (_, session) = try await makeSession(faults: faults)

        #expect(try await session.readActiveProfile() == nil)
        await session.stop()
    }

    @Test("Une écriture avalée sans effet est détectée à la relecture")
    func detectsSilentlyDroppedWrite() async throws {
        var faults = SimulatedHIDTransport.Faults()
        faults.dropWrites = true
        let (_, session) = try await makeSession(faults: faults)

        await #expect(throws: PulsarSession.SessionError.readbackMismatch(address: FlashMap.debounceTime)) {
            try await session.writeScalar(11, at: FlashMap.debounceTime)
        }
        await session.stop()
    }

    @Test("Une déconnexion en pleine écriture remonte comme telle")
    func disconnectionDuringWrite() async throws {
        var faults = SimulatedHIDTransport.Faults()
        faults.disconnectAfterFrames = 2
        let (_, session) = try await makeSession(faults: faults)

        await #expect(throws: (any Error).self) {
            _ = try await session.identify()
            _ = try await session.readBattery()
            _ = try await session.readFirmwareVersion()
        }
        await session.stop()
    }

    @Test("Les commandes de mise à jour firmware sont refusées en phase 1")
    func firmwareIsBlocked() async throws {
        let (_, session) = try await makeSession()
        await #expect(throws: PulsarSession.SessionError.firmwareOperationBlocked(.enterUsbUpdateMode)) {
            try await session.request(PulsarFrame(command: .enterUsbUpdateMode))
        }
        await #expect(throws: PulsarSession.SessionError.firmwareOperationBlocked(.enterMTKMode)) {
            try await session.request(PulsarFrame(command: .enterMTKMode))
        }
        await session.stop()
    }

    @Test("Une notification poussée par la souris est remontée à l'application")
    func changeNotification() async throws {
        let (transport, session) = try await makeSession()
        let stream = await session.changeNotifications()

        Task {
            try? await Task.sleep(for: .milliseconds(20))
            await transport.pushChangeNotification(primary: 0b0000_0010, secondary: 0b0000_0001)
        }

        var iterator = stream.makeAsyncIterator()
        let notification = try #require(await iterator.next())
        #expect(notification.generalSettings)
        #expect(notification.dpi)
        await session.stop()
    }

    @Test("La réinitialisation ramène les réglages d'usine")
    func factoryReset() async throws {
        let (transport, session) = try await makeSession()
        try await session.writeScalar(14, at: FlashMap.debounceTime)
        try await session.clearSettings()

        let image = await transport.flashImage()
        let family = try #require(DeviceCatalog.embedded.family(cid: 87, mid: 10))
        #expect(ScalarSetting.decode(from: image, at: FlashMap.debounceTime)
                == UInt8(family.debounce.default))
        await session.stop()
    }
}
