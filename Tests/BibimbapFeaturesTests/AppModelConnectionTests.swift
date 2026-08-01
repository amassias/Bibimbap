import Foundation
import Testing
@testable import BibimbapFeatures
@testable import PulsarHID
@testable import PulsarProtocol
@testable import PulsarSimulator

/// Sélection, reconnexion et récupération du brouillon, vues depuis le modèle applicatif.
///
/// Ces tests portent sur la règle produit la plus lourde de conséquences : rien n'est
/// écrit sans un geste explicite, et un brouillon n'est jamais perdu ni appliqué tout seul.
extension AppModelTests {
    // MARK: Outillage

    fileprivate static func secondCandidate() -> HIDDeviceIdentifier {
        HIDDeviceIdentifier(
            vendorID: 0x3710, productID: 0x3414, locationID: 0x0230_0000,
            usagePage: 0xFF05, usage: 1,
            productName: "Pulsar X2V2 Mini", manufacturer: "Pulsar",
            transport: .usb, maxInputReportSize: 17, maxOutputReportSize: 17
        )
    }

    fileprivate static func makeModel(
        _ configure: (inout SimulatedHIDTransport.Faults) -> Void = { _ in }
    ) -> (SimulatedHIDTransport, AppModel) {
        var faults = SimulatedHIDTransport.Faults()
        configure(&faults)
        let transport = SimulatedHIDTransport(faults: faults)
        return (transport, AppModel.simulated(transport: transport))
    }

    /// Les évènements HID sont traités hors du geste qui les provoque : on attend l'effet
    /// plutôt que de supposer qu'il est déjà arrivé.
    fileprivate func waitUntil(
        _ timeout: Duration = .seconds(15),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: Sélection

    @Test("Un seul candidat se connecte sans rien demander")
    func singleCandidateConnectsAutomatically() async {
        let (transport, model) = Self.makeModel()
        await model.connect()

        #expect(model.connection == .connected)
        #expect(model.availableCandidates.count == 1)
        let expectedKey = await transport.deviceIdentifier().stableKey
        #expect(model.selectedStableKey == expectedKey)
        await model.disconnect()
    }

    @Test("Plusieurs candidats passent la main à l'utilisateur, sans rien ouvrir")
    func multipleCandidatesRequireSelection() async {
        let (transport, model) = Self.makeModel { $0.extraCandidates = [Self.secondCandidate()] }
        await model.connect()

        #expect(model.connection == .selectingDevice)
        #expect(model.availableCandidates.count == 2)
        #expect(model.snapshot == nil)
        // Le point essentiel : aucune collection n'a été ouverte au hasard.
        #expect(await transport.totalOpenCount() == 0)
        await model.disconnect()
    }

    @Test("La sélection n'est pas une occupation")
    func selectionIsNotBusy() {
        #expect(AppModel.ConnectionState.selectingDevice.isBusy == false)
        #expect(AppModel.ConnectionState.reconnecting(attempt: 1).isBusy)
        #expect(AppModel.ConnectionState.scanning.isBusy)
        #expect(AppModel.ConnectionState.writing(progress: 0).isBusy)
    }

    @Test("Le candidat choisi est celui qui s'ouvre")
    func chosenCandidateIsTheOneOpened() async {
        let (transport, model) = Self.makeModel { $0.extraCandidates = [Self.secondCandidate()] }
        await model.connect()
        #expect(model.connection == .selectingDevice)

        await model.connect(to: transport.deviceIdentifier())
        #expect(model.connection == .connected)
        #expect(await transport.totalOpenCount() == 1)
        await model.disconnect()
    }

    @Test("Un candidat qui refuse la connexion ne fait pas ouvrir les autres")
    func failedCandidateDoesNotCascade() async {
        let (transport, model) = Self.makeModel { $0.extraCandidates = [Self.secondCandidate()] }
        await model.connect()

        await model.connect(to: Self.secondCandidate())
        #expect(model.snapshot == nil)
        #expect(model.availableCandidates.count == 2)
        // Aucune session : surtout pas celle du périphérique qu'on n'a pas choisi.
        #expect(await transport.openSessionCount() == 0)

        model.showDeviceSelection()
        #expect(model.connection == .selectingDevice)
        await model.disconnect()
    }

    @Test("Une permission refusée a son propre état")
    func permissionDeniedHasItsOwnState() async {
        let (_, model) = Self.makeModel { $0.discoveryFailure = .permissionDenied }
        await model.connect()

        #expect(model.connection == .permissionDenied)
        await model.disconnect()
    }

    @Test("Une souris qui ne répond pas est distinguée d'une panne de communication")
    func handshakeTimeoutHasItsOwnState() async {
        let (_, model) = Self.makeModel { $0.silentCommands = [.encryptionData] }
        await model.connect()

        #expect(model.connection == .handshakeTimedOut)
        await model.disconnect()
    }

    // MARK: Concurrence

    @Test("Fenêtre et barre des menus partagent la même tentative")
    func concurrentConnectSharesOneAttempt() async {
        let (transport, model) = Self.makeModel()

        async let fromWindow: Void = model.connect()
        async let fromMenuBar: Void = model.connect()
        _ = await (fromWindow, fromMenuBar)

        #expect(model.connection == .connected)
        #expect(await transport.totalOpenCount() == 1)
        await model.disconnect()
    }

    // MARK: Reconnexion

    @Test("Un débranchement conserve le brouillon et reconnecte tout seul")
    func draftSurvivesDetachment() async {
        let (transport, model) = Self.makeModel()
        await model.connect()
        let base = model.snapshot!.settings.debounceMilliseconds
        model.draft.debounceMilliseconds = base + 2

        await transport.detachDevice()
        #expect(await waitUntil { if case .reconnecting = model.connection { true } else { false } })
        // Le brouillon est là pendant la coupure : c'est tout l'intérêt de ne pas appeler
        // `disconnect()` sur un débranchement subi.
        #expect(model.draft.debounceMilliseconds == base + 2)

        await transport.attachDevice()
        #expect(await waitUntil { model.connection == .connected })
        #expect(model.draft.debounceMilliseconds == base + 2)
        #expect(model.hasPendingChanges)
        #expect(model.draftRecovery == nil)
        // Et surtout : rien n'a été écrit tout seul au retour.
        #expect(await transport.flashImage().slice(at: FlashMap.debounceTime, count: 1).first == UInt8(base))
        await model.disconnect()
    }

    @Test("Les débranchements répétés ne lancent qu'une reconnexion")
    func duplicateEventsDoNotStackReconnections() async {
        let (transport, model) = Self.makeModel()
        await model.connect()

        await transport.detachDevice()
        // On attend que le débranchement soit réellement pris en compte, sans présumer
        // de l'état exact : selon le moment, c'est `.reconnecting` ou déjà la suite.
        let observed = await waitUntil { model.connection != .connected }
        #expect(observed, "débranchement non pris en compte, état : \(model.connection)")

        // Un même débranchement remonte une fois par collection HID exposée.
        let identifier = await transport.deviceIdentifier()
        await transport.replayEvent(.detached(identifier))
        await transport.replayEvent(.detached(identifier))
        await transport.attachDevice()

        #expect(await waitUntil { model.connection == .connected })
        // Laisser passer d'éventuels doublons différés avant de compter.
        try? await Task.sleep(for: .milliseconds(700))

        // Une ouverture au départ, une au retour. Pas trois.
        let opens = await transport.totalOpenCount()
        #expect(opens == 2, "ouvertures : \(opens)")
        await model.disconnect()
    }

    @Test("La reconnexion est bornée et rend la main")
    func reconnectionIsBounded() async {
        let (transport, model) = Self.makeModel()
        await model.connect()
        let base = model.snapshot!.settings.debounceMilliseconds
        model.draft.debounceMilliseconds = base + 2

        // Le périphérique ne revient jamais : cinq tentatives, puis l'utilisateur décide.
        await transport.detachDevice()
        #expect(await waitUntil { model.connection == .noDevice })
        #expect(model.draft.debounceMilliseconds == base + 2)
        await model.disconnect()
    }

    @Test("Un débranchement demandé par l'utilisateur ne relance rien")
    func userDisconnectDoesNotReconnect() async {
        let (transport, model) = Self.makeModel()
        await model.connect()
        await model.disconnect()

        await transport.detachDevice()
        await transport.attachDevice()
        try? await Task.sleep(for: .milliseconds(600))

        #expect(model.connection == .idle)
        #expect(model.snapshot == nil)
    }

    // MARK: Conflit et récupération

    @Test("Un changement distant sous un brouillon produit un conflit explicite")
    func remoteChangeUnderDraftRaisesConflict() async {
        let (transport, model) = Self.makeModel()
        await model.connect()
        let base = model.snapshot!.settings.debounceMilliseconds
        model.draft.debounceMilliseconds = base + 2

        // La souris a été touchée à la main pendant que le brouillon attendait.
        await transport.changeSettingOnDevice(UInt8(base + 4), at: FlashMap.debounceTime)
        await transport.pushChangeNotification(primary: 1, secondary: 0)

        #expect(await waitUntil { model.draftRecovery != nil })
        let recovery = model.draftRecovery!
        #expect(recovery.cause == .deviceReportedChange)
        #expect(recovery.conflicts.count == 1)
        #expect(recovery.conflicts.first?.localValue == "\(base + 2) ms")
        #expect(recovery.conflicts.first?.remoteValue == "\(base + 4) ms")
        // Tant que le conflit n'est pas tranché, rien ne peut partir vers le matériel.
        #expect(!model.canApply)
        await model.disconnect()
    }

    @Test("Conserver le brouillon repart de l'état relu, sans écrire")
    func keepingDraftRebasesWithoutWriting() async {
        let (transport, model) = Self.makeModel()
        await model.connect()
        let base = model.snapshot!.settings.debounceMilliseconds
        model.draft.debounceMilliseconds = base + 2
        await transport.changeSettingOnDevice(UInt8(base + 4), at: FlashMap.debounceTime)
        await transport.pushChangeNotification(primary: 1, secondary: 0)
        #expect(await waitUntil { model.draftRecovery != nil })

        model.keepDraftAfterRecovery()

        #expect(model.draftRecovery == nil)
        #expect(model.draft.debounceMilliseconds == base + 2)
        #expect(model.canApply)
        // Le choix ne déclenche aucune écriture : la flash porte toujours l'état distant.
        let onDevice = await transport.flashImage().slice(at: FlashMap.debounceTime, count: 1).first
        #expect(onDevice == UInt8(base + 4))
        await model.disconnect()
    }

    @Test("Adopter les réglages relus efface le brouillon, sans écrire")
    func adoptingRemoteDropsDraft() async {
        let (transport, model) = Self.makeModel()
        await model.connect()
        let base = model.snapshot!.settings.debounceMilliseconds
        model.draft.debounceMilliseconds = base + 2
        await transport.changeSettingOnDevice(UInt8(base + 4), at: FlashMap.debounceTime)
        await transport.pushChangeNotification(primary: 1, secondary: 0)
        #expect(await waitUntil { model.draftRecovery != nil })

        model.adoptRemoteAfterRecovery()

        #expect(model.draftRecovery == nil)
        #expect(model.draft.debounceMilliseconds == base + 4)
        #expect(!model.hasPendingChanges)
        let onDevice = await transport.flashImage().slice(at: FlashMap.debounceTime, count: 1).first
        #expect(onDevice == UInt8(base + 4))
        await model.disconnect()
    }

    @Test("Sans brouillon, une notification de la souris relit simplement")
    func deviceChangeWithoutDraftJustReloads() async {
        let (transport, model) = Self.makeModel()
        await model.connect()
        let base = model.snapshot!.settings.debounceMilliseconds

        await transport.changeSettingOnDevice(UInt8(base + 4), at: FlashMap.debounceTime)
        await transport.pushChangeNotification(primary: 1, secondary: 0)

        #expect(await waitUntil { model.snapshot?.settings.debounceMilliseconds == base + 4 })
        #expect(model.draftRecovery == nil)
        #expect(!model.hasPendingChanges)
        await model.disconnect()
    }

    @Test("Relire et comparer conserve le brouillon au lieu de l'écraser")
    func explicitRereadComparesPendingDraft() async {
        let (transport, model) = Self.makeModel()
        await model.connect()
        let base = model.snapshot!.settings.debounceMilliseconds
        model.draft.debounceMilliseconds = base + 2
        await transport.changeSettingOnDevice(UInt8(base + 4), at: FlashMap.debounceTime)

        await model.rereadAndCompare()

        #expect(model.draftRecovery?.cause == .explicitComparison)
        #expect(model.draft.debounceMilliseconds == base + 2)
        #expect(!model.canApply)
        #expect(await transport.flashImage().slice(at: FlashMap.debounceTime, count: 1).first
                == UInt8(base + 4))
        await model.disconnect()
    }

    // MARK: Écriture interrompue

    @Test("Une écriture coupée laisse un état incertain jusqu'à une relecture explicite")
    func interruptedWriteRequiresExplicitReread() async {
        let (transport, model) = Self.makeModel()
        await model.connect()
        let base = model.snapshot!.settings.debounceMilliseconds
        model.draft.debounceMilliseconds = base + 2

        // Le dialogue se coupe au milieu du lot.
        await transport.setFaults({
            var faults = SimulatedHIDTransport.Faults()
            faults.disconnectAfterFrames = 1
            return faults
        }())
        await model.apply()

        guard case .disconnectedDuringWrite = model.connection else {
            Issue.record("attendu : état matériel incertain, obtenu \(model.connection)")
            return
        }
        #expect(model.requiresExplicitReread)
        // Aucune réécriture automatique : Apply reste fermé tant qu'on n'a pas relu.
        #expect(!model.canApply)
        await model.disconnect()
    }

    @Test("La progression compte uniquement les opérations relues")
    func writeProgressIsPerVerifiedOperation() async {
        let (transport, model) = Self.makeModel()
        await model.connect()
        let base = model.snapshot!.settings
        model.draft.debounceMilliseconds = base.debounceMilliseconds + 2
        model.draft.motionSync.toggle()

        await model.apply()

        #expect(model.connection == .connected)
        #expect(model.writeProgress?.completed == model.writeProgress?.total)
        #expect(model.writeProgress?.total == 2)
        #expect(model.writeProgress?.currentOperation == nil)
        #expect(await transport.flashImage().slice(at: FlashMap.debounceTime, count: 1).first
                == UInt8(base.debounceMilliseconds + 2))
        await model.disconnect()
    }

    @Test("La récupération dédiée reconnecte avant de lever l'incertitude")
    func uncertainHardwareRecoveryReconnectsAndCompares() async {
        let (transport, model) = Self.makeModel()
        await model.connect()
        let base = model.snapshot!.settings.debounceMilliseconds
        model.draft.debounceMilliseconds = base + 2

        var faults = SimulatedHIDTransport.Faults()
        faults.disconnectAfterFrames = 1
        await transport.setFaults(faults)
        await model.apply()
        #expect(model.requiresExplicitReread)

        await transport.setFaults(SimulatedHIDTransport.Faults())
        await model.recoverUncertainHardware()

        #expect(model.connection == .connected)
        #expect(!model.requiresExplicitReread)
        // La récupération relit sans appliquer le brouillon resté en mémoire.
        #expect(model.hasPendingChanges)
        #expect(await transport.flashImage().slice(at: FlashMap.debounceTime, count: 1).first
                == UInt8(base))
        await model.disconnect()
    }

    @Test("Une incertitude conserve le brouillon si la lecture de contrôle reste possible")
    func uncertainWriteKeepsDraftAfterReadableFailure() async {
        let (transport, model) = Self.makeModel()
        await model.connect()
        let base = model.snapshot!.settings
        model.draft.debounceMilliseconds = base.debounceMilliseconds + 2
        model.draft.motionSync.toggle()

        var faults = SimulatedHIDTransport.Faults()
        faults.dropWritesAfterWriteOperations = 1
        await transport.setFaults(faults)
        await model.apply()

        #expect(model.requiresExplicitReread)
        #expect(model.hasPendingChanges)
        #expect(model.draft.debounceMilliseconds == base.debounceMilliseconds + 2)
        guard case .disconnectedDuringWrite(let uncertain) = model.connection else {
            Issue.record("attendu : état matériel incertain, obtenu \(model.connection)")
            await model.disconnect()
            return
        }
        #expect(!uncertain.isEmpty)
        await model.disconnect()
    }
}
