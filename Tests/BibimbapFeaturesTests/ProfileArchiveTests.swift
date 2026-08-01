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
        let archive = ProfileArchive(snapshot: snapshot)
        let decoded = try ProfileArchive.decode(from: archive.encoded())

        #expect(decoded.version == ProfileArchive.currentVersion)
        #expect(decoded.cid == snapshot.identity.cid)
        #expect(decoded.mid == snapshot.identity.mid)
        #expect(decoded.settings == snapshot.settings)
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
}
