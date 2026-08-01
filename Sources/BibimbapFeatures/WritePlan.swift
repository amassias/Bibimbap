import BibimbapLocalization
import Foundation
import PulsarCatalog
import PulsarProtocol

/// Une modification en attente, telle que présentée à l'utilisateur avant application.
public struct PendingChange: Identifiable, Equatable, Sendable {
    public enum Group: String, Sendable, CaseIterable {
        case performance
        case dpi
        case lighting
        case buttons
        case macros
        case power

        public var label: String {
            switch self {
            case .performance: L10n.string( "Performance")
            case .dpi: L10n.string( "DPI")
            case .lighting: L10n.string( "Éclairage")
            case .buttons: L10n.string( "Boutons")
            case .macros: L10n.string( "Macros")
            case .power: L10n.string( "Alimentation")
            }
        }
    }

    public var id: String
    public var group: Group
    public var label: String
    public var before: String
    public var after: String

    public init(id: String, group: Group, label: String, before: String, after: String) {
        self.id = id
        self.group = group
        self.label = label
        self.before = before
        self.after = after
    }
}

/// Une opération d'écriture élémentaire, avec de quoi la vérifier et la défaire.
public struct WriteOperation: Identifiable, Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        /// Réglage scalaire : valeur suivie de son complément à 0x55.
        case scalar(UInt8)
        /// Bloc quelconque déjà checksummé.
        case block([UInt8])
        /// Commande hors flash.
        case command(PulsarCommand, [UInt8])
    }

    public var id: String
    public var group: PendingChange.Group
    public var label: String
    public var address: UInt16
    public var payload: Payload
    /// Valeur à réécrire pour revenir en arrière si le lot échoue.
    public var rollback: Payload?

    public init(
        id: String,
        group: PendingChange.Group,
        label: String,
        address: UInt16,
        payload: Payload,
        rollback: Payload?
    ) {
        self.id = id
        self.group = group
        self.label = label
        self.address = address
        self.payload = payload
        self.rollback = rollback
    }
}

/// L'ensemble ordonné des écritures à effectuer pour passer de l'état lu au brouillon.
public struct WritePlan: Equatable, Sendable {
    public var operations: [WriteOperation]

    public var isEmpty: Bool { operations.isEmpty }
    public var count: Int { operations.count }
}

/// Résultat d'une application, y compris partielle.
public struct WriteResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case succeeded
        /// Le lot a échoué et l'état précédent a été restauré intégralement.
        case failedAndRestored(failure: String)
        /// Le lot a échoué et la restauration n'a pas abouti : l'état matériel est incertain.
        case failedAndUncertain(failure: String, uncertain: [String])
    }

    public var outcome: Outcome
    public var applied: [String]

    public var isUncertain: Bool {
        if case .failedAndUncertain = outcome { return true }
        return false
    }
}

/// Construit le plan d'écriture à partir de l'écart entre l'état lu et le brouillon.
///
/// L'ordre est déterministe et volontairement conservateur : les paliers DPI avant le
/// palier actif et le nombre de paliers, pour ne jamais pointer un palier pas encore
/// écrit ; l'alimentation en dernier, parce qu'elle peut endormir le périphérique.
public struct WritePlanner: Sendable {
    public let family: DeviceFamily
    public let catalog: DeviceCatalog
    private let codec: DPICodec?

    public init(family: DeviceFamily, catalog: DeviceCatalog) {
        self.family = family
        self.catalog = catalog
        self.codec = DPICodec(family: family, catalog: catalog)
    }

    public func changes(from current: DeviceSettings, to draft: DeviceSettings) -> [PendingChange] {
        plan(from: current, to: draft).operations
            .filter { $0.id != "power.sleepPerformance" }
            .map {
                PendingChange(
                    id: $0.id,
                    group: $0.group,
                    label: $0.label,
                    before: describe($0.rollback),
                    after: describe($0.payload)
                )
            }
    }

    private func describe(_ payload: WriteOperation.Payload?) -> String {
        switch payload {
        case .scalar(let value): String(value)
        case .block(let bytes): bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .command(_, let bytes): bytes.map(String.init).joined(separator: " ")
        case nil: "—"
        }
    }

    public func plan(from current: DeviceSettings, to draft: DeviceSettings) -> WritePlan {
        var operations: [WriteOperation] = []

        func scalar(
            _ id: String,
            _ group: PendingChange.Group,
            _ label: String,
            _ address: UInt16,
            _ new: Int,
            _ old: Int
        ) {
            guard new != old else { return }
            operations.append(WriteOperation(
                id: id, group: group, label: label, address: address,
                payload: .scalar(UInt8(clamping: new)),
                rollback: .scalar(UInt8(clamping: old))
            ))
        }

        func effectScalar(
            _ id: String,
            _ label: String,
            _ address: UInt16,
            _ field: DPIEffectCodec.Field,
            _ new: Int,
            _ old: Int
        ) {
            guard new != old,
                  let encodedNew = try? DPIEffectCodec().encode(new, for: field),
                  let encodedOld = try? DPIEffectCodec().encode(old, for: field) else { return }
            operations.append(WriteOperation(
                id: id, group: .lighting, label: label, address: address,
                payload: .scalar(encodedNew), rollback: .scalar(encodedOld)
            ))
        }

        // 1. Paliers DPI, avant tout ce qui les référence.
        if let codec {
            for stage in draft.dpiStages {
                guard let previous = current.dpiStages.first(where: { $0.index == stage.index }) else { continue }
                if stage.x != previous.x || stage.y != previous.y,
                   let block = try? codec.encodeStage(x: stage.x, y: stage.y),
                   let restore = try? codec.encodeStage(x: previous.x, y: previous.y) {
                    operations.append(WriteOperation(
                        id: "dpi.value.\(stage.index)",
                        group: .dpi,
                        label: L10n.format("Stage %d", stage.index + 1),
                        address: FlashMap.dpiValue(stage: stage.index, extended: codec.usesExtendedBlock),
                        payload: .block(block),
                        rollback: .block(restore)
                    ))
                }
                if stage.color != previous.color,
                   let block = try? DPIColorCodec().encode(stage.color),
                   let restore = try? DPIColorCodec().encode(previous.color) {
                    operations.append(WriteOperation(
                        id: "dpi.color.\(stage.index)",
                        group: .dpi,
                        label: L10n.format("Stage %d color", stage.index + 1),
                        address: FlashMap.dpiColor(stage: stage.index),
                        payload: .block(block),
                        rollback: .block(restore)
                    ))
                }
            }
        }

        scalar("dpi.count", .dpi, L10n.string( "Nombre de paliers"),
               FlashMap.maxDPIStage, draft.enabledStageCount, current.enabledStageCount)
        scalar("dpi.active", .dpi, L10n.string( "Palier actif"),
               FlashMap.currentDPI, draft.activeStage, current.activeStage)

        // 2. Performance et capteur.
        if draft.reportRateHertz != current.reportRateHertz,
           let new = ReportRateCodec.code(from: draft.reportRateHertz),
           let old = ReportRateCodec.code(from: current.reportRateHertz) {
            operations.append(WriteOperation(
                id: "perf.rate", group: .performance,
                label: L10n.string( "Polling"),
                address: FlashMap.reportRate,
                payload: .scalar(new), rollback: .scalar(old)
            ))
        }
        scalar("perf.lod", .performance, L10n.string( "Distance de décrochage"),
               FlashMap.liftOffDistance, draft.liftOffMillimetres, current.liftOffMillimetres)
        scalar("perf.debounce", .performance, L10n.string( "Temps de rebond"),
               FlashMap.debounceTime, draft.debounceMilliseconds, current.debounceMilliseconds)
        scalar("perf.motionSync", .performance, L10n.string( "Motion Sync"),
               FlashMap.motionSync, draft.motionSync ? 1 : 0, current.motionSync ? 1 : 0)
        scalar("perf.angleSnap", .performance, L10n.string( "Angle Snap"),
               FlashMap.angleSnap, draft.angleSnap ? 1 : 0, current.angleSnap ? 1 : 0)
        scalar("perf.ripple", .performance, L10n.string( "Ripple Control"),
               FlashMap.rippleControl, draft.rippleControl ? 1 : 0, current.rippleControl ? 1 : 0)
        scalar("perf.performanceState", .performance, L10n.string( "Mode performance"),
               FlashMap.performanceState, draft.performanceMode ? 1 : 0, current.performanceMode ? 1 : 0)
        scalar("perf.sensorMode", .performance, L10n.string( "Mode capteur"),
               FlashMap.sensorMode, draft.sensorMode, current.sensorMode)

        if draft.rotationDegrees != current.rotationDegrees {
            // La rotation est signée ; l'octet la porte en complément à deux.
            scalar("perf.rotation", .performance, L10n.string( "Rotation"),
                   FlashMap.angleTune,
                   Int(UInt8(bitPattern: Int8(clamping: draft.rotationDegrees))),
                   Int(UInt8(bitPattern: Int8(clamping: current.rotationDegrees))))
            scalar("perf.rotationState", .performance, L10n.string( "Rotation active"),
                   FlashMap.angleTuneState,
                   draft.rotationDegrees == 0 ? 0 : 1,
                   current.rotationDegrees == 0 ? 0 : 1)
        }

        // 3. Effet lumineux du palier.
        effectScalar("light.mode", L10n.string( "Effet DPI"), FlashMap.dpiEffectMode, .mode,
                     draft.dpiEffect.mode.rawValue, current.dpiEffect.mode.rawValue)
        effectScalar("light.brightness", L10n.string( "Luminosité"), FlashMap.dpiEffectBrightness,
                     .brightness, draft.dpiEffect.brightness, current.dpiEffect.brightness)
        effectScalar("light.speed", L10n.string( "Vitesse"), FlashMap.dpiEffectSpeed, .speed,
                     draft.dpiEffect.speed, current.dpiEffect.speed)
        effectScalar("light.state", L10n.string( "Indicateur DPI"), FlashMap.dpiEffectState, .state,
                     draft.dpiEffect.enabled ? 1 : 0, current.dpiEffect.enabled ? 1 : 0)

        // 4. Macros, avant les boutons qui les référencent : un bouton ne doit jamais
        // pointer un emplacement dont le contenu n'est pas encore écrit.
        for binding in draft.macros {
            let previous = current.macros.first { $0.slot == binding.slot }
            guard previous?.macro != binding.macro else { continue }
            guard let block = try? MacroCodec.encode(binding.macro) else { continue }
            operations.append(WriteOperation(
                id: "macro.\(binding.slot)",
                group: .macros,
                label: L10n.format("Macro “%@”", binding.macro.name),
                address: FlashMap.macro(slot: binding.slot),
                payload: .block(block),
                // Sans état antérieur connu, on ne fabrique pas de restauration :
                // l'opération sera signalée comme incertaine si le lot échoue.
                rollback: previous.flatMap { try? MacroCodec.encode($0.macro) }.map { .block($0) }
            ))
        }

        // 5. Blocs de raccourci, avant la fonction qui les référence.
        // La lecture de l'état courant renseigne ces blocs même quand le bouton n'est
        // pas actuellement clavier : une restauration reste donc possible si le lot
        // échoue après cette opération.
        for button in draft.buttons {
            guard button.function == .keyboardShortcut,
                  let previous = current.buttons.first(where: { $0.index == button.index }),
                  button.shortcut != previous.shortcut,
                  let shortcut = button.shortcut,
                  let block = try? ShortcutCodec.encode(shortcut),
                  let oldShortcut = previous.shortcut,
                  let restore = try? ShortcutCodec.encode(oldShortcut)
            else { continue }
            operations.append(WriteOperation(
                id: "shortcut.\(button.index)",
                group: .buttons,
                label: L10n.format("Keyboard shortcut — button %d", button.index + 1),
                address: FlashMap.shortcut(slot: button.index),
                payload: .block(block),
                rollback: .block(restore)
            ))
        }

        // 6. Fonctions de boutons. Le raccourci est un champ séparé : changer seulement
        // sa combinaison ne doit pas réécrire le bloc de fonction (et inversement).
        for button in draft.buttons {
            if button.function == .macro {
                let slot = (button.parameter >> 8) & 0xFF
                guard draft.macros.contains(where: { $0.slot == slot }) else { continue }
            }
            guard let previous = current.buttons.first(where: { $0.index == button.index }) else {
                continue
            }
            let effectiveButton: DeviceSettings.ButtonAssignment
            if button.function == .macro,
               let binding = draft.macros.first(where: { $0.slot == ((button.parameter >> 8) & 0xFF) }) {
                var adjusted = button
                adjusted.parameter = (button.parameter & 0xFF00) | binding.repeatCount
                effectiveButton = adjusted
            } else {
                effectiveButton = button
            }
            guard previous.function != effectiveButton.function
                    || previous.parameter != effectiveButton.parameter else { continue }
            // Une zone raccourci illisible n'est pas une ancienne valeur restaurable :
            // ne rendons pas le bouton actif en prétendant pouvoir défaire ce changement.
            guard effectiveButton.function != .keyboardShortcut || previous.shortcut != nil else {
                continue
            }
            operations.append(WriteOperation(
                id: "button.\(button.index)",
                group: .buttons,
                label: L10n.format("Button %d", button.index + 1),
                address: FlashMap.keyFunction(button: button.index),
                payload: .block(buttonBlock(effectiveButton)),
                rollback: .block(buttonBlock(previous))
            ))
        }

        // 7. Alimentation, en dernier : la veille peut couper le dialogue.
        if draft.sleepTimeCode != current.sleepTimeCode {
            scalar("power.sleep", .power, L10n.string("Mise en veille"),
                   FlashMap.sleepTime, draft.sleepTimeCode, current.sleepTimeCode)
            scalar("power.sleepPerformance", .power, L10n.string("Sensor sleep"),
                   FlashMap.performance, draft.sleepTimeCode, current.performanceLevel)
        }
        scalar("power.saveBattery", .power, L10n.string( "Seuil d'économie"),
               FlashMap.powerSaveBattery, draft.powerSaveBatteryPercent, current.powerSaveBatteryPercent)

        if draft.longDistance != current.longDistance {
            operations.append(WriteOperation(
                id: "power.longDistance",
                group: .power,
                label: L10n.string( "Mode longue portée"),
                address: 0,
                payload: .command(.setLongRangeMode, [draft.longDistance ? 1 : 0]),
                rollback: .command(.setLongRangeMode, [current.longDistance ? 1 : 0])
            ))
        }

        return WritePlan(operations: operations)
    }

    private func buttonBlock(_ button: DeviceSettings.ButtonAssignment) -> [UInt8] {
        // Le verrouillage DPI range son paramètre en petit-boutiste, contrairement au reste.
        let head: [UInt8]
        if button.function == .dpiLock {
            head = [
                button.function.rawValue,
                UInt8(truncatingIfNeeded: button.parameter),
                UInt8(truncatingIfNeeded: button.parameter >> 8),
            ]
        } else {
            head = [
                button.function.rawValue,
                UInt8(truncatingIfNeeded: button.parameter >> 8),
                UInt8(truncatingIfNeeded: button.parameter),
            ]
        }
        return head + [PulsarFrame.blockChecksum(over: head)]
    }
}

/// Validation d'un brouillon contre les capacités du modèle.
///
/// Une valeur que le matériel ne sait pas représenter est refusée avant l'écriture
/// plutôt qu'acceptée puis silencieusement altérée à la relecture.
public struct DraftValidator: Sendable {
    public let capabilities: DeviceCapabilities
    private let codec: DPICodec?
    private let buttonIndices: Set<Int>

    public init(capabilities: DeviceCapabilities, family: DeviceFamily, catalog: DeviceCatalog) {
        self.capabilities = capabilities
        self.codec = DPICodec(family: family, catalog: catalog)
        self.buttonIndices = Set(family.buttons.map(\.index))
    }

    public struct Issue: Identifiable, Equatable, Sendable {
        public var id: String
        public var message: String
        public var isBlocking: Bool
    }

    public func validate(_ draft: DeviceSettings) -> [Issue] {
        var issues: [Issue] = []

        if !capabilities.availableReportRates.contains(draft.reportRateHertz) {
            issues.append(Issue(
                id: "rate",
                message: L10n.format(
                    "This model supports up to %d Hz on this connection.",
                    capabilities.availableReportRates.last ?? 1000
                ),
                isBlocking: true
            ))
        }
        if draft.debounceMilliseconds > capabilities.maximumDebounce {
            issues.append(Issue(
                id: "debounce.max",
                message: L10n.format("Debounce time cannot exceed %d ms.", capabilities.maximumDebounce),
                isBlocking: true
            ))
        } else if draft.debounceMilliseconds > capabilities.debounceWarningThreshold {
            issues.append(Issue(
                id: "debounce.warn",
                message: L10n.format(
                    "Above %d ms, click latency becomes noticeable.",
                    capabilities.debounceWarningThreshold
                ),
                isBlocking: false
            ))
        }

        for button in draft.buttons {
            guard buttonIndices.contains(button.index) else {
                issues.append(Issue(
                    id: "button.\(button.index).unavailable",
                    message: L10n.format("Button %d is not available on this model.", button.index + 1),
                    isBlocking: true
                ))
                continue
            }

            do {
                try ButtonParameterCodec.validate(
                    function: button.function,
                    parameter: button.parameter
                )
            } catch {
                issues.append(Issue(
                    id: "button.\(button.index).parameter",
                    message: L10n.format(
                        "The parameter for button %d is not supported by this function.",
                        button.index + 1
                    ),
                    isBlocking: true
                ))
            }

            switch button.function {
            case .dpiLock:
                guard (capabilities.minimumDPI...capabilities.maximumDPI).contains(button.parameter) else {
                    issues.append(Issue(
                        id: "button.\(button.index).dpiLock",
                        message: L10n.format(
                            "DPI Lock must be between %d and %d DPI.",
                            capabilities.minimumDPI,
                            capabilities.maximumDPI
                        ),
                        isBlocking: true
                    ))
                    continue
                }
                if let codec, (try? codec.snap(dpi: button.parameter)) != button.parameter {
                    issues.append(Issue(
                        id: "button.\(button.index).dpiLock",
                        message: L10n.string("DPI Lock must use a value representable by the sensor."),
                        isBlocking: true
                    ))
                }
            case .macro:
                let slot = (button.parameter >> 8) & 0xFF
                if slot != button.index {
                    issues.append(Issue(
                        id: "button.\(button.index).macroSlot",
                        message: L10n.string("A macro button must use its own hardware slot."),
                        isBlocking: true
                    ))
                }
            case .keyboardShortcut:
                guard let shortcut = button.shortcut, !shortcut.keys.isEmpty else {
                    issues.append(Issue(
                        id: "button.\(button.index).shortcut",
                        message: L10n.string("Choose at least one supported key for this shortcut."),
                        isBlocking: true
                    ))
                    continue
                }
                if (try? ShortcutCodec.encode(shortcut)) == nil {
                    issues.append(Issue(
                        id: "button.\(button.index).shortcut",
                        message: L10n.string("This shortcut cannot be represented by the device."),
                        isBlocking: true
                    ))
                }
            default:
                break
            }
        }

        for binding in draft.macros {
            if !buttonIndices.contains(binding.slot) {
                issues.append(Issue(
                    id: "macro.\(binding.slot).slot",
                    message: L10n.format("Macro slot %d is not available on this model.", binding.slot + 1),
                    isBlocking: true
                ))
            }
            let nameBytes = binding.macro.name.utf8.count
            if nameBytes == 0 || nameBytes > PulsarMacro.nameCapacity {
                issues.append(Issue(
                    id: "macro.\(binding.slot).name",
                    message: L10n.format(
                        "A macro name must be 1 to %d bytes; “%@” uses %d.",
                        PulsarMacro.nameCapacity,
                        binding.macro.name,
                        nameBytes
                    ),
                    isBlocking: true
                ))
            }
            if binding.macro.steps.count > PulsarMacro.stepCapacity {
                issues.append(Issue(
                    id: "macro.\(binding.slot).steps",
                    message: L10n.format("A macro cannot exceed %d steps.", PulsarMacro.stepCapacity),
                    isBlocking: true
                ))
            }
            if (try? MacroCodec.encode(binding.macro)) == nil {
                issues.append(Issue(
                    id: "macro.\(binding.slot).encoding",
                    message: L10n.string("This macro contains a value outside the device limits."),
                    isBlocking: true
                ))
            }
            if !(1...255).contains(binding.repeatCount) {
                issues.append(Issue(
                    id: "macro.\(binding.slot).repeat",
                    message: L10n.string( "Le nombre de répétitions doit aller de 1 à 255."),
                    isBlocking: true
                ))
            }
        }

        if draft.enabledStageCount < 1 || draft.enabledStageCount > capabilities.maximumStages {
            issues.append(Issue(
                id: "stages.count",
                message: L10n.format("This model supports 1 to %d DPI stages.", capabilities.maximumStages),
                isBlocking: true
            ))
        }
        if draft.activeStage >= draft.enabledStageCount {
            issues.append(Issue(
                id: "stages.active",
                message: L10n.string( "Le palier actif doit faire partie des paliers activés."),
                isBlocking: true
            ))
        }
        if draft.activeStage < 0 {
            issues.append(Issue(
                id: "stages.active.negative",
                message: L10n.string("Le palier actif doit être positif."),
                isBlocking: true
            ))
        }
        for stage in draft.dpiStages.prefix(draft.enabledStageCount) {
            for (axis, value) in [("X", stage.x), ("Y", stage.y)] {
                guard let codec else { continue }
                let representable = value >= capabilities.minimumDPI
                    && value <= capabilities.maximumDPI
                    && (try? codec.snap(dpi: value, upTo: capabilities.maximumDPI)) == value
                if !representable {
                    issues.append(Issue(
                        id: "stage.\(stage.index).\(axis)",
                        message: L10n.format(
                            "Stage %d (%@) is not representable by this sensor (use the displayed ranges).",
                            stage.index + 1,
                            axis
                        ),
                        isBlocking: true
                    ))
                }
            }
            if (try? DPIColorCodec().encode(stage.color)) == nil {
                issues.append(Issue(
                    id: "stage.\(stage.index).color",
                    message: L10n.format("Stage %d color is outside the RGB range 0–255.", stage.index + 1),
                    isBlocking: true
                ))
            }
        }

        let effectCodec = DPIEffectCodec()
        for (field, value, label) in [
            (DPIEffectCodec.Field.brightness, draft.dpiEffect.brightness, L10n.string("brightness")),
            (DPIEffectCodec.Field.speed, draft.dpiEffect.speed, L10n.string("speed")),
        ] where (try? effectCodec.encode(value, for: field)) == nil {
            issues.append(Issue(
                id: "lighting.\(field.rawValue)",
                message: L10n.format("The DPI lighting %@ level is outside the codec range.", label),
                isBlocking: true
            ))
        }
        if !capabilities.supportsRotation, draft.rotationDegrees != 0 {
            issues.append(Issue(
                id: "rotation",
                message: L10n.string( "Ce modèle ne gère pas la calibration de rotation."),
                isBlocking: true
            ))
        }
        return issues
    }
}
