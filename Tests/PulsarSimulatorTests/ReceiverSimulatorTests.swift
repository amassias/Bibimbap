import Testing
@testable import PulsarCatalog
@testable import PulsarProtocol
@testable import PulsarSimulator

private func receiverSession() async throws -> (SimulatedHIDTransport, PulsarSession) {
    let transport = SimulatedHIDTransport()
    let identifier = try #require(try await transport.discover().first)
    try await transport.open(identifier)
    let session = PulsarSession(transport: transport)
    await session.start()
    return (transport, session)
}

@Suite("Simulateur — réglages avancés du récepteur")
struct ReceiverSimulatorTests {
    @Test("Le sondage relit les effets, la LED DPI et les quatre boutons")
    func probesAdvancedReceiver() async throws {
        let (_, session) = try await receiverSession()
        let readback = await session.readReceiverSettings(dongleType: 1)

        #expect(readback.capabilities.supportsRGBLighting)
        #expect(readback.capabilities.supportsEffect)
        #expect(readback.capabilities.supportsDPILighting)
        #expect(readback.capabilities.supportsButtonMode)
        #expect(readback.capabilities.buttonFunctionSlots == [0, 1, 2, 3])
        #expect(readback.settings.effect?.mode == 3)
        #expect(readback.settings.dpiLightEnabled == true)
        #expect(readback.settings.buttonFunctions.count == 4)
        await session.stop()
    }

    @Test("Chaque écriture récepteur est confirmée par son getter")
    func writesAndReadsBackAdvancedSettings() async throws {
        let (_, session) = try await receiverSession()
        let effect = ReceiverLightEffect(
            mode: 2,
            color: CatalogColor(red: 11, green: 22, blue: 33),
            speed: 7,
            brightness: 4,
            duration: 19
        )
        let function = ReceiverButtonFunction(
            index: 1,
            mode: 4,
            color: CatalogColor(red: 9, green: 8, blue: 7),
            speed: 3,
            brightness: 6,
            duration: 5
        )

        try await session.setReceiverEffect(effect)
        #expect(try await session.readReceiverEffect() == effect)
        try await session.setReceiverDPILight(enabled: false)
        #expect(try await session.readReceiverDPILight() == false)
        try await session.setReceiverButtonMode(5, kind: .oButton)
        #expect(try await session.readReceiverButtonMode(kind: .oButton) == 5)
        try await session.setReceiverButtonFunction(function)
        #expect(try await session.readReceiverButtonFunction(index: 1) == function)
        await session.stop()
    }

    @Test("Une commande récepteur refusée disparaît du sondage")
    func unsupportedReceiverCommandIsHidden() async throws {
        var faults = SimulatedHIDTransport.Faults()
        faults.unsupportedCommands = [
            .getPulsarDongleLightParam,
            .getPulsarDongleDPILightParam,
            .getPulsarDongleOButtonCurrentMode,
            .getPulsarDongleOButtonFunction,
        ]
        let transport = SimulatedHIDTransport(faults: faults)
        let identifier = try #require(try await transport.discover().first)
        try await transport.open(identifier)
        let session = PulsarSession(transport: transport)
        await session.start()

        let readback = await session.readReceiverSettings(dongleType: 1)
        #expect(readback.capabilities.supportsRGBLighting)
        #expect(!readback.capabilities.supportsEffect)
        #expect(!readback.capabilities.supportsDPILighting)
        #expect(!readback.capabilities.supportsButtonMode)
        #expect(readback.settings.buttonFunctions.isEmpty)
        await session.stop()
    }
}
