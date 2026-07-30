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

    @Test("Un palier actif hors des paliers activés est refusé")
    func rejectsActiveStageOutOfRange() {
        var draft = baselineSettings()
        draft.enabledStageCount = 2
        draft.activeStage = 4
        #expect(validator.validate(draft).contains { $0.id == "stages.active" && $0.isBlocking })
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
