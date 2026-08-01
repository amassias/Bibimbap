import Foundation
import Testing
@testable import BibimbapFeatures
@testable import PulsarHID
@testable import PulsarProtocol
@testable import PulsarSimulator

/// Les chemins d'échec de la connexion, rejoués sur le transport simulé.
///
/// Ce sont exactement les situations qu'on ne peut pas provoquer à volonté sur du vrai
/// matériel : permission refusée, ouverture refusée, interface qui disparaît entre
/// l'énumération et l'ouverture, souris endormie derrière son récepteur.
@Suite("Simulateur — chemins d'échec de connexion")
struct SimulatorFaultTests {
    private func make(_ configure: (inout SimulatedHIDTransport.Faults) -> Void = { _ in })
        -> (SimulatedHIDTransport, DeviceController) {
        var faults = SimulatedHIDTransport.Faults()
        configure(&faults)
        let transport = SimulatedHIDTransport(faults: faults)
        return (transport, DeviceController(transport: transport))
    }

    @Test("Une permission refusée est nommée telle quelle, sans réessai")
    func permissionDeniedIsReported() async {
        let (transport, controller) = make { $0.discoveryFailure = .permissionDenied }

        await #expect(throws: DeviceController.ControllerError.permissionDenied) {
            _ = try await controller.connect()
        }
        #expect(await transport.isCurrentlyOpen() == false)
        #expect(await transport.totalOpenCount() == 0)
    }

    @Test("Un échec d'ouverture conserve le code système")
    func openFailureKeepsCode() async {
        let (transport, controller) = make { $0.openFailure = .openFailed(-536_870_174) }

        await #expect(throws: DeviceController.ControllerError.openFailed(code: -536_870_174)) {
            _ = try await controller.connect()
        }
        #expect(await transport.isCurrentlyOpen() == false)

        let log = await controller.connectionLog()
        #expect(log.contains { $0.phase == .open && $0.systemCode == -536_870_174 })
    }

    @Test("Une interface qui disparaît est ré-énumérée une fois")
    func transientDisappearanceIsRetriedOnce() async throws {
        let (transport, controller) = make { $0.transientOpenFailures = 1 }

        let snapshot = try await controller.connect()
        #expect(snapshot.identity.cid == 87)
        #expect(await transport.openSessionCount() == 1)
        await controller.disconnect()
    }

    @Test("Une interface durablement absente n'est pas réessayée indéfiniment")
    func repeatedDisappearanceGivesUp() async {
        // Deux échecs : la ré-énumération unique ne suffit pas, et c'est voulu — au-delà
        // c'est une panne, pas un rebranchement.
        let (transport, controller) = make { $0.transientOpenFailures = 2 }

        await #expect(throws: DeviceController.ControllerError.interfaceDisappeared) {
            _ = try await controller.connect()
        }
        #expect(await transport.isCurrentlyOpen() == false)
    }

    @Test("Un handshake sans réponse expire au lieu de rester suspendu")
    func handshakeTimesOut() async {
        let (transport, controller) = make { $0.silentCommands = [.encryptionData] }

        await #expect(throws: DeviceController.ControllerError.handshakeTimedOut) {
            _ = try await controller.connect()
        }
        // Le point le plus important : la collection ne reste pas ouverte derrière l'échec.
        #expect(await transport.isCurrentlyOpen() == false)
        #expect(await transport.openSessionCount() == 0)
    }

    @Test("Une souris endormie derrière son récepteur est distinguée d'une panne")
    func offlineMouseIsDistinguished() async {
        let (transport, controller) = make { $0.staysOffline = true }

        await #expect(throws: DeviceController.ControllerError.deviceOffline) {
            _ = try await controller.connect()
        }
        #expect(await transport.isCurrentlyOpen() == false)

        let log = await controller.connectionLog()
        #expect(log.contains { $0.phase == .online })
    }

    @Test("Le récepteur qui cherche encore la souris fait patienter, pas échouer")
    func onlineAfterSeveralPolls() async throws {
        let (_, controller) = make { $0.pollsBeforeOnline = 4 }

        let snapshot = try await controller.connect()
        #expect(snapshot.identity.cid == 87)
        await controller.disconnect()
    }

    @Test("Aucune session ne survit à un échec, quelle qu'en soit la cause")
    func noSessionLeaksAfterAnyFailure() async {
        let failures: [(String, (inout SimulatedHIDTransport.Faults) -> Void)] = [
            ("permission", { $0.discoveryFailure = .permissionDenied }),
            ("ouverture", { $0.openFailure = .openFailed(-1) }),
            ("handshake", { $0.silentCommands = [.encryptionData] }),
            ("hors ligne", { $0.staysOffline = true }),
            ("interface absente", { $0.transientOpenFailures = 3 }),
        ]

        for (name, configure) in failures {
            let (transport, controller) = make(configure)
            _ = try? await controller.connect()
            #expect(await transport.openSessionCount() == 0, "session laissée ouverte après « \(name) »")
            #expect(await transport.isCurrentlyOpen() == false, "collection ouverte après « \(name) »")
        }
    }

    @Test("Le journal de connexion précède les trames pour un échec précoce")
    func connectionLogCoversPreSessionFailures() async {
        let (_, controller) = make { $0.discoveryFailure = .permissionDenied }
        _ = try? await controller.connect()

        let log = await controller.connectionLog()
        // Aucune trame n'a pu être échangée : sans ce journal, le rapport serait vide.
        #expect(await controller.diagnosticLog().isEmpty)
        #expect(!log.isEmpty)
        #expect(log.contains { $0.phase == .permission })
        #expect(log.last?.line.isEmpty == false)
    }

    @Test("Le débranchement simulé retire le candidat et referme la session")
    func detachClosesEverything() async throws {
        let (transport, controller) = make()
        _ = try await controller.connect()
        #expect(await transport.openSessionCount() == 1)

        await transport.detachDevice()
        #expect(await transport.isCurrentlyOpen() == false)
        #expect(try await controller.availableDevices().isEmpty)

        await transport.attachDevice()
        #expect(try await controller.availableDevices().count == 1)
    }

    @Test("Les candidats supplémentaires apparaissent dans l'énumération")
    func extraCandidatesAreEnumerated() async throws {
        let second = HIDDeviceIdentifier(
            vendorID: 0x3710, productID: 0x3414, locationID: 0x0230_0000,
            usagePage: 0xFF05, usage: 1,
            productName: "Pulsar X2V2", manufacturer: "Pulsar",
            transport: .usb, maxInputReportSize: 17, maxOutputReportSize: 17
        )
        let (_, controller) = make { $0.extraCandidates = [second] }

        let candidates = try await controller.availableDevices()
        #expect(candidates.count == 2)
        #expect(Set(candidates.map(\.stableKey)).count == 2)
    }
}
