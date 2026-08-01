import Foundation

/// Représentation typée du paramètre associé à une fonction de bouton.
///
/// Le firmware stocke toujours un entier 16 bits, mais chaque fonction lui donne un
/// sens différent. Garder cette distinction dans le codec empêche l'interface de
/// proposer un champ générique qui pourrait écrire une valeur non supportée.
public enum PulsarButtonParameter: Equatable, Sendable, Hashable {
    public enum DPISwitchMode: Int, CaseIterable, Sendable, Hashable {
        case cycle = 0x0100
        case next = 0x0200
        case previous = 0x0300

        public var label: String {
            switch self {
            case .cycle: "Cycle DPI"
            case .next: "Palier DPI suivant"
            case .previous: "Palier DPI précédent"
            }
        }
    }

    public enum ScrollDirection: Int, CaseIterable, Sendable, Hashable {
        case positive = 0x0100
        case negative = 0x0200

        public var label: String {
            switch self {
            case .positive: "Défilement positif"
            case .negative: "Défilement négatif"
            }
        }
    }

    case disabled
    case mouseButton(PulsarMacro.MouseButtonMask)
    case dpiSwitch(DPISwitchMode)
    case horizontalScroll(ScrollDirection)
    case rapidFire(times: Int, intervalMilliseconds: Int)
    case keyboardShortcut
    case macro(slot: Int, repeatCount: Int)
    case reportRateSwitch
    case lighting
    case profileSwitch
    case dpiLock(Int)
    case verticalScroll(ScrollDirection)
    /// Fonction connue mais paramètre non représentable par les règles ci-dessus.
    case unknown(Int)
}

/// Encode et valide les paramètres de fonctions de bouton.
public enum ButtonParameterCodec {
    public enum CodecError: Error, Equatable, Sendable {
        case invalidParameter(function: PulsarKeyFunction, parameter: Int)
        case invalidMouseButton(Int)
        case invalidDPI(Int)
        case invalidRapidFire(times: Int, intervalMilliseconds: Int)
        case invalidMacroRepeat(Int)
    }

    public static func decode(
        function: PulsarKeyFunction,
        parameter: Int
    ) -> PulsarButtonParameter {
        guard (0...0xFFFF).contains(parameter) else { return .unknown(parameter) }

        switch function {
        case .disabled:
            return parameter == 0 ? .disabled : .unknown(parameter)
        case .mouseButton:
            guard parameter & 0x00FF == 0,
                  let mask = PulsarMacro.MouseButtonMask(rawValue: parameter >> 8)
            else { return .unknown(parameter) }
            return .mouseButton(mask)
        case .dpiSwitch:
            guard let mode = PulsarButtonParameter.DPISwitchMode(rawValue: parameter) else {
                return .unknown(parameter)
            }
            return .dpiSwitch(mode)
        case .horizontalScroll:
            guard let direction = PulsarButtonParameter.ScrollDirection(rawValue: parameter) else {
                return .unknown(parameter)
            }
            return .horizontalScroll(direction)
        case .rapidFire:
            let times = parameter & 0x00FF
            let interval = parameter >> 8
            guard (0...3).contains(times), (10...255).contains(interval) else {
                return .unknown(parameter)
            }
            return .rapidFire(times: times, intervalMilliseconds: interval)
        case .keyboardShortcut:
            return parameter == 0 ? .keyboardShortcut : .unknown(parameter)
        case .macro:
            let repeatCount = parameter & 0x00FF
            return (1...255).contains(repeatCount)
                ? .macro(slot: parameter >> 8, repeatCount: repeatCount)
                : .unknown(parameter)
        case .reportRateSwitch:
            return parameter == 0 ? .reportRateSwitch : .unknown(parameter)
        case .lighting:
            return parameter == 0 ? .lighting : .unknown(parameter)
        case .profileSwitch:
            return parameter == 0 ? .profileSwitch : .unknown(parameter)
        case .dpiLock:
            return (1...0xFFFF).contains(parameter) ? .dpiLock(parameter) : .unknown(parameter)
        case .verticalScroll:
            guard let direction = PulsarButtonParameter.ScrollDirection(rawValue: parameter) else {
                return .unknown(parameter)
            }
            return .verticalScroll(direction)
        }
    }

    public static func encode(_ parameter: PulsarButtonParameter) throws -> Int {
        switch parameter {
        case .disabled:
            return 0
        case .mouseButton(let mask):
            return mask.rawValue << 8
        case .dpiSwitch(let mode):
            return mode.rawValue
        case .horizontalScroll(let direction), .verticalScroll(let direction):
            return direction.rawValue
        case .rapidFire(let times, let intervalMilliseconds):
            guard (0...3).contains(times), (10...255).contains(intervalMilliseconds) else {
                throw CodecError.invalidRapidFire(
                    times: times,
                    intervalMilliseconds: intervalMilliseconds
                )
            }
            return intervalMilliseconds << 8 | times
        case .keyboardShortcut, .reportRateSwitch, .lighting, .profileSwitch:
            return 0
        case .macro(let slot, let repeatCount):
            guard (0...255).contains(slot), (1...255).contains(repeatCount) else {
                throw CodecError.invalidMacroRepeat(repeatCount)
            }
            return slot << 8 | repeatCount
        case .dpiLock(let dpi):
            guard (1...0xFFFF).contains(dpi) else { throw CodecError.invalidDPI(dpi) }
            return dpi
        case .unknown(let raw):
            throw CodecError.invalidParameter(function: .disabled, parameter: raw)
        }
    }

    /// Vérifie un entier brut sans le convertir en une valeur destinée à l'interface.
    public static func validate(
        function: PulsarKeyFunction,
        parameter: Int
    ) throws {
        switch decode(function: function, parameter: parameter) {
        case .unknown:
            throw CodecError.invalidParameter(function: function, parameter: parameter)
        case .mouseButton(let mask):
            guard mask.rawValue << 8 == parameter else {
                throw CodecError.invalidMouseButton(parameter)
            }
        default:
            _ = try encode(decoded: function, parameter: parameter)
        }
    }

    private static func encode(
        decoded function: PulsarKeyFunction,
        parameter: Int
    ) throws -> Int {
        switch function {
        case .disabled:
            guard parameter == 0 else { throw CodecError.invalidParameter(function: function, parameter: parameter) }
        case .mouseButton:
            guard parameter & 0x00FF == 0,
                  PulsarMacro.MouseButtonMask(rawValue: parameter >> 8) != nil
            else { throw CodecError.invalidMouseButton(parameter) }
        case .dpiSwitch:
            guard PulsarButtonParameter.DPISwitchMode(rawValue: parameter) != nil else {
                throw CodecError.invalidParameter(function: function, parameter: parameter)
            }
        case .horizontalScroll, .verticalScroll:
            guard PulsarButtonParameter.ScrollDirection(rawValue: parameter) != nil else {
                throw CodecError.invalidParameter(function: function, parameter: parameter)
            }
        case .rapidFire:
            let times = parameter & 0xFF
            let interval = parameter >> 8
            guard (0...3).contains(times), (10...255).contains(interval) else {
                throw CodecError.invalidRapidFire(times: times, intervalMilliseconds: interval)
            }
        case .keyboardShortcut, .reportRateSwitch, .lighting, .profileSwitch:
            guard parameter == 0 else { throw CodecError.invalidParameter(function: function, parameter: parameter) }
        case .macro:
            guard (0...255).contains(parameter >> 8),
                  (1...255).contains(parameter & 0xFF) else {
                throw CodecError.invalidMacroRepeat(parameter & 0xFF)
            }
        case .dpiLock:
            guard (1...0xFFFF).contains(parameter) else { throw CodecError.invalidDPI(parameter) }
        }
        guard (0...0xFFFF).contains(parameter) else {
            throw CodecError.invalidParameter(function: function, parameter: parameter)
        }
        return parameter
    }
}
