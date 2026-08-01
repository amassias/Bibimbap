import Foundation
import PulsarCatalog

/// Effet lumineux paramétrable du récepteur.
///
/// Les valeurs restent brutes afin de conserver une valeur relue même si une version
/// future du firmware introduit un nouveau mode. L'interface ne propose que les modes
/// qu'elle sait encoder ; une valeur inconnue n'est jamais remplacée silencieusement.
public struct ReceiverLightEffect: Hashable, Sendable, Codable {
    public var mode: Int
    public var color: CatalogColor
    public var speed: Int
    public var brightness: Int
    public var duration: Int

    public init(
        mode: Int = 0,
        color: CatalogColor = CatalogColor(red: 255, green: 255, blue: 255),
        speed: Int = 5,
        brightness: Int = 9,
        duration: Int = 0
    ) {
        self.mode = mode
        self.color = color
        self.speed = speed
        self.brightness = brightness
        self.duration = duration
    }

    public var payload: [UInt8] {
        [
            UInt8(clamping: mode),
            UInt8(clamping: color.red),
            UInt8(clamping: color.green),
            UInt8(clamping: color.blue),
            UInt8(clamping: speed),
            UInt8(clamping: brightness),
            UInt8(clamping: duration),
        ]
    }

    public static let supportedModes = Array(0...6)
    public static let supportedLevels = Array(0...9)
}

/// Fonction programmée sur un bouton physique du récepteur.
public struct ReceiverButtonFunction: Hashable, Sendable, Codable, Identifiable {
    public var index: Int
    public var mode: Int
    public var color: CatalogColor
    public var speed: Int
    public var brightness: Int
    public var duration: Int

    public var id: Int { index }

    public init(
        index: Int,
        mode: Int,
        color: CatalogColor = CatalogColor(red: 255, green: 255, blue: 255),
        speed: Int = 5,
        brightness: Int = 9,
        duration: Int = 0
    ) {
        self.index = index
        self.mode = mode
        self.color = color
        self.speed = speed
        self.brightness = brightness
        self.duration = duration
    }

    public var payload: [UInt8] {
        [
            UInt8(clamping: index),
            UInt8(clamping: mode),
            UInt8(clamping: color.red),
            UInt8(clamping: color.green),
            UInt8(clamping: color.blue),
            UInt8(clamping: speed),
            UInt8(clamping: brightness),
            UInt8(clamping: duration),
        ]
    }
}

/// Variante de la commande de bouton exposée par le récepteur.
public enum ReceiverButtonModeKind: String, Hashable, Sendable, Codable {
    case keyFunction
    case oButton

    public var getCommand: PulsarCommand {
        switch self {
        case .keyFunction: .getPulsarDongleKeyFunction
        case .oButton: .getPulsarDongleOButtonCurrentMode
        }
    }

    public var setCommand: PulsarCommand {
        switch self {
        case .keyFunction: .setPulsarDongleKeyFunction
        case .oButton: .setPulsarDongleOButtonCurrentMode
        }
    }
}

/// Capacités réellement sondées sur un récepteur précis.
public struct ReceiverCapabilities: Hashable, Sendable, Codable {
    public var supportsRGBLighting: Bool
    public var supportsEffect: Bool
    public var supportsDPILighting: Bool
    public var buttonModeKind: ReceiverButtonModeKind?
    public var buttonModeOptions: [Int]
    public var buttonFunctionSlots: [Int]

    public init(
        supportsRGBLighting: Bool = false,
        supportsEffect: Bool = false,
        supportsDPILighting: Bool = false,
        buttonModeKind: ReceiverButtonModeKind? = nil,
        buttonModeOptions: [Int] = [],
        buttonFunctionSlots: [Int] = []
    ) {
        self.supportsRGBLighting = supportsRGBLighting
        self.supportsEffect = supportsEffect
        self.supportsDPILighting = supportsDPILighting
        self.buttonModeKind = buttonModeKind
        self.buttonModeOptions = buttonModeOptions
        self.buttonFunctionSlots = buttonFunctionSlots
    }

    public static let none = ReceiverCapabilities()

    public var supportsButtonMode: Bool { buttonModeKind != nil }
    public var supportsButtonFunctions: Bool { !buttonFunctionSlots.isEmpty }
}

/// Réglages du récepteur obtenus par les getters correspondants.
public struct ReceiverSettings: Hashable, Sendable, Codable {
    public var rgbLighting: DongleLightingState?
    public var effect: ReceiverLightEffect?
    public var dpiLightEnabled: Bool?
    public var buttonMode: Int?
    public var buttonFunctions: [ReceiverButtonFunction]

    public init(
        rgbLighting: DongleLightingState? = nil,
        effect: ReceiverLightEffect? = nil,
        dpiLightEnabled: Bool? = nil,
        buttonMode: Int? = nil,
        buttonFunctions: [ReceiverButtonFunction] = []
    ) {
        self.rgbLighting = rgbLighting
        self.effect = effect
        self.dpiLightEnabled = dpiLightEnabled
        self.buttonMode = buttonMode
        self.buttonFunctions = buttonFunctions
    }
}

/// Résultat d'un sondage groupé, séparant l'état relu des capacités utilisables par l'UI.
public struct ReceiverReadback: Hashable, Sendable {
    public var settings: ReceiverSettings
    public var capabilities: ReceiverCapabilities

    public init(settings: ReceiverSettings, capabilities: ReceiverCapabilities) {
        self.settings = settings
        self.capabilities = capabilities
    }
}

extension PulsarSession {
    /// Lit l'effet lumineux avancé du récepteur.
    public func readReceiverEffect() async throws -> ReceiverLightEffect? {
        guard let response = await probe(PulsarFrame(command: .getPulsarDongleLightParam)) else {
            return nil
        }
        guard response.payload.count >= 7 else { return nil }
        return ReceiverLightEffect(
            mode: Int(response[byte: 5]),
            color: CatalogColor(
                red: Int(response[byte: 6]),
                green: Int(response[byte: 7]),
                blue: Int(response[byte: 8])
            ),
            speed: Int(response[byte: 9]),
            brightness: Int(response[byte: 10]),
            duration: Int(response[byte: 11])
        )
    }

    public func setReceiverEffect(_ effect: ReceiverLightEffect) async throws {
        try await request(PulsarFrame(command: .setPulsarDongleLightParam, payload: effect.payload))
    }

    public func readReceiverDPILight() async throws -> Bool? {
        guard let response = await probe(PulsarFrame(command: .getPulsarDongleDPILightParam)) else {
            return nil
        }
        guard !response.payload.isEmpty else { return nil }
        return response[byte: 5] == 1
    }

    public func setReceiverDPILight(enabled: Bool) async throws {
        try await request(PulsarFrame(
            command: .setPulsarDongleDPILightParam,
            payload: [enabled ? 1 : 0]
        ))
    }

    public func readReceiverButtonMode(kind: ReceiverButtonModeKind) async throws -> Int? {
        guard let response = await probe(PulsarFrame(command: kind.getCommand)) else { return nil }
        guard !response.payload.isEmpty else { return nil }
        return Int(response[byte: 5])
    }

    public func setReceiverButtonMode(_ mode: Int, kind: ReceiverButtonModeKind) async throws {
        try await request(PulsarFrame(
            command: kind.setCommand,
            payload: [UInt8(clamping: mode)]
        ))
    }

    public func readReceiverButtonFunction(index: Int) async throws -> ReceiverButtonFunction? {
        guard let response = await probe(PulsarFrame(
            command: .getPulsarDongleOButtonFunction,
            payload: [UInt8(clamping: index)]
        )) else { return nil }
        guard response.payload.count >= 8, Int(response[byte: 5]) == index else { return nil }
        return ReceiverButtonFunction(
            index: index,
            mode: Int(response[byte: 6]),
            color: CatalogColor(
                red: Int(response[byte: 7]),
                green: Int(response[byte: 8]),
                blue: Int(response[byte: 9])
            ),
            speed: Int(response[byte: 10]),
            brightness: Int(response[byte: 11]),
            duration: Int(response[byte: 12])
        )
    }

    public func setReceiverButtonFunction(_ function: ReceiverButtonFunction) async throws {
        try await request(PulsarFrame(
            command: .setPulsarDongleOButtonFunction,
            payload: function.payload
        ))
    }

    /// Sonde uniquement les familles de commandes cohérentes avec le type de récepteur.
    /// Une commande refusée est absente du résultat : elle ne pourra donc pas atteindre l'UI.
    public func readReceiverSettings(dongleType: Int) async -> ReceiverReadback {
        var settings = ReceiverSettings()
        var capabilities = ReceiverCapabilities()

        if let rgb = try? await readDongleLighting() {
            settings.rgbLighting = rgb
            capabilities.supportsRGBLighting = true
        }

        if dongleType > 0, let effect = try? await readReceiverEffect() {
            settings.effect = effect
            capabilities.supportsEffect = true
        }

        if dongleType > 0, let dpi = try? await readReceiverDPILight() {
            settings.dpiLightEnabled = dpi
            capabilities.supportsDPILighting = true
        }

        let buttonKind: ReceiverButtonModeKind?
        switch dongleType {
        case 2, 4: buttonKind = .keyFunction
        case 1: buttonKind = .oButton
        default: buttonKind = nil
        }
        if let buttonKind, let mode = try? await readReceiverButtonMode(kind: buttonKind) {
            settings.buttonMode = mode
            capabilities.buttonModeKind = buttonKind
            capabilities.buttonModeOptions = buttonKind == .keyFunction
                ? Array(0...8)
                : Array(0...6)
        }

        if dongleType == 1 {
            for index in 0..<4 {
                if let function = try? await readReceiverButtonFunction(index: index) {
                    settings.buttonFunctions.append(function)
                    capabilities.buttonFunctionSlots.append(index)
                }
            }
        }

        return ReceiverReadback(settings: settings, capabilities: capabilities)
    }
}
