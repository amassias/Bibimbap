import Foundation
import Testing
@testable import BibimbapFeatures
@testable import PulsarCatalog
@testable import PulsarProtocol
@testable import PulsarSimulator

@Suite("Macros — bout en bout sur le simulateur")
struct MacroBindingTests {
    private func connected() async throws -> (SimulatedHIDTransport, DeviceController, DeviceSnapshot) {
        let transport = SimulatedHIDTransport()
        let controller = DeviceController(transport: transport)
        let snapshot = try await controller.connect()
        return (transport, controller, snapshot)
    }

    private func sampleMacro() -> PulsarMacro {
        PulsarMacro(name: "Tir en rafale", steps: [
            .init(kind: .mouseButton, action: .press, value: 1, delayMilliseconds: 0),
            .init(kind: .mouseButton, action: .release, value: 1, delayMilliseconds: 0),
            .init(kind: .key, action: .press, value: 4, delayMilliseconds: 15),
            .init(kind: .key, action: .release, value: 4, delayMilliseconds: 15),
        ])
    }

    @Test("Une macro écrite se relit à l'identique depuis le périphérique")
    func writeThenRead() async throws {
        let (_, controller, snapshot) = try await connected()

        var draft = snapshot.settings
        // Le bouton 3 porte déjà une macro dans les réglages d'usine du catalogue.
        let slot = 3
        draft.buttons[slot].function = .macro
        draft.buttons[slot].parameter = (slot << 8) | 2
        draft.macros = [
            DeviceSettings.MacroBinding(slot: slot, macro: sampleMacro(), repeatCount: 2)
        ]

        let plan = WritePlanner(family: snapshot.family, catalog: .embedded)
            .plan(from: snapshot.settings, to: draft)
        let result = try await controller.apply(plan)
        #expect(result.outcome == .succeeded)

        let refreshed = try await controller.readSnapshot()
        let binding = try #require(refreshed.settings.macros.first { $0.slot == slot })
        #expect(binding.macro.name == "Tir en rafale")
        #expect(binding.macro.steps.count == 4)
        #expect(binding.repeatCount == 2)
        #expect(binding.macro.steps[0].action == .press)
        #expect(binding.macro.steps[1].action == .release)
        await controller.disconnect()
    }

    @Test("La macro est écrite avant le bouton qui la référence")
    func macroPrecedesButton() async throws {
        let (_, controller, snapshot) = try await connected()

        var draft = snapshot.settings
        draft.buttons[3].function = .macro
        draft.buttons[3].parameter = (3 << 8) | 1
        draft.macros = [DeviceSettings.MacroBinding(slot: 3, macro: sampleMacro(), repeatCount: 1)]

        let plan = WritePlanner(family: snapshot.family, catalog: .embedded)
            .plan(from: snapshot.settings, to: draft)
        let ids = plan.operations.map(\.id)
        if let macroIndex = ids.firstIndex(of: "macro.3"),
           let buttonIndex = ids.firstIndex(of: "button.3") {
            #expect(macroIndex < buttonIndex)
        }
        await controller.disconnect()
    }

    @Test("Un nom trop long pour la flash est refusé avant écriture")
    func rejectsOverlongName() async throws {
        let (_, controller, snapshot) = try await connected()
        let capabilities = DeviceCapabilities(
            family: snapshot.family, catalog: .embedded,
            connection: snapshot.identity.connectionType,
            supportsProfiles: true, supportsLongDistance: true, supportsSignalStrength: true
        )

        var draft = snapshot.settings
        draft.macros = [DeviceSettings.MacroBinding(
            slot: 3,
            macro: PulsarMacro(name: String(repeating: "é", count: 20), steps: []),
            repeatCount: 1
        )]

        let issues = DraftValidator(
            capabilities: capabilities, family: snapshot.family, catalog: .embedded
        ).validate(draft)
        // 20 caractères accentués font 40 octets UTF-8, au-delà des 30 disponibles.
        #expect(issues.contains { $0.id == "macro.3.name" && $0.isBlocking })
        await controller.disconnect()
    }

    @Test("Un nombre de répétitions hors bornes est refusé")
    func rejectsInvalidRepeatCount() async throws {
        let (_, controller, snapshot) = try await connected()
        let capabilities = DeviceCapabilities(
            family: snapshot.family, catalog: .embedded,
            connection: snapshot.identity.connectionType,
            supportsProfiles: true, supportsLongDistance: true, supportsSignalStrength: true
        )

        var draft = snapshot.settings
        draft.macros = [DeviceSettings.MacroBinding(
            slot: 3, macro: sampleMacro(), repeatCount: 0
        )]
        let issues = DraftValidator(
            capabilities: capabilities, family: snapshot.family, catalog: .embedded
        ).validate(draft)
        #expect(issues.contains { $0.id == "macro.3.repeat" && $0.isBlocking })
        await controller.disconnect()
    }

    @Test("Un emplacement sans macro n'en invente pas une")
    func emptySlotYieldsNothing() async throws {
        let (_, controller, snapshot) = try await connected()
        // Les réglages d'usine affectent des macros à certains boutons, mais aucun bloc
        // macro n'est écrit : la relecture ne doit donc rien remonter.
        #expect(snapshot.settings.macros.isEmpty)
        await controller.disconnect()
    }

    @Test("Un raccourci clavier écrit son bloc séparé puis se relit")
    func writeThenReadShortcut() async throws {
        let (_, controller, snapshot) = try await connected()

        var draft = snapshot.settings
        let buttonIndex = 0
        draft.buttons[buttonIndex].function = .keyboardShortcut
        draft.buttons[buttonIndex].parameter = 0
        draft.buttons[buttonIndex].shortcut = PulsarShortcut(keys: [
            .init(kind: .modifier, value: 8),
            .init(kind: .key, value: 4),
        ])

        let plan = WritePlanner(family: snapshot.family, catalog: .embedded)
            .plan(from: snapshot.settings, to: draft)
        let ids = plan.operations.map(\.id)
        #expect(ids.contains("shortcut.0"))
        #expect(ids.contains("button.0"))
        #expect(ids.firstIndex(of: "shortcut.0")! < ids.firstIndex(of: "button.0")!)

        let result = try await controller.apply(plan)
        #expect(result.outcome == .succeeded)

        let refreshed = try await controller.readSnapshot()
        #expect(refreshed.settings.buttons[buttonIndex].function == .keyboardShortcut)
        #expect(refreshed.settings.buttons[buttonIndex].shortcut
            == draft.buttons[buttonIndex].shortcut)
        await controller.disconnect()
    }
}
