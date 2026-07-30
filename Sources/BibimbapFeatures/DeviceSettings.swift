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
    public var rotationDegrees: Int = 0
    /// Code brut du délai de veille, conservé sous son ancien nom afin que les profils
    /// JSON déjà exportés restent lisibles. Une unité vaut dix secondes.
    public var sleepMinutes: Int = 6
    public var powerSaveBatteryPercent: Int = 0
    public var longDistance = false
    public var dpiEffect: DPIEffect = DPIEffect()
    public var buttons: [ButtonAssignment] = []
    public var macros: [MacroBinding] = []

    public init() {}

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
        public var brightness: Int = 3
        public var speed: Int = 5
        public var enabled = true

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

        public var id: Int { index }

        public init(index: Int, function: PulsarKeyFunction, parameter: Int) {
            self.index = index
            self.function = function
            self.parameter = parameter
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
            && lhs.battery == rhs.battery
            && lhs.signalStrength == rhs.signalStrength
            && lhs.activeProfile == rhs.activeProfile
            && lhs.settings == rhs.settings
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
    public var availableReportRates: [Int]
    public var maximumStages: Int
    public var buttonCount: Int
    public var maximumDebounce: Int
    public var debounceWarningThreshold: Int
    public var supportsMotionSync: Bool
    public var supportsAngleSnap: Bool
    public var supportsRippleControl: Bool
    public var supportsPerformanceMode: Bool
    public var supportsRotation: Bool
    public var supportsFanMode: Bool
    public var supportsProfiles: Bool
    public var supportsLongDistance: Bool
    public var supportsSignalStrength: Bool
    public var supportsBattery: Bool

    public init(
        family: DeviceFamily,
        catalog: DeviceCatalog,
        connection: PulsarConnectionType,
        supportsProfiles: Bool,
        supportsLongDistance: Bool,
        supportsSignalStrength: Bool
    ) {
        let ranges = catalog.sensorRanges(for: family)
        maximumDPI = min(family.dpi.maximum, ranges?.maximumDPI ?? family.dpi.maximum)
        minimumDPI = ranges?.minimumDPI ?? 50
        availableReportRates = ReportRateCodec.available(
            upTo: min(family.maximumReportRate, connection.maximumReportRate)
        )
        maximumStages = family.dpi.stages.count
        buttonCount = family.buttons.count
        maximumDebounce = family.debounce.maximum
        debounceWarningThreshold = family.debounce.warnAbove
        self.supportsMotionSync = family.sensor.supportsMotionSync
        self.supportsAngleSnap = family.sensor.supportsAngleSnap
        self.supportsRippleControl = family.sensor.supportsRippleControl
        self.supportsPerformanceMode = family.sensor.supportsPerformanceMode
        supportsRotation = family.supportsAngleTune
        supportsFanMode = family.supportsFanMode
        self.supportsProfiles = supportsProfiles
        self.supportsLongDistance = supportsLongDistance && !connection.isWired
        self.supportsSignalStrength = supportsSignalStrength && !connection.isWired
        supportsBattery = !connection.isWired
    }
}
