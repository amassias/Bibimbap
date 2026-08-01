import Foundation
import Testing
@testable import BibimbapFeatures
@testable import PulsarCatalog
@testable import PulsarProtocol
@testable import PulsarSimulator

private let catalog = DeviceCatalog.embedded
private let family = catalog.family(cid: 87, mid: 10)!

private func baselineSettings() -> DeviceSettings {
    var settings = DeviceSettings()
    settings.reportRateHertz = 1000
    settings.enabledStageCount = family.dpi.stages.count
    settings.activeStage = 1
    settings.debounceMilliseconds = family.debounce.default
    settings.liftOffMillimetres = family.sensor.defaultLiftOff
    settings.sleepTimeCode = family.power.defaultSleepTimeCode
    settings.dpiStages = family.dpi.stages.enumerated().map { index, stage in
        DeviceSettings.DPIStage(index: index, x: stage.value, y: stage.value, color: stage.color)
    }
    settings.buttons = family.buttons.map {
        DeviceSettings.ButtonAssignment(
            index: $0.index,
            function: PulsarKeyFunction(rawValue: UInt8($0.defaultType)) ?? .disabled,
            parameter: $0.defaultParameter
        )
    }
    return settings
}

@Suite("Plan d'écriture")
struct WritePlanTests {
    let planner = WritePlanner(family: family, catalog: catalog)

    @Test("Un brouillon identique ne produit aucune écriture")
    func noChangesMeansNoPlan() {
        let settings = baselineSettings()
        #expect(planner.plan(from: settings, to: settings).isEmpty)
    }

    @Test("Seuls les réglages modifiés produisent une opération")
    func onlyDiffsAreWritten() {
        var draft = baselineSettings()
        draft.debounceMilliseconds = 6
        let plan = planner.plan(from: baselineSettings(), to: draft)
        #expect(plan.count == 1)
        #expect(plan.operations.first?.address == FlashMap.debounceTime)
        #expect(plan.operations.first?.payload == .scalar(6))
        #expect(plan.operations.first?.rollback == .scalar(UInt8(family.debounce.default)))
    }

    @Test("Les paliers DPI sont écrits avant le palier actif et leur nombre")
    func stagesComeFirst() {
        var draft = baselineSettings()
        draft.dpiStages[0].x = 1600
        draft.dpiStages[0].y = 1600
        draft.activeStage = 0
        draft.enabledStageCount = 3

        let plan = planner.plan(from: baselineSettings(), to: draft)
        let ids = plan.operations.map(\.id)
        let valueIndex = try! #require(ids.firstIndex(of: "dpi.value.0"))
        let countIndex = try! #require(ids.firstIndex(of: "dpi.count"))
        let activeIndex = try! #require(ids.firstIndex(of: "dpi.active"))
        #expect(valueIndex < countIndex)
        #expect(countIndex < activeIndex)
    }

    @Test("L'alimentation est écrite en dernier")
    func powerComesLast() {
        var draft = baselineSettings()
        draft.sleepTimeCode = 30
        draft.debounceMilliseconds = 5
        draft.reportRateHertz = 500

        let plan = planner.plan(from: baselineSettings(), to: draft)
        #expect(plan.operations.last?.group == .power)
    }

    @Test("La veille synchronise les deux temporisations firmware")
    func sleepWritesBothFirmwareTimers() {
        var draft = baselineSettings()
        draft.sleepTimeCode = 60
        let operations = planner.plan(from: baselineSettings(), to: draft).operations
            .filter { $0.id.hasPrefix("power.sleep") }

        #expect(operations.map(\.address) == [FlashMap.sleepTime, FlashMap.performance])
        #expect(operations.allSatisfy { $0.payload == .scalar(60) })
        #expect(planner.changes(from: baselineSettings(), to: draft).count == 1)
    }

    @Test("Chaque opération porte de quoi revenir en arrière")
    func everyOperationHasRollback() {
        var draft = baselineSettings()
        draft.debounceMilliseconds = 7
        draft.dpiStages[2].x = 2000
        draft.dpiStages[2].y = 2000
        draft.buttons[0].function = .macro
        draft.sleepTimeCode = 30

        for operation in planner.plan(from: baselineSettings(), to: draft).operations {
            #expect(operation.rollback != nil, "\(operation.id)")
        }
    }

    @Test("Le changement de polling passe par le code flash, pas par la valeur en Hz")
    func reportRateIsEncoded() {
        var draft = baselineSettings()
        draft.reportRateHertz = 500
        let plan = planner.plan(from: baselineSettings(), to: draft)
        #expect(plan.operations.first?.payload == .scalar(2))
    }

    @Test("La liste présentée à l'utilisateur reflète le plan")
    func pendingChangesMirrorPlan() {
        var draft = baselineSettings()
        draft.debounceMilliseconds = 4
        draft.motionSync = true
        let changes = planner.changes(from: baselineSettings(), to: draft)
        #expect(changes.count == 2)
        #expect(changes.allSatisfy { $0.group == .performance })
    }

    @Test("La couleur, X/Y et l'effet DPI passent par leurs codecs et portent une restauration")
    func dpiAndLightingFieldsAreEncoded() throws {
        var draft = baselineSettings()
        draft.dpiStages[0].x = 800
        draft.dpiStages[0].y = 1600
        draft.dpiStages[0].color = CatalogColor(red: 12, green: 128, blue: 250)
        draft.dpiEffect.mode = .breathing
        draft.dpiEffect.speed = 8
        draft.dpiEffect.brightness = 7
        draft.dpiEffect.enabled = false

        let operations = planner.plan(from: baselineSettings(), to: draft).operations
        #expect(operations.map(\.id).contains("dpi.value.0"))
        #expect(operations.map(\.id).contains("dpi.color.0"))
        #expect(operations.first { $0.id == "light.mode" }?.payload == .scalar(2))
        #expect(operations.first { $0.id == "light.speed" }?.payload == .scalar(8))
        #expect(operations.first { $0.id == "light.brightness" }?.payload == .scalar(7))
        #expect(operations.first { $0.id == "light.state" }?.payload == .scalar(0))
        #expect(operations.allSatisfy { $0.rollback != nil })

        let colorOperation = try #require(operations.first { $0.id == "dpi.color.0" })
        #expect(colorOperation.payload == .block(try DPIColorCodec().encode(draft.dpiStages[0].color)))
        #expect(colorOperation.rollback == .block(
            try DPIColorCodec().encode(baselineSettings().dpiStages[0].color)
        ))
    }
}

@Suite("Validation du brouillon")
struct DraftValidatorTests {
    let capabilities = DeviceCapabilities(
        family: family,
        catalog: catalog,
        connection: .wireless4k,
        supportsProfiles: true,
        supportsLongDistance: true,
        supportsSignalStrength: true
    )

    var validator: DraftValidator {
        DraftValidator(capabilities: capabilities, family: family, catalog: catalog)
    }

    @Test("Un brouillon d'usine est valide")
    func baselineIsValid() {
        #expect(validator.validate(baselineSettings()).isEmpty)
    }

    @Test("Une cadence au-dessus du plafond de la connexion est bloquante")
    func rejectsExcessiveReportRate() {
        var draft = baselineSettings()
        draft.reportRateHertz = 8000
        let issues = validator.validate(draft)
        #expect(issues.contains { $0.id == "rate" && $0.isBlocking })
    }

    @Test("Un rebond au-delà du seuil avertit sans bloquer")
    func warnsAboveDebounceThreshold() {
        var draft = baselineSettings()
        draft.debounceMilliseconds = family.debounce.warnAbove + 1
        let issues = validator.validate(draft)
        #expect(issues.contains { $0.id == "debounce.warn" && !$0.isBlocking })
    }

    @Test("Un rebond au-delà du maximum matériel est bloquant")
    func blocksAboveDebounceMaximum() {
        var draft = baselineSettings()
        draft.debounceMilliseconds = family.debounce.maximum + 1
        #expect(validator.validate(draft).contains { $0.id == "debounce.max" && $0.isBlocking })
    }

    @Test("Un DPI non représentable par le capteur est refusé avant écriture")
    func rejectsUnrepresentableDPI() {
        var draft = baselineSettings()
        draft.dpiStages[0].x = 405
        draft.dpiStages[0].y = 405
        #expect(validator.validate(draft).contains { $0.id.hasPrefix("stage.0") && $0.isBlocking })
    }

    @Test("Les plages du capteur sont exposées et les valeurs intermédiaires sont arrondies par le même codec")
    func capabilitiesExposeDPIRanges() {
        #expect(capabilities.supportsDPIEditing)
        #expect(capabilities.dpiRepresentableRanges == [
            DPIRepresentableRange(minimum: 10, maximum: 10_000, step: 10),
            DPIRepresentableRange(minimum: 10_050, maximum: 30_000, step: 50),
            DPIRepresentableRange(minimum: 30_100, maximum: 32_000, step: 100),
        ])
        #expect(capabilities.snapDPI(10_025) == 10_000)
        #expect(capabilities.snapDPI(10_026) == 10_050)
    }

    @Test("Une vitesse ou une couleur hors codec bloque l'application")
    func rejectsInvalidLightingFields() {
        var draft = baselineSettings()
        draft.dpiEffect.speed = DPIEffectCodec.speedRange.upperBound + 1
        draft.dpiStages[0].color = CatalogColor(red: -1, green: 0, blue: 0)

        let issues = validator.validate(draft)
        #expect(issues.contains { $0.id == "lighting.speed" && $0.isBlocking })
        #expect(issues.contains { $0.id == "stage.0.color" && $0.isBlocking })
    }

    @Test("Un palier actif hors des paliers activés est refusé")
    func rejectsActiveStageOutOfRange() {
        var draft = baselineSettings()
        draft.enabledStageCount = 2
        draft.activeStage = 4
        #expect(validator.validate(draft).contains { $0.id == "stages.active" && $0.isBlocking })
    }

    @Test("Un paramètre rapid-fire hors bornes est refusé")
    func rejectsInvalidButtonParameter() {
        var draft = baselineSettings()
        draft.buttons[0].function = .rapidFire
        draft.buttons[0].parameter = 9 << 8
        #expect(validator.validate(draft).contains {
            $0.id == "button.0.parameter" && $0.isBlocking
        })
    }

    @Test("Un raccourci sans touche ne peut pas être écrit")
    func rejectsEmptyShortcut() {
        var draft = baselineSettings()
        draft.buttons[0].function = .keyboardShortcut
        draft.buttons[0].parameter = 0
        draft.buttons[0].shortcut = PulsarShortcut(keys: [])
        #expect(validator.validate(draft).contains {
            $0.id == "button.0.shortcut" && $0.isBlocking
        })
    }

    @Test("La cadence de macro est projetée dans l'octet du bouton")
    func macroRepeatBindingIsEncodedInButtonBlock() {
        var current = baselineSettings()
        current.buttons[3].function = .macro
        current.buttons[3].parameter = (3 << 8) | 1

        var draft = current
        draft.macros = [DeviceSettings.MacroBinding(
            slot: 3,
            macro: PulsarMacro(name: "Test", steps: [
                .init(kind: .key, action: .press, value: 4, delayMilliseconds: 0),
            ]),
            repeatCount: 5
        )]
        let operation = WritePlanner(family: family, catalog: catalog)
            .plan(from: current, to: draft).operations.first {
            $0.id == "button.3"
        }
        guard case .block(let bytes) = operation?.payload else {
            Issue.record("Le plan ne contient pas le bloc du bouton 3")
            return
        }
        #expect(bytes[0] == PulsarKeyFunction.macro.rawValue)
        #expect(bytes[1] == 3)
        #expect(bytes[2] == 5)
    }

    @Test("Les capacités reflètent le plafond de la connexion")
    func capabilitiesFollowConnection() {
        let wired = DeviceCapabilities(
            family: family, catalog: catalog, connection: .wired1k,
            supportsProfiles: true, supportsLongDistance: true, supportsSignalStrength: true
        )
        #expect(wired.availableReportRates == [125, 250, 500, 1000])
        #expect(!wired.supportsBattery)
        #expect(!wired.supportsLongDistance)
    }
}
