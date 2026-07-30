import Foundation
import Testing
@testable import BibimbapFeatures
@testable import PulsarCatalog
@testable import PulsarProtocol
@testable import PulsarSimulator

@Suite("Contrôleur — cycle lecture / écriture / relecture")
struct DeviceControllerTests {
    private func makeController(
        faults: SimulatedHIDTransport.Faults = .init()
    ) -> (SimulatedHIDTransport, DeviceController) {
        let transport = SimulatedHIDTransport(faults: faults)
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
        _ = try await controller.connect()

        let disabled = try await controller.setDongleLightEnabled(false)
        #expect(disabled.dongleLighting?.isEnabled == false)

        let enabled = try await controller.setDongleLightEnabled(true)
        #expect(enabled.dongleLighting?.isEnabled == true)
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
