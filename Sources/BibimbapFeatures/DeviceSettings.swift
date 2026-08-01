import BibimbapLocalization
import Foundation
import PulsarCatalog
import PulsarProtocol

/// Les réglages d'un périphérique, tels que relus depuis la souris.
///
/// C'est la source de vérité : l'application ne conserve jamais un état « supposé »
/// après une écriture, elle relit.
public struct DeviceSettings: Equatable, Sendable, Codable {
    public var reportRateHertz: Int = 1000
    public var dpiStages: [DPIStage] = []
    public var activeStage: Int = 0
    public var enabledStageCount: Int = 6
    public var liftOffMillimetres: Int = 1
    public var debounceMilliseconds: Int = 2
    public var motionSync = false
    public var angleSnap = false
    public var rippleControl = false
    public var performanceMode = false
    public var performanceLevel: Int = 6
    public var sensorMode: Int = 0
    /// Niveau du ventilateur, disponible seulement après validation du modèle et de la
    /// lecture de la case flash correspondante.
    public var fanMode: Int = 0
    public var rotationDegrees: Int = 0
    /// Code brut du délai de veille, conservé sous son ancien nom afin que les profils
    /// JSON déjà exportés restent lisibles. Une unité vaut dix secondes.
    public var sleepMinutes: Int = 6
    public var powerSaveBatteryPercent: Int = 0
    public var longDistance = false
    public var dpiEffect: DPIEffect = DPIEffect()
    /// Réglages hors flash du récepteur. Nil signifie qu'aucun état exploitable n'a été
    /// relu pour cette connexion ; il ne doit alors produire aucune écriture.
    public var receiver: ReceiverSettings?
    public var buttons: [ButtonAssignment] = []
    public var macros: [MacroBinding] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case reportRateHertz, dpiStages, activeStage, enabledStageCount
        case liftOffMillimetres, debounceMilliseconds, motionSync, angleSnap, rippleControl
        case performanceMode, performanceLevel, sensorMode, fanMode, rotationDegrees
        case sleepMinutes, powerSaveBatteryPercent, longDistance, dpiEffect, receiver
        case buttons, macros
    }

    /// Les profils antérieurs à BIB-013 ne contiennent ni `fanMode` ni `receiver`.
    /// Les nouveaux champs sont donc décodés avec une valeur sûre plutôt que de rendre
    /// les sauvegardes historiques illisibles.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reportRateHertz = try values.decodeIfPresent(Int.self, forKey: .reportRateHertz) ?? 1000
        dpiStages = try values.decodeIfPresent([DPIStage].self, forKey: .dpiStages) ?? []
        activeStage = try values.decodeIfPresent(Int.self, forKey: .activeStage) ?? 0
        enabledStageCount = try values.decodeIfPresent(Int.self, forKey: .enabledStageCount) ?? 6
        liftOffMillimetres = try values.decodeIfPresent(Int.self, forKey: .liftOffMillimetres) ?? 1
        debounceMilliseconds = try values.decodeIfPresent(Int.self, forKey: .debounceMilliseconds) ?? 2
        motionSync = try values.decodeIfPresent(Bool.self, forKey: .motionSync) ?? false
        angleSnap = try values.decodeIfPresent(Bool.self, forKey: .angleSnap) ?? false
        rippleControl = try values.decodeIfPresent(Bool.self, forKey: .rippleControl) ?? false
        performanceMode = try values.decodeIfPresent(Bool.self, forKey: .performanceMode) ?? false
        performanceLevel = try values.decodeIfPresent(Int.self, forKey: .performanceLevel) ?? 6
        sensorMode = try values.decodeIfPresent(Int.self, forKey: .sensorMode) ?? 0
        fanMode = try values.decodeIfPresent(Int.self, forKey: .fanMode) ?? 0
        rotationDegrees = try values.decodeIfPresent(Int.self, forKey: .rotationDegrees) ?? 0
        sleepMinutes = try values.decodeIfPresent(Int.self, forKey: .sleepMinutes) ?? 6
        powerSaveBatteryPercent = try values.decodeIfPresent(Int.self, forKey: .powerSaveBatteryPercent) ?? 0
        longDistance = try values.decodeIfPresent(Bool.self, forKey: .longDistance) ?? false
        dpiEffect = try values.decodeIfPresent(DPIEffect.self, forKey: .dpiEffect) ?? DPIEffect()
        receiver = try values.decodeIfPresent(ReceiverSettings.self, forKey: .receiver)
        buttons = try values.decodeIfPresent([ButtonAssignment].self, forKey: .buttons) ?? []
        macros = try values.decodeIfPresent([MacroBinding].self, forKey: .macros) ?? []
    }

    public var sleepTimeCode: Int {
        get { sleepMinutes }
        set { sleepMinutes = newValue }
    }

    /// Valeurs proposées par le configurateur officiel Pulsar.
    public static let supportedSleepTimeCodes = [1, 3, 6, 30, 60, 180]

    public static func sleepTimeLabel(for code: Int) -> String {
        switch code {
        case 1: L10n.string("10 s")
        case 3: L10n.string("30 s")
        case 6: L10n.string("1 min")
        case 30: L10n.string("5 min")
        case 60: L10n.string("10 min")
        case 180: L10n.string("30 min")
        default: L10n.format("Unknown value (%d)", code)
        }
    }

    /// Une macro et son nombre de répétitions, pour un emplacement donné.
    ///
    /// Le firmware réserve un emplacement par bouton. Le compteur de répétitions ne vit
    /// pas dans le bloc macro mais dans le paramètre du bouton, d'où sa présence ici
    /// plutôt que dans `PulsarMacro`.
    public struct MacroBinding: Equatable, Sendable, Codable, Identifiable {
        public var slot: Int
        public var macro: PulsarMacro
        public var repeatCount: Int

        public var id: Int { slot }

        public init(slot: Int, macro: PulsarMacro, repeatCount: Int) {
            self.slot = slot
            self.macro = macro
            self.repeatCount = repeatCount
        }
    }

    public struct DPIStage: Equatable, Sendable, Codable, Identifiable {
        public var index: Int
        public var x: Int
        public var y: Int
        public var color: CatalogColor

        public var id: Int { index }
        /// Vrai quand les deux axes partagent la même valeur, cas courant.
        public var isSymmetric: Bool { x == y }

        public init(index: Int, x: Int, y: Int, color: CatalogColor) {
            self.index = index
            self.x = x
            self.y = y
            self.color = color
        }
    }

    public struct DPIEffect: Equatable, Sendable, Codable {
        public var mode: Mode = .off
        public var brightness: Int = DPIEffectCodec.defaultBrightness
        public var speed: Int = DPIEffectCodec.defaultSpeed
        public var enabled = true

        public static let brightnessRange = DPIEffectCodec.brightnessRange
        public static let speedRange = DPIEffectCodec.speedRange

        public enum Mode: Int, Sendable, Codable, CaseIterable {
            case off = 0
            case steady = 1
            case breathing = 2

            public var label: String {
                switch self {
                case .off: L10n.string( "Éteint")
                case .steady: L10n.string( "Fixe")
                case .breathing: L10n.string( "Respiration")
                }
            }
        }

        public init() {}
    }

    public struct ButtonAssignment: Equatable, Sendable, Codable, Identifiable {
        public var index: Int
        public var function: PulsarKeyFunction
        public var parameter: Int
        /// Bloc de raccourci séparé, présent uniquement pour une fonction clavier.
        /// `nil` signifie que la zone n'a pas pu être relue ou n'est pas affectée.
        public var shortcut: PulsarShortcut?

        public var id: Int { index }

        public init(
            index: Int,
            function: PulsarKeyFunction,
            parameter: Int,
            shortcut: PulsarShortcut? = nil
        ) {
            self.index = index
            self.function = function
            self.parameter = parameter
            self.shortcut = shortcut
        }

        private enum CodingKeys: String, CodingKey {
            case index, function, parameter, shortcut
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            function = try container.decode(PulsarKeyFunction.self, forKey: .function)
            parameter = try container.decode(Int.self, forKey: .parameter)
            // Les profils exportés avant BIB-010 n'ont pas cette clé.
            shortcut = try container.decodeIfPresent(PulsarShortcut.self, forKey: .shortcut)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(index, forKey: .index)
            try container.encode(function, forKey: .function)
            try container.encode(parameter, forKey: .parameter)
            try container.encodeIfPresent(shortcut, forKey: .shortcut)
        }
    }
}

/// Plage de valeurs DPI exposable sans inventer de pas ou de valeurs intermédiaires.
public struct DPIRepresentableRange: Equatable, Sendable {
    public var minimum: Int
    public var maximum: Int
    public var step: Int

    public init(minimum: Int, maximum: Int, step: Int) {
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
    }

    public func nearest(to dpi: Int) -> Int {
        let clamped = min(max(dpi, minimum), maximum)
        let offset = clamped - minimum
        let lower = minimum + (offset / step) * step
        let upper = min(lower + step, maximum)
        return abs(upper - clamped) < abs(clamped - lower) ? upper : lower
    }
}

/// Valeurs lisibles par une personne, indépendantes de l'encodage flash.
///
/// Les plans d'écriture et les archives utilisent cette couche pour ne jamais exposer
/// un code de codec ou un bloc checksummé dans une prévisualisation. Une opération peut
/// donc continuer à être représentée par des octets pour le protocole, tout en restant
/// compréhensible dans l'interface et dans un conflit de brouillon.
public enum DeviceSettingValueFormatter {
    public static func reportRate(_ hertz: Int) -> String {
        hertz >= 1_000 ? "\(hertz / 1_000) kHz" : "\(hertz) Hz"
    }

    public static func dpi(_ stage: DeviceSettings.DPIStage) -> String {
        if stage.x == stage.y {
            return "\(stage.x) DPI"
        }
        return "\(stage.x) × \(stage.y) DPI"
    }

    public static func color(_ color: CatalogColor) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }

    public static func onOff(_ value: Bool) -> String {
        value ? L10n.string("Activé") : L10n.string("Désactivé")
    }

    public static func stageCount(_ count: Int) -> String {
        L10n.format("%d stage(s)", count)
    }

    public static func activeStage(_ index: Int) -> String {
        L10n.format("Stage %d", index + 1)
    }

    public static func button(_ assignment: DeviceSettings.ButtonAssignment) -> String {
        let function: String
        switch assignment.function {
        case .disabled: function = L10n.string("Désactivé")
        case .mouseButton: function = L10n.string("Bouton souris")
        case .dpiSwitch: function = L10n.string("Cycle DPI")
        case .horizontalScroll: function = L10n.string("Défilement horizontal")
        case .rapidFire: function = L10n.string("Tir rapide")
        case .keyboardShortcut: function = L10n.string("Raccourci clavier")
        case .macro: function = L10n.string("Macro")
        case .reportRateSwitch: function = L10n.string("Cycle polling")
        case .lighting: function = L10n.string("Éclairage")
        case .profileSwitch: function = L10n.string("Cycle de profils")
        case .dpiLock: function = L10n.string("Verrouillage DPI")
        case .verticalScroll: function = L10n.string("Défilement vertical")
        }
        guard assignment.parameter != 0 else { return function }
        return L10n.format("%@ (paramètre %@)", function, String(assignment.parameter))
    }

    public static func macro(_ binding: DeviceSettings.MacroBinding) -> String {
        let repetitions = L10n.format("×%d", binding.repeatCount)
        let steps = L10n.format("%d étape(s)", binding.macro.steps.count)
        return "\(binding.macro.name) · \(steps) \(repetitions)"
    }

    /// Retourne la valeur utilisateur correspondant à l'identifiant stable d'une
    /// opération de `WritePlanner`.
    public static func value(for operationID: String, in settings: DeviceSettings) -> String {
        let parts = operationID.split(separator: ".")
        guard let first = parts.first else { return "—" }

        switch first {
        case "dpi":
            switch parts.dropFirst().first {
            case "value":
                guard let index = Int(parts.last ?? ""),
                      let stage = settings.dpiStages.first(where: { $0.index == index }) else {
                    return "—"
                }
                return dpi(stage)
            case "color":
                guard let index = Int(parts.last ?? ""),
                      let stage = settings.dpiStages.first(where: { $0.index == index }) else {
                    return "—"
                }
                return color(stage.color)
            case "count": return stageCount(settings.enabledStageCount)
            case "active": return activeStage(settings.activeStage)
            default: return "—"
            }
        case "perf":
            switch parts.dropFirst().first {
            case "rate": return reportRate(settings.reportRateHertz)
            case "lod": return L10n.format("%d mm", settings.liftOffMillimetres)
            case "debounce": return L10n.format("%d ms", settings.debounceMilliseconds)
            case "motionSync": return onOff(settings.motionSync)
            case "angleSnap": return onOff(settings.angleSnap)
            case "ripple": return onOff(settings.rippleControl)
            case "performanceState": return onOff(settings.performanceMode)
            case "sensorMode": return L10n.format("Mode %d", settings.sensorMode)
            case "rotation": return L10n.format("%d°", settings.rotationDegrees)
            case "rotationState": return onOff(settings.rotationDegrees != 0)
            default: return "—"
            }
        case "light":
            switch parts.dropFirst().first {
            case "mode": return settings.dpiEffect.mode.label
            case "brightness": return L10n.format("Niveau %d", settings.dpiEffect.brightness)
            case "speed": return L10n.format("Niveau %d", settings.dpiEffect.speed)
            case "state": return onOff(settings.dpiEffect.enabled)
            default: return "—"
            }
        case "macro":
            guard let slot = Int(parts.dropFirst().first ?? ""),
                  let binding = settings.macros.first(where: { $0.slot == slot }) else {
                return L10n.string("Aucune macro")
            }
            return macro(binding)
        case "button":
            guard let index = Int(parts.dropFirst().first ?? ""),
                  let assignment = settings.buttons.first(where: { $0.index == index }) else {
                return "—"
            }
            return button(assignment)
        case "power":
            switch parts.dropFirst().first {
            case "sleep", "sleepPerformance":
                return DeviceSettings.sleepTimeLabel(for: settings.sleepTimeCode)
            case "saveBattery": return L10n.format("%d %%", settings.powerSaveBatteryPercent)
            case "longDistance": return onOff(settings.longDistance)
            default: return "—"
            }
        default:
            return "—"
        }
    }
}

/// Photographie complète d'un périphérique connecté.
public struct DeviceSnapshot: Equatable, Sendable {
    public var identity: DeviceIdentity
    public var family: DeviceFamily
    public var productName: String
    public var connection: HIDConnectionSummary
    public var firmwareVersion: String
    public var dongleVersion: String?
    public var dongleLighting: DongleLightingState?
    public var receiverCapabilities: ReceiverCapabilities = .none
    public var flashCapabilities: DeviceFlashCapabilities = DeviceFlashCapabilities()
    public var battery: BatteryState?
    public var signalStrength: Int?
    public var activeProfile: Int?
    public var settings: DeviceSettings

    public static func == (lhs: DeviceSnapshot, rhs: DeviceSnapshot) -> Bool {
        lhs.identity == rhs.identity
            && lhs.productName == rhs.productName
            && lhs.connection == rhs.connection
            && lhs.firmwareVersion == rhs.firmwareVersion
            && lhs.dongleVersion == rhs.dongleVersion
            && lhs.dongleLighting == rhs.dongleLighting
            && lhs.receiverCapabilities == rhs.receiverCapabilities
            && lhs.flashCapabilities == rhs.flashCapabilities
            && lhs.battery == rhs.battery
            && lhs.signalStrength == rhs.signalStrength
            && lhs.activeProfile == rhs.activeProfile
            && lhs.settings == rhs.settings
    }
}

/// Résultat de la présence et de la cohérence des champs avancés de la flash.
///
/// Le catalogue fournit une attente initiale ; la lecture de la flash reste l'autorité
/// pour décider si un champ peut réellement être écrit sur cette connexion.
public struct DeviceFlashCapabilities: Equatable, Sendable {
    public var supportsFanMode: Bool
    public var supportsSensorMode: Bool
    public var supportsPerformanceLevel: Bool

    public init(
        supportsFanMode: Bool = false,
        supportsSensorMode: Bool = false,
        supportsPerformanceLevel: Bool = false
    ) {
        self.supportsFanMode = supportsFanMode
        self.supportsSensorMode = supportsSensorMode
        self.supportsPerformanceLevel = supportsPerformanceLevel
    }
}

public struct HIDConnectionSummary: Equatable, Sendable {
    public var isWired: Bool
    public var maximumReportRate: Int
    public var label: String

    public init(connectionType: PulsarConnectionType) {
        isWired = connectionType.isWired
        maximumReportRate = connectionType.maximumReportRate
        label = connectionType.isWired
            ? L10n.string( "USB")
            : L10n.string( "2,4 GHz")
    }
}

/// Ce qu'un modèle sait faire, dérivé du catalogue et du sondage des commandes.
///
/// L'interface se construit à partir de cet objet : une option absente n'est pas
/// affichée grisée, elle n'est pas affichée du tout.
public struct DeviceCapabilities: Equatable, Sendable {
    public var maximumDPI: Int
    public var minimumDPI: Int
    public var dpiRepresentableRanges: [DPIRepresentableRange]
    public var availableReportRates: [Int]
    public var maximumStages: Int
    /// Nombre de commandes affichées, donc de numéros visibles.
    public var buttonCount: Int
    /// Les index firmware réellement déclarés par le modèle.
    ///
    /// Ils ne forment pas toujours `0..<buttonCount` : un test d'appartenance doit passer
    /// par cet ensemble, jamais par une comparaison au nombre de boutons.
    public var firmwareButtonIndices: Set<Int>
    public var maximumDebounce: Int
    public var debounceWarningThreshold: Int
    public var supportsMotionSync: Bool
    public var supportsAngleSnap: Bool
    public var supportsRippleControl: Bool
    public var supportsPerformanceMode: Bool
    public var supportsRotation: Bool
    public var supportsFanMode: Bool
    public var fanModeOptions: [Int]
    public var supportsSensorMode: Bool
    public var sensorModeOptions: [Int]
    public var supportsPerformanceLevel: Bool
    public var performanceLevelOptions: [Int]
    public var receiver: ReceiverCapabilities
    public var supportsProfiles: Bool
    public var supportsLongDistance: Bool
    public var supportsSignalStrength: Bool
    public var supportsBattery: Bool

    public var supportsDPIEditing: Bool { !dpiRepresentableRanges.isEmpty }

    public var minimumDPIStep: Int {
        dpiRepresentableRanges.map(\.step).min() ?? 1
    }

    /// Valeur la plus proche que le capteur et le plafond du modèle peuvent encoder.
    public func snapDPI(_ dpi: Int) -> Int? {
        guard !dpiRepresentableRanges.isEmpty else { return nil }
        let candidates = dpiRepresentableRanges.map { $0.nearest(to: dpi) }
        return candidates.min { lhs, rhs in
            let leftDistance = abs(lhs - dpi)
            let rightDistance = abs(rhs - dpi)
            return leftDistance == rightDistance ? lhs < rhs : leftDistance < rightDistance
        }
    }

    public init(
        family: DeviceFamily,
        catalog: DeviceCatalog,
        connection: PulsarConnectionType,
        supportsProfiles: Bool,
        supportsLongDistance: Bool,
        supportsSignalStrength: Bool,
        flashCapabilities: DeviceFlashCapabilities = DeviceFlashCapabilities(),
        receiver: ReceiverCapabilities = .none
    ) {
        let ranges = catalog.sensorRanges(for: family)
        let codec = DPICodec(family: family, catalog: catalog)
        dpiRepresentableRanges = codec?.representableRanges(upTo: family.dpi.maximum).map {
            DPIRepresentableRange(minimum: $0.minimum, maximum: $0.maximum, step: $0.step)
        } ?? []
        maximumDPI = dpiRepresentableRanges.last?.maximum ?? min(
            family.dpi.maximum,
            ranges?.maximumDPI ?? family.dpi.maximum
        )
        minimumDPI = dpiRepresentableRanges.first?.minimum ?? ranges?.minimumDPI ?? 50
        availableReportRates = ReportRateCodec.available(
            upTo: min(family.maximumReportRate, connection.maximumReportRate)
        )
        maximumStages = family.dpi.stages.count
        buttonCount = family.buttons.count
        firmwareButtonIndices = family.firmwareButtonIndices
        maximumDebounce = family.debounce.maximum
        debounceWarningThreshold = family.debounce.warnAbove
        self.supportsMotionSync = family.sensor.supportsMotionSync
        self.supportsAngleSnap = family.sensor.supportsAngleSnap
        self.supportsRippleControl = family.sensor.supportsRippleControl
        self.supportsPerformanceMode = family.sensor.supportsPerformanceMode
        supportsRotation = family.supportsAngleTune
        supportsFanMode = family.supportsFanMode && flashCapabilities.supportsFanMode
        fanModeOptions = supportsFanMode ? Array(0...4) : []
        supportsSensorMode = flashCapabilities.supportsSensorMode
            && !connection.isWired
            && connection.maximumReportRate <= 1000
        sensorModeOptions = supportsSensorMode ? [0, 1] : []
        supportsPerformanceLevel = flashCapabilities.supportsPerformanceLevel
        performanceLevelOptions = supportsPerformanceLevel
            ? DeviceSettings.supportedSleepTimeCodes
            : []
        var receiver = receiver
        if !family.supportsFanMode {
            receiver.buttonModeOptions.removeAll { $0 == 8 }
        }
        self.receiver = receiver
        self.supportsProfiles = supportsProfiles
        self.supportsLongDistance = supportsLongDistance && !connection.isWired
        self.supportsSignalStrength = supportsSignalStrength && !connection.isWired
        supportsBattery = !connection.isWired
    }
}
