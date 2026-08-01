import Foundation
import Testing
@testable import BibimbapFeatures
@testable import PulsarCatalog
@testable import PulsarProtocol
@testable import PulsarSimulator

/// Les modèles servant de témoins, choisis pour leurs listes de boutons.
///
/// `nonContiguous` est le cas qui piège toutes les numérotations dérivées de l'index :
/// six commandes, mais des index firmware 0, 1, 2, 6, 4, 3.
private enum SampleMID {
    static let sixButtons = 10       // X2 CrazyLight — index 0, 1, 2, 5, 4, 3
    static let fiveButtons = 36      // Pulsar Lab. X2F — index 0, 1, 2, 4, 3
    static let nonContiguous = 111   // X5 — index 0, 1, 2, 6, 4, 3
}

private func connected(mid: Int) async throws -> (DeviceController, DeviceSnapshot) {
    let transport = SimulatedHIDTransport(cid: 87, mid: mid)
    let controller = DeviceController(transport: transport)
    return (controller, try await controller.connect())
}

private func presentations(mid: Int) async throws -> ([ButtonPresentation], DeviceController) {
    let (controller, snapshot) = try await connected(mid: mid)
    return (
        ButtonPresentation.list(family: snapshot.family, settings: snapshot.settings),
        controller
    )
}

@Suite("Numérotation des boutons")
struct ButtonPresentationTests {
    @Test("Un modèle à six boutons contigus affiche 1 à 6")
    func sixContiguousButtons() async throws {
        let (buttons, controller) = try await presentations(mid: SampleMID.sixButtons)

        #expect(buttons.count == 6)
        #expect(buttons.map(\.displayNumber) == [1, 2, 3, 4, 5, 6])
        #expect(Set(buttons.map(\.firmwareIndex)) == [0, 1, 2, 3, 4, 5])
        await controller.disconnect()
    }

    @Test("Un modèle à cinq boutons affiche 1 à 5, sans sixième")
    func fiveButtons() async throws {
        let (buttons, controller) = try await presentations(mid: SampleMID.fiveButtons)

        #expect(buttons.count == 5)
        #expect(buttons.map(\.displayNumber) == [1, 2, 3, 4, 5])
        #expect(!buttons.contains { $0.displayNumber == 6 })
        #expect(Set(buttons.map(\.firmwareIndex)) == [0, 1, 2, 3, 4])
        await controller.disconnect()
    }

    @Test("Des index firmware discontinus donnent tout de même six numéros de 1 à 6")
    func nonContiguousFirmwareIndices() async throws {
        let (buttons, controller) = try await presentations(mid: SampleMID.nonContiguous)

        #expect(buttons.count == 6)
        #expect(buttons.map(\.displayNumber) == [1, 2, 3, 4, 5, 6])
        #expect(!buttons.contains { $0.displayNumber > 6 })
        // L'index 6 existe bel et bien, et l'index 5 n'existe pas.
        #expect(buttons.map(\.firmwareIndex) == [0, 1, 2, 6, 4, 3])
        // Le bouton d'index firmware 6 porte le numéro 4, pas 7.
        let sixth = try #require(buttons.first { $0.firmwareIndex == 6 })
        #expect(sixth.displayNumber == 4)
        await controller.disconnect()
    }

    @Test("L'ordre d'affichage suit l'ordre officiel du catalogue")
    func displayOrderFollowsCatalog() async throws {
        for mid in [SampleMID.sixButtons, SampleMID.fiveButtons, SampleMID.nonContiguous] {
            let (controller, snapshot) = try await connected(mid: mid)
            let buttons = ButtonPresentation.list(
                family: snapshot.family, settings: snapshot.settings
            )

            #expect(buttons.map(\.profile.order) == Array(0..<buttons.count), "MID \(mid)")
            #expect(
                buttons.map(\.firmwareIndex) == snapshot.family.orderedButtons.map(\.index),
                "MID \(mid)"
            )
            // Les affectations relues sont dans le même ordre que la carte.
            #expect(snapshot.settings.buttons.map(\.index) == buttons.map(\.firmwareIndex))
            await controller.disconnect()
        }
    }

    @Test("Le rôle vient du profil, jamais de l'index")
    func rolesComeFromTheProfile() async throws {
        let (controller, snapshot) = try await connected(mid: SampleMID.nonContiguous)
        let family = snapshot.family

        #expect(family.button(firmwareIndex: 0)?.role == .primaryClick)
        #expect(family.button(firmwareIndex: 1)?.role == .secondaryClick)
        #expect(family.button(firmwareIndex: 2)?.role == .wheelClick)
        #expect(family.button(firmwareIndex: 3)?.role == .back)
        #expect(family.button(firmwareIndex: 4)?.role == .forward)
        // Le quatrième de la carte n'est ni « Back » ni « Forward » : c'est un
        // verrouillage DPI, ce que seul le profil dit.
        #expect(family.button(firmwareIndex: 6)?.role == .dpiLock)
        await controller.disconnect()
    }

    @Test("Chaque bouton d'un modèle connu porte une position exploitable")
    func everyButtonHasGeometry() async throws {
        let (buttons, controller) = try await presentations(mid: SampleMID.nonContiguous)

        for button in buttons {
            let marker = try #require(button.normalizedMarker, "bouton \(button.displayNumber)")
            #expect(marker.x > 0 && marker.x < 1)
            #expect(marker.y > 0 && marker.y < 1)
        }
        // Les repères des clics principal et secondaire encadrent l'axe de la souris.
        let primary = try #require(buttons.first { $0.profile.role == .primaryClick })
        let secondary = try #require(buttons.first { $0.profile.role == .secondaryClick })
        let left = try #require(primary.normalizedMarker)
        let right = try #require(secondary.normalizedMarker)
        #expect(left.x < 0.5 && right.x > 0.5)
        #expect(abs((left.x + right.x) / 2 - 0.5) < 0.02)
        await controller.disconnect()
    }

    @Test("Un bouton sans géométrie publiée garde sa ligne mais n'invente pas de repère")
    func missingGeometryYieldsNoMarker() {
        let profile = ButtonProfile(
            index: 6, order: 3, geometry: nil, defaultType: 1, defaultParameter: 0x0800
        )
        let presentation = ButtonPresentation(
            assignment: .init(index: 6, function: .mouseButton, parameter: 0x0800),
            profile: profile,
            displayNumber: 4
        )

        #expect(presentation.normalizedMarker == nil)
        #expect(presentation.numberLabel.contains("4"))
    }
}

@Suite("Écritures et macros sur index firmware discontinus")
struct NonContiguousButtonWriteTests {
    @Test("Une écriture vise l'adresse de l'index firmware, pas le numéro affiché")
    func writesUseFirmwareIndices() async throws {
        let (controller, snapshot) = try await connected(mid: SampleMID.nonContiguous)

        var draft = snapshot.settings
        let position = try #require(draft.buttons.firstIndex { $0.index == 6 })
        draft.buttons[position].function = .reportRateSwitch
        draft.buttons[position].parameter = 0

        let plan = WritePlanner(family: snapshot.family, catalog: .embedded)
            .plan(from: snapshot.settings, to: draft)
        let operation = try #require(plan.operations.first { $0.id == "button.6" })
        #expect(operation.address == FlashMap.keyFunction(button: 6))
        // Le libellé, lui, montre le numéro visible : le quatrième de la carte.
        #expect(operation.label.contains("4"))
        #expect(!plan.operations.contains { $0.id == "button.5" })

        #expect(try await controller.apply(plan).outcome == .succeeded)
        let refreshed = try await controller.readSnapshot()
        let written = try #require(refreshed.settings.buttons.first { $0.index == 6 })
        #expect(written.function == .reportRateSwitch)
        await controller.disconnect()
    }

    @Test("Une macro sur un index firmware discontinu survit à l'import")
    func macroOnNonContiguousIndexSurvivesImport() async throws {
        let (controller, snapshot) = try await connected(mid: SampleMID.nonContiguous)
        let capabilities = await controller.capabilities(for: snapshot)
        #expect(capabilities.firmwareButtonIndices == [0, 1, 2, 3, 4, 6])

        var saved = snapshot.settings
        let position = try #require(saved.buttons.firstIndex { $0.index == 6 })
        saved.buttons[position].function = .macro
        saved.buttons[position].parameter = (6 << 8) | 1
        saved.macros = [
            .init(slot: 6, macro: PulsarMacro(name: "Sniper", steps: []), repeatCount: 1),
            // L'emplacement 5 n'est déclaré par aucun bouton de ce modèle.
            .init(slot: 5, macro: PulsarMacro(name: "Fantôme", steps: []), repeatCount: 1),
        ]

        var archive = ProfileArchive(snapshot: snapshot)
        archive.settings = saved

        let (fitted, skipped) = archive.settings(
            fittingFamily: snapshot.family,
            capabilities: capabilities,
            catalog: .embedded,
            current: snapshot.settings
        )

        // L'emplacement 6 est en dehors de `0..<buttonCount` mais bien déclaré : le
        // comparer au nombre de boutons l'aurait supprimé.
        #expect(fitted.macros.map(\.slot) == [6])
        #expect(skipped.contains { $0.contains("macro") })
        #expect(fitted.buttons.first { $0.index == 6 }?.function == .macro)
        await controller.disconnect()
    }

    @Test("Les capacités listent les index firmware plutôt qu'un intervalle")
    func capabilitiesExposeFirmwareIndices() async throws {
        let (controller, snapshot) = try await connected(mid: SampleMID.fiveButtons)
        let capabilities = await controller.capabilities(for: snapshot)

        #expect(capabilities.buttonCount == 5)
        #expect(capabilities.firmwareButtonIndices == [0, 1, 2, 3, 4])
        await controller.disconnect()
    }
}

@Suite("Changement de modèle et modèle inconnu")
@MainActor
struct ConnectedModelChangeTests {
    @Test("Rien du modèle précédent ne subsiste après un changement")
    func switchingModelsLeavesNothingBehind() async throws {
        let six = AppModel.simulated(mid: SampleMID.sixButtons)
        await six.connect()
        let before = six.buttonPresentations
        #expect(before.count == 6)
        #expect(before.contains { $0.firmwareIndex == 5 })

        await six.disconnect()
        // Débranchée, l'application n'affiche plus aucun bouton hérité.
        #expect(six.buttonPresentations.isEmpty)
        #expect(six.draft.buttons.isEmpty)
        #expect(six.capabilities == nil)

        let five = AppModel.simulated(mid: SampleMID.fiveButtons)
        await five.connect()
        let after = five.buttonPresentations

        #expect(after.count == 5)
        #expect(after.map(\.displayNumber) == [1, 2, 3, 4, 5])
        // L'index firmware 5, propre au modèle précédent, a disparu — repère compris.
        #expect(!after.contains { $0.firmwareIndex == 5 })
        #expect(Set(after.compactMap { $0.normalizedMarker.map { "\($0.x),\($0.y)" } }).count == 5)
        await five.disconnect()
    }

    @Test("Un modèle absent du catalogue ne reçoit aucune liste de boutons")
    func unknownModelYieldsNoButtons() async {
        // Le catalogue ne connaît pas ce MID : aucune famille, donc rien à présenter.
        #expect(DeviceCatalog.embedded.family(cid: 87, mid: 250) == nil)

        let model = AppModel.simulated(mid: SampleMID.sixButtons)
        // Sans connexion, il n'existe pas de modèle reconnu : la liste reste vide plutôt
        // que de retomber sur une carte à six boutons par défaut.
        #expect(model.buttonPresentations.isEmpty)
        #expect(model.capabilities == nil)
    }
}
