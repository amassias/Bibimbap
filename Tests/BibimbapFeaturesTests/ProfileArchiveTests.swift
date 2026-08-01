import Foundation
import Testing
@testable import BibimbapFeatures
@testable import PulsarCatalog
@testable import PulsarProtocol
@testable import PulsarSimulator

@Suite("Sauvegardes de profil")
struct ProfileArchiveTests {
    private func connectedSnapshot() async throws -> DeviceSnapshot {
        let controller = DeviceController(transport: SimulatedHIDTransport())
        let snapshot = try await controller.connect()
        await controller.disconnect()
        return snapshot
    }

    private func capabilities(for snapshot: DeviceSnapshot) -> DeviceCapabilities {
        DeviceCapabilities(
            family: snapshot.family, catalog: .embedded,
            connection: snapshot.identity.connectionType,
            supportsProfiles: true, supportsLongDistance: true, supportsSignalStrength: true
        )
    }

    @Test("Une sauvegarde fait l'aller-retour JSON sans perte")
    func roundTripsThroughJSON() async throws {
        let snapshot = try await connectedSnapshot()
        let archive = ProfileArchive(
            snapshot: snapshot,
            profileSlot: 2,
            hardwareLocation: "0x00000000",
            hardwareTransport: "USB"
        )
        let decoded = try ProfileArchive.decode(from: archive.encoded())

        #expect(decoded.version == ProfileArchive.currentVersion)
        #expect(decoded.cid == snapshot.identity.cid)
        #expect(decoded.mid == snapshot.identity.mid)
        #expect(decoded.settings == snapshot.settings)
        #expect(decoded.profileSlot == 2)
        #expect(decoded.hardwareLocation == "0x00000000")
        #expect(decoded.hardwareTransport == "USB")
    }

    @Test("Une comparaison de profils expose des valeurs utilisateur")
    func comparesProfilesWithUserValues() async throws {
        let snapshot = try await connectedSnapshot()
        var first = ProfileArchive(snapshot: snapshot, profileSlot: 0)
        var second = ProfileArchive(snapshot: snapshot, profileSlot: 1)
        first.settings.debounceMilliseconds = 2
        second.settings.debounceMilliseconds = 6
        second.settings.reportRateHertz = 4000
        second.settings.dpiEffect.mode = .breathing

        let comparison = first.comparison(with: second)

        #expect(comparison.differences.contains {
            $0.id == "perf.debounce" && $0.before == "2 ms" && $0.after == "6 ms"
        })
        #expect(comparison.differences.contains {
            $0.id == "perf.rate" && $0.before == "1 kHz" && $0.after == "4 kHz"
        })
        #expect(comparison.differences.contains {
            $0.id == "light.mode" && $0.before == "Éteint" && $0.after == "Respiration"
        })
        #expect(comparison.differences.allSatisfy { !$0.before.contains(" ") || !$0.before.contains("0x") })
    }

    @Test("Un bouton exporté avant le codec de raccourcis reste lisible")
    func decodesLegacyButtonAssignment() throws {
        let data = Data(#"{"index":0,"function":1,"parameter":256}"#.utf8)
        let button = try JSONDecoder().decode(
            DeviceSettings.ButtonAssignment.self,
            from: data
        )
        #expect(button.shortcut == nil)
        #expect(button.function == .mouseButton)
        #expect(button.parameter == 256)
    }

    @Test("Une sauvegarde d'une version future est refusée plutôt que réinterprétée")
    func rejectsFutureVersions() async throws {
        let snapshot = try await connectedSnapshot()
        var archive = ProfileArchive(snapshot: snapshot)
        archive.version = ProfileArchive.currentVersion + 1

        #expect(throws: ProfileArchive.ArchiveError.unsupportedVersion(archive.version)) {
            try ProfileArchive.decode(from: archive.encoded())
        }
    }

    @Test("Une archive ne peut pas inventer un emplacement matériel")
    func rejectsInvalidProfileSlots() async throws {
        let snapshot = try await connectedSnapshot()
        var archive = ProfileArchive(snapshot: snapshot)
        archive.profileSlot = DeviceController.profileCount

        #expect(throws: ProfileArchive.ArchiveError.invalidProfileSlot(archive.profileSlot!)) {
            try ProfileArchive.decode(from: archive.encoded())
        }
    }

    @Test("Une sauvegarde compatible est reprise intégralement")
    func adoptsCompatibleSettings() async throws {
        let snapshot = try await connectedSnapshot()
        var saved = snapshot.settings
        saved.debounceMilliseconds = 6
        saved.dpiStages[0].x = 1600
        saved.dpiStages[0].y = 1600

        var archive = ProfileArchive(snapshot: snapshot)
        archive.settings = saved

        let (result, skipped) = archive.settings(
            fittingFamily: snapshot.family,
            capabilities: capabilities(for: snapshot),
            catalog: .embedded,
            current: snapshot.settings
        )
        #expect(skipped.isEmpty)
        #expect(result.debounceMilliseconds == 6)
        #expect(result.dpiStages[0].x == 1600)
    }

    @Test("Un polling que la connexion ne permet pas est écarté, pas forcé")
    func skipsUnreachableReportRate() async throws {
        let snapshot = try await connectedSnapshot()
        var saved = snapshot.settings
        saved.reportRateHertz = 8000

        var archive = ProfileArchive(snapshot: snapshot)
        archive.settings = saved

        // La liaison simulée plafonne à 4 kHz : 8 kHz doit être refusé.
        let (result, skipped) = archive.settings(
            fittingFamily: snapshot.family,
            capabilities: capabilities(for: snapshot),
            catalog: .embedded,
            current: snapshot.settings
        )
        #expect(result.reportRateHertz == snapshot.settings.reportRateHertz)
        // Le libellé est localisé et peut grouper les milliers : on teste le sujet,
        // pas sa mise en forme.
        #expect(skipped.contains { $0.contains("Polling") })
    }

    @Test("Un DPI non représentable est ramené au pas du capteur et signalé")
    func snapsUnrepresentableDPI() async throws {
        let snapshot = try await connectedSnapshot()
        var saved = snapshot.settings
        saved.dpiStages[0].x = 405
        saved.dpiStages[0].y = 405

        var archive = ProfileArchive(snapshot: snapshot)
        archive.settings = saved

        let (result, skipped) = archive.settings(
            fittingFamily: snapshot.family,
            capabilities: capabilities(for: snapshot),
            catalog: .embedded,
            current: snapshot.settings
        )
        #expect(result.dpiStages[0].x == 410)
        #expect(skipped.contains { $0.contains("Stage 1") })
    }

    @Test("Une capacité absente du modèle est écartée et nommée")
    func skipsUnsupportedCapabilities() async throws {
        let snapshot = try await connectedSnapshot()
        var reduced = capabilities(for: snapshot)
        reduced.supportsRotation = false
        reduced.supportsLongDistance = false

        var saved = snapshot.settings
        saved.rotationDegrees = 12
        saved.longDistance = true

        var archive = ProfileArchive(snapshot: snapshot)
        archive.settings = saved

        let (result, skipped) = archive.settings(
            fittingFamily: snapshot.family,
            capabilities: reduced,
            catalog: .embedded,
            current: snapshot.settings
        )
        #expect(result.rotationDegrees == snapshot.settings.rotationDegrees)
        #expect(!result.longDistance)
        #expect(skipped.count == 2)
    }

    @Test("Importer une sauvegarde ne fait que remplir le brouillon")
    @MainActor
    func importOnlyTouchesDraft() async throws {
        let model = AppModel.simulated()
        await model.connect()
        let before = model.snapshot?.settings

        var archive = try #require(model.exportProfile())
        archive.settings.debounceMilliseconds = 7
        let skipped = model.importProfile(archive)

        #expect(skipped.isEmpty)
        #expect(model.draft.debounceMilliseconds == 7)
        #expect(model.hasPendingChanges)
        // Rien n'est parti vers le matériel : l'instantané est intact.
        #expect(model.snapshot?.settings == before)
        await model.disconnect()
    }

    @Test("L'export du profil actif indique le slot et l'emplacement matériel")
    @MainActor
    func exportIncludesActiveHardwareLocation() async throws {
        let model = AppModel.simulated()
        await model.connect()

        let archive = try #require(model.exportProfile())

        #expect(archive.profileSlot == model.activeProfileIndex)
        #expect(archive.hardwareLocation == model.hardwareLocation)
        #expect(archive.hardwareTransport == model.hardwareTransport)
        #expect(archive.hardwareLocationLabel.contains("emplacement"))
        await model.disconnect()
    }

    @Test("L'aperçu d'import ne modifie ni le brouillon ni la flash")
    @MainActor
    func importPreviewIsReadOnly() async throws {
        let transport = SimulatedHIDTransport()
        let model = AppModel.simulated(transport: transport)
        await model.connect()
        let original = model.snapshot!.settings
        var archive = try #require(model.exportProfile())
        archive.settings.debounceMilliseconds = original.debounceMilliseconds + 2
        let flashBefore = await transport.flashImage()

        let preview = try #require(model.previewProfileImport(archive))

        #expect(preview.changes.contains { $0.after == "\(original.debounceMilliseconds + 2) ms" })
        #expect(model.draft == original)
        #expect(model.profileImportPreview != nil)
        #expect(await transport.flashImage() == flashBefore)

        model.confirmProfileImportPreview()
        #expect(model.draft.debounceMilliseconds == original.debounceMilliseconds + 2)
        #expect(await transport.flashImage() == flashBefore)
        await model.disconnect()
    }

    @Test("La comparaison relit deux slots puis restaure le profil actif")
    @MainActor
    func comparesHardwareProfilesAndRestoresActiveSlot() async throws {
        let transport = SimulatedHIDTransport()
        let model = AppModel.simulated(transport: transport)
        await model.connect()
        let sourceValue = model.snapshot!.settings.debounceMilliseconds

        await model.selectProfile(1)
        let targetValue = sourceValue + 4
        await transport.changeSettingOnDevice(UInt8(targetValue), at: FlashMap.debounceTime)
        await model.reload()
        await model.selectProfile(0)

        let comparison = try #require(await model.compareProfiles(0, 1))

        #expect(model.snapshot?.activeProfile == 0)
        #expect(comparison.differences.contains {
            $0.id == "perf.debounce"
                && $0.before == "\(sourceValue) ms"
                && $0.after == "\(targetValue) ms"
        })
        await model.disconnect()
    }

    @Test("La copie inter-profils est prévisualisée puis appliquée avec restauration de l'actif")
    @MainActor
    func copiesProfileAfterExplicitPreview() async throws {
        let transport = SimulatedHIDTransport()
        let model = AppModel.simulated(transport: transport)
        await model.connect()
        let sourceValue = model.snapshot!.settings.debounceMilliseconds + 2
        model.draft.debounceMilliseconds = sourceValue
        await model.apply()

        await model.selectProfile(1)
        let targetValue = sourceValue + 2
        await transport.changeSettingOnDevice(UInt8(targetValue), at: FlashMap.debounceTime)
        await model.reload()
        await model.selectProfile(0)
        let targetBefore = await transport.flashImage(forProfile: 1)

        let preview = try #require(await model.previewProfileCopy(to: 1))
        #expect(preview.changes.contains {
            $0.before == "\(targetValue) ms" && $0.after == "\(sourceValue) ms"
        })
        #expect(await transport.flashImage(forProfile: 1) == targetBefore)
        #expect(model.snapshot?.activeProfile == 0)

        await model.applyProfileCopyPreview()

        #expect(model.connection == .connected)
        #expect(model.snapshot?.activeProfile == 0)
        let copied = await transport.flashImage(forProfile: 1)
        #expect(copied.slice(at: FlashMap.debounceTime, count: 1).first == UInt8(sourceValue))
        await model.disconnect()
    }
}
