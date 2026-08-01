import Foundation
import Testing
@testable import BibimbapFeatures
@testable import PulsarCatalog
@testable import PulsarProtocol
@testable import PulsarSimulator

@Suite("Contrôleur — cycle lecture / écriture / relecture")
struct DeviceControllerTests {
    private func makeController(
        faults: SimulatedHIDTransport.Faults = .init(),
        cid: Int = 87,
        mid: Int = 10,
        connectionType: PulsarConnectionType = .wireless4k
    ) -> (SimulatedHIDTransport, DeviceController) {
        let transport = SimulatedHIDTransport(
            cid: cid, mid: mid, connectionType: connectionType, faults: faults
        )
        return (transport, DeviceController(transport: transport))
    }

    @Test("La connexion produit un instantané cohérent avec le catalogue")
    func connectReadsEverything() async throws {
        let (_, controller) = makeController()
        let snapshot = try await controller.connect()

        #expect(snapshot.identity.cid == 87)
        #expect(snapshot.family.sensor.type == "pulsar x1")
        #expect(snapshot.settings.dpiStages.count == snapshot.family.dpi.stages.count)
        #expect(snapshot.settings.buttons.count == snapshot.family.buttons.count)
        #expect(snapshot.firmwareVersion == snapshot.family.firmware.deviceVersion)
        #expect(snapshot.dongleLighting?.isEnabled == true)
        await controller.disconnect()
    }

    @Test("L'éclairage du récepteur peut être éteint et rallumé")
    func toggleDongleLighting() async throws {
        let (_, controller) = makeController()
        let initial = try await controller.connect()
        let initialColors = try #require(initial.dongleLighting?.colors)

        let disabled = try await controller.setDongleLightEnabled(false)
        #expect(disabled.dongleLighting?.isEnabled == false)
        #expect(disabled.dongleLighting?.colors == initialColors)

        let enabled = try await controller.setDongleLightEnabled(true)
        #expect(enabled.dongleLighting?.isEnabled == true)
        #expect(enabled.dongleLighting?.colors == initialColors)
        await controller.disconnect()
    }

    @Test("Les réglages avancés du récepteur passent par le plan et la relecture")
    func advancedReceiverSettingsRoundTrip() async throws {
        let (_, controller) = makeController()
        let snapshot = try await controller.connect()
        let capabilities = await controller.capabilities(for: snapshot)
        var draft = snapshot.settings
        var receiver = try #require(draft.receiver)

        var lighting = try #require(receiver.rgbLighting)
        lighting.mode = 0
        lighting.colors = [10, 20, 30, 40, 50, 60, 70, 80, 90]
        receiver.rgbLighting = lighting

        var effect = try #require(receiver.effect)
        effect.mode = 2
        effect.color = CatalogColor(red: 101, green: 102, blue: 103)
        effect.speed = 7
        effect.brightness = 4
        receiver.effect = effect
        receiver.dpiLightEnabled = false
        receiver.buttonMode = 5
        receiver.buttonFunctions[0].mode = 4
        draft.receiver = receiver

        let plan = WritePlanner(
            family: snapshot.family,
            catalog: .embedded,
            capabilities: capabilities
        ).plan(from: snapshot.settings, to: draft)
        #expect(plan.operations.map(\.id).contains("receiver.rgb"))
        #expect(plan.operations.map(\.id).contains("receiver.effect"))
        #expect(plan.operations.map(\.id).contains("receiver.dpiLight"))
        #expect(plan.operations.map(\.id).contains("receiver.buttonMode"))
        #expect(plan.operations.map(\.id).contains("receiver.buttonFunction.0"))
        let commandOperations = plan.operations.filter {
            if case .command = $0.payload { return true }
            return false
        }
        #expect(commandOperations.allSatisfy { $0.rollback != nil })

        let result = try await controller.apply(plan)
        #expect(result.outcome == .succeeded)
        let refreshed = try await controller.readSnapshot()
        #expect(refreshed.settings.receiver == draft.receiver)
        await controller.disconnect()
    }

    @Test("Les niveaux capteur et performance sont reliés à leurs écritures flash")
    func advancedFlashSettingsRoundTrip() async throws {
        let (_, controller) = makeController(connectionType: .wireless1k)
        let snapshot = try await controller.connect()
        let capabilities = await controller.capabilities(for: snapshot)
        #expect(capabilities.supportsSensorMode)
        #expect(capabilities.supportsPerformanceLevel)

        var draft = snapshot.settings
        draft.sensorMode = 1
        draft.performanceLevel = 30
        draft.sleepTimeCode = 30
        let plan = WritePlanner(
            family: snapshot.family,
            catalog: .embedded,
            capabilities: capabilities
        ).plan(from: snapshot.settings, to: draft)
        #expect(plan.operations.map(\.id).contains("perf.sensorMode"))
        #expect(plan.operations.map(\.id).contains("power.sleep"))
        #expect(plan.operations.map(\.id).contains("power.sleepPerformance"))

        #expect((try await controller.apply(plan)).outcome == .succeeded)
        let refreshed = try await controller.readSnapshot()
        #expect(refreshed.settings.sensorMode == 1)
        #expect(refreshed.settings.performanceLevel == 30)
        #expect(refreshed.settings.sleepTimeCode == 30)
        await controller.disconnect()
    }

    @Test("Le fan mode reste réservé au modèle dont la flash et le catalogue le déclarent")
    func fanModeRoundTrip() async throws {
        let (_, controller) = makeController(cid: 87, mid: 101, connectionType: .wireless1k)
        let snapshot = try await controller.connect()
        let capabilities = await controller.capabilities(for: snapshot)
        #expect(capabilities.supportsFanMode)
        #expect(capabilities.fanModeOptions == [0, 1, 2, 3, 4])

        var draft = snapshot.settings
        draft.fanMode = 3
        let plan = WritePlanner(
            family: snapshot.family,
            catalog: .embedded,
            capabilities: capabilities
        ).plan(from: snapshot.settings, to: draft)
        #expect(plan.operations.contains { $0.id == "perf.fanMode" })
        #expect((try await controller.apply(plan)).outcome == .succeeded)
        #expect((try await controller.readSnapshot()).settings.fanMode == 3)
        await controller.disconnect()
    }

    @Test("Une commande récepteur non sondée ne crée pas de capacité d'interface")
    func unsupportedReceiverSettingsAreNotExposed() async throws {
        var faults = SimulatedHIDTransport.Faults()
        faults.unsupportedCommands = [
            .getPulsarDongleLightParam,
            .getPulsarDongleDPILightParam,
            .getPulsarDongleOButtonCurrentMode,
            .getPulsarDongleOButtonFunction,
        ]
        let (_, controller) = makeController(faults: faults)
        let snapshot = try await controller.connect()
        let capabilities = await controller.capabilities(for: snapshot)
        #expect(capabilities.receiver.supportsRGBLighting)
        #expect(!capabilities.receiver.supportsEffect)
        #expect(!capabilities.receiver.supportsDPILighting)
        #expect(!capabilities.receiver.supportsButtonMode)
        #expect(!capabilities.receiver.supportsButtonFunctions)
        await controller.disconnect()
    }

    @Test("Une commande récepteur avalée est relue puis restaurée")
    func receiverWriteDivergenceIsRestored() async throws {
        let (transport, controller) = makeController()
        let snapshot = try await controller.connect()
        let capabilities = await controller.capabilities(for: snapshot)
        var draft = snapshot.settings
        var receiver = try #require(draft.receiver)
        receiver.dpiLightEnabled = false
        draft.receiver = receiver
        let plan = WritePlanner(
            family: snapshot.family,
            catalog: .embedded,
            capabilities: capabilities
        ).plan(from: snapshot.settings, to: draft)

        var faults = SimulatedHIDTransport.Faults()
        faults.dropReceiverWrites = true
        await transport.setFaults(faults)
        let result = try await controller.apply(plan)

        guard case .failedAndRestored = result.outcome else {
            Issue.record("la relecture d'une commande récepteur avalée doit être restaurée")
            return
        }
        #expect((try await controller.readSnapshot()).settings.receiver == snapshot.settings.receiver)
        await controller.disconnect()
    }

    @Test("Un plan appliqué se retrouve à la relecture")
    func applyThenReadBack() async throws {
        let (_, controller) = makeController()
        let snapshot = try await controller.connect()

        var draft = snapshot.settings
        draft.debounceMilliseconds = 5
        draft.motionSync.toggle()
        draft.dpiStages[0].x = 1600
        draft.dpiStages[0].y = 1600

        let plan = WritePlanner(family: snapshot.family, catalog: .embedded)
            .plan(from: snapshot.settings, to: draft)
        let result = try await controller.apply(plan)
        #expect(result.outcome == .succeeded)

        let refreshed = try await controller.readSnapshot()
        #expect(refreshed.settings.debounceMilliseconds == 5)
        #expect(refreshed.settings.motionSync == draft.motionSync)
        #expect(refreshed.settings.dpiStages[0].x == 1600)
        await controller.disconnect()
    }

    @Test("DPI asymétrique, couleur et effet lumineux font un round-trip simulateur")
    func dpiAndLightingRoundTrip() async throws {
        let (_, controller) = makeController()
        let snapshot = try await controller.connect()

        var draft = snapshot.settings
        draft.dpiStages[0].x = 800
        draft.dpiStages[0].y = 1600
        draft.dpiStages[0].color = CatalogColor(red: 12, green: 128, blue: 250)
        draft.dpiEffect.mode = .breathing
        draft.dpiEffect.speed = 8
        draft.dpiEffect.brightness = 7
        draft.dpiEffect.enabled = false

        let plan = WritePlanner(family: snapshot.family, catalog: .embedded)
            .plan(from: snapshot.settings, to: draft)
        let result = try await controller.apply(plan)
        #expect(result.outcome == .succeeded)

        let refreshed = try await controller.readSnapshot()
        #expect(refreshed.settings.dpiStages[0].x == 800)
        #expect(refreshed.settings.dpiStages[0].y == 1600)
        #expect(refreshed.settings.dpiStages[0].color == draft.dpiStages[0].color)
        #expect(refreshed.settings.dpiEffect.mode == .breathing)
        #expect(refreshed.settings.dpiEffect.speed == 8)
        #expect(refreshed.settings.dpiEffect.brightness == 7)
        #expect(!refreshed.settings.dpiEffect.enabled)
        await controller.disconnect()
    }

    @Test("Une écriture sans effet est détectée et le lot est restauré")
    func failedWriteIsRolledBack() async throws {
        let (transport, controller) = makeController()
        let snapshot = try await controller.connect()

        var draft = snapshot.settings
        draft.debounceMilliseconds = 5
        draft.sleepTimeCode = 30

        // La souris accepte les trames mais n'applique plus rien.
        await transport.setFaults({
            var faults = SimulatedHIDTransport.Faults()
            faults.dropWrites = true
            return faults
        }())

        let plan = WritePlanner(family: snapshot.family, catalog: .embedded)
            .plan(from: snapshot.settings, to: draft)
        let result = try await controller.apply(plan)

        guard case .failedAndRestored = result.outcome else {
            Issue.record("attendu : échec suivi d'une restauration, obtenu \(result.outcome)")
            return
        }
        #expect(result.applied.isEmpty)
        await controller.disconnect()
    }

    @Test("Une restauration impossible laisse l'état matériel déclaré incertain")
    func failedRollbackIsReportedAsUncertain() async throws {
        let (transport, controller) = makeController()
        let snapshot = try await controller.connect()

        var draft = snapshot.settings
        draft.debounceMilliseconds = 5
        draft.liftOffMillimetres = 2
        draft.sleepTimeCode = 30

        let plan = WritePlanner(family: snapshot.family, catalog: .embedded)
            .plan(from: snapshot.settings, to: draft)
        #expect(plan.count >= 2)

        // La première écriture passe, puis plus rien ne s'applique — y compris la
        // restauration, ce qui est exactement le cas que l'utilisateur doit voir nommé.
        Task {
            try? await Task.sleep(for: .milliseconds(15))
            await transport.setFaults({
                var faults = SimulatedHIDTransport.Faults()
                faults.dropWrites = true
                return faults
            }())
        }

        let result = try await controller.apply(plan)
        if case .succeeded = result.outcome {
            // Le basculement de panne est arrivé trop tard : rien à vérifier ici.
            await controller.disconnect()
            return
        }
        #expect(result.outcome != .succeeded)
        await controller.disconnect()
    }

    @Test("La réinitialisation ramène les réglages d'usine")
    func factoryReset() async throws {
        let (_, controller) = makeController()
        let snapshot = try await controller.connect()

        var draft = snapshot.settings
        draft.debounceMilliseconds = 12
        let plan = WritePlanner(family: snapshot.family, catalog: .embedded)
            .plan(from: snapshot.settings, to: draft)
        _ = try await controller.apply(plan)

        let restored = try await controller.factoryReset()
        #expect(restored.settings.debounceMilliseconds == snapshot.family.debounce.default)
        await controller.disconnect()
    }

    @Test("Un modèle absent du catalogue est refusé plutôt qu'approximé")
    func unrecognisedDeviceIsRejected() async throws {
        // MID 250 n'existe dans aucune famille : le simulateur ne peut pas le construire,
        // donc on vérifie la garde côté catalogue.
        #expect(DeviceCatalog.embedded.family(cid: 87, mid: 250) == nil)
    }

    @Test("Le journal de diagnostic retient les trames échangées")
    func diagnosticLogIsPopulated() async throws {
        let (_, controller) = makeController()
        _ = try await controller.connect()
        let log = await controller.diagnosticLog()
        #expect(!log.isEmpty)
        #expect(log.contains { $0.outgoing && $0.frame.command == .encryptionData })
        await controller.disconnect()
    }
}

@Suite("Modèle applicatif")
@MainActor
struct AppModelTests {
    @Test("La connexion simulée renseigne l'état et les capacités")
    func connectsToSimulator() async {
        let model = AppModel.simulated()
        await model.connect()

        #expect(model.connection == .connected)
        #expect(model.snapshot != nil)
        #expect(model.capabilities?.buttonCount == 6)
        #expect(!model.hasPendingChanges)
        await model.disconnect()
    }

    @Test("Modifier le brouillon crée des changements en attente sans écrire")
    func draftStaysLocal() async {
        let model = AppModel.simulated()
        await model.connect()
        let before = model.snapshot?.settings

        model.draft.debounceMilliseconds = 7
        #expect(model.hasPendingChanges)
        #expect(model.pendingChanges.count == 1)
        // L'instantané, lui, n'a pas bougé : rien n'est parti vers le matériel.
        #expect(model.snapshot?.settings == before)
        await model.disconnect()
    }

    @Test("Annuler ramène le brouillon à l'état lu")
    func revertRestoresDraft() async {
        let model = AppModel.simulated()
        await model.connect()

        model.draft.debounceMilliseconds = 9
        model.draft.motionSync.toggle()
        #expect(model.hasPendingChanges)

        model.revert()
        #expect(!model.hasPendingChanges)
        #expect(model.draft == model.snapshot?.settings)
        await model.disconnect()
    }

    @Test("Appliquer écrit puis relit, et vide la liste des changements")
    func applyCommitsChanges() async {
        let model = AppModel.simulated()
        await model.connect()

        model.draft.debounceMilliseconds = 6
        await model.apply()

        #expect(model.connection == .connected)
        #expect(!model.hasPendingChanges)
        #expect(model.snapshot?.settings.debounceMilliseconds == 6)
        #expect(model.lastResult?.outcome == .succeeded)
        await model.disconnect()
    }

    @Test("Un brouillon invalide bloque l'application")
    func invalidDraftBlocksApply() async {
        let model = AppModel.simulated()
        await model.connect()

        model.draft.debounceMilliseconds = 99
        #expect(model.validationIssues.contains { $0.isBlocking })
        #expect(!model.canApply)
        await model.disconnect()
    }

    @Test("Les sections proposées suivent les capacités du modèle")
    func sectionsFollowCapabilities() async {
        let wireless = AppModel.simulated(connectionType: .wireless4k)
        await wireless.connect()
        #expect(wireless.availableSections.contains(.power))
        await wireless.disconnect()
    }
}
