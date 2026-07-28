import Foundation

/// Adresses de la flash de configuration.
///
/// La zone `0x0000..<0x0100` est lue en bloc à la connexion ; les raccourcis, macros et
/// paliers DPI étendus vivent au-delà et sont lus à la demande.
public enum FlashMap {
    public static let reportRate: UInt16 = 0
    public static let maxDPIStage: UInt16 = 2
    public static let currentDPI: UInt16 = 4
    public static let liftOffDistance: UInt16 = 10
    public static let dpiValue: UInt16 = 12
    public static let dpiColor: UInt16 = 44
    public static let dpiEffectMode: UInt16 = 76
    public static let dpiEffectBrightness: UInt16 = 78
    public static let dpiEffectSpeed: UInt16 = 80
    public static let dpiEffectState: UInt16 = 82
    public static let keyFunction: UInt16 = 96
    public static let light: UInt16 = 160
    public static let debounceTime: UInt16 = 169
    public static let motionSync: UInt16 = 171
    public static let sleepTime: UInt16 = 173
    public static let angleSnap: UInt16 = 175
    public static let rippleControl: UInt16 = 177
    public static let movingOffLight: UInt16 = 179
    public static let performanceState: UInt16 = 181
    public static let performance: UInt16 = 183
    public static let sensorMode: UInt16 = 185
    public static let angleTune: UInt16 = 189
    public static let angleTuneState: UInt16 = 191
    public static let powerSaveBattery: UInt16 = 215
    public static let powerSaveTime: UInt16 = 217
    public static let fanMode: UInt16 = 231
    public static let shortcutKey: UInt16 = 256
    public static let macro: UInt16 = 768
    public static let sensor3955DPI: UInt16 = 6912

    /// Étendue lue systématiquement à la connexion.
    public static let coreRegion: Range<UInt16> = 0..<256

    public static let dpiStageStride = 4
    public static let extendedDPIStageStride = 6
    public static let dpiColorStride = 4
    public static let keyFunctionStride = 4
    public static let shortcutStride = 32
    public static let macroStride = 384
    /// Longueur de l'en-tête d'un bloc macro : longueur du nom, nom, nombre d'étapes.
    public static let macroHeaderLength = 32
    public static let macroNameCapacity = 30
    public static let macroStepLength = 5

    public static func dpiValue(stage: Int, extended: Bool) -> UInt16 {
        extended
            ? sensor3955DPI + UInt16(extendedDPIStageStride * stage)
            : dpiValue + UInt16(dpiStageStride * stage)
    }

    public static func dpiColor(stage: Int) -> UInt16 {
        dpiColor + UInt16(dpiColorStride * stage)
    }

    public static func keyFunction(button: Int) -> UInt16 {
        keyFunction + UInt16(keyFunctionStride * button)
    }

    public static func shortcut(slot: Int) -> UInt16 {
        shortcutKey + UInt16(shortcutStride * slot)
    }

    public static func macro(slot: Int) -> UInt16 {
        macro + UInt16(macroStride * slot)
    }
}

/// Un réglage scalaire, stocké sur deux octets : la valeur puis son complément à `0x55`.
public struct ScalarSetting: Hashable, Sendable {
    public var address: UInt16
    public var value: UInt8

    public init(address: UInt16, value: UInt8) {
        self.address = address
        self.value = value
    }

    public var encoded: [UInt8] {
        [value, PulsarFrame.blockChecksum(over: [value])]
    }

    /// Relit un réglage scalaire depuis une image de flash.
    ///
    /// Renvoie `nil` si l'octet de contrôle ne correspond pas : la flash est alors
    /// soit corrompue, soit pas encore initialisée pour ce réglage.
    public static func decode(from flash: FlashImage, at address: UInt16) -> UInt8? {
        guard let value = flash[address], let check = flash[address + 1] else { return nil }
        guard PulsarFrame.blockChecksum(over: [value]) == check else { return nil }
        return value
    }
}

/// Image de la flash de configuration lue depuis le périphérique.
///
/// `0xFF` marque une case jamais lue, comme le fait le configurateur officiel qui
/// pré-remplit son tampon avant la lecture initiale.
public struct FlashImage: Sendable, Equatable {
    public static let unwritten: UInt8 = 0xFF
    public static let capacity = 8192

    private var bytes: [UInt8]

    public init() {
        bytes = [UInt8](repeating: Self.unwritten, count: Self.capacity)
    }

    public subscript(address: UInt16) -> UInt8? {
        get {
            let index = Int(address)
            guard index < bytes.count else { return nil }
            return bytes[index]
        }
        set {
            let index = Int(address)
            guard index < bytes.count, let newValue else { return }
            bytes[index] = newValue
        }
    }

    public func slice(at address: UInt16, count: Int) -> [UInt8] {
        let start = Int(address)
        let end = min(start + count, bytes.count)
        guard start < end else { return [] }
        return Array(bytes[start..<end])
    }

    public mutating func write(_ data: [UInt8], at address: UInt16) {
        for (offset, byte) in data.enumerated() {
            let index = Int(address) + offset
            guard index < bytes.count else { break }
            bytes[index] = byte
        }
    }
}
