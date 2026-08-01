import Foundation
import PulsarCatalog

/// Encodage des couleurs de palier DPI.
///
/// Le périphérique conserve trois octets RGB suivis du même checksum de bloc que les
/// autres réglages composés. Une couleur relue avec un checksum faux n'est pas adoptée :
/// elle ne peut pas être distinguée d'une flash partiellement lue.
public struct DPIColorCodec: Sendable {
    public enum CodecError: Error, Equatable, Sendable {
        case invalidBlockLength(expected: Int, actual: Int)
        case invalidChannel(name: String, value: Int)
        case checksumMismatch(expected: UInt8, actual: UInt8)
    }

    public init() {}

    public func encode(_ color: CatalogColor) throws -> [UInt8] {
        let channels: [(String, Int)] = [
            ("red", color.red),
            ("green", color.green),
            ("blue", color.blue),
        ]
        for (name, value) in channels where !(0...255).contains(value) {
            throw CodecError.invalidChannel(name: name, value: value)
        }

        let head = channels.map { UInt8($0.1) }
        return head + [PulsarFrame.blockChecksum(over: head)]
    }

    public func decode(_ block: [UInt8]) throws -> CatalogColor {
        guard block.count == 4 else {
            throw CodecError.invalidBlockLength(expected: 4, actual: block.count)
        }
        let head = Array(block.prefix(3))
        let expected = PulsarFrame.blockChecksum(over: head)
        let actual = block[3]
        guard expected == actual else {
            throw CodecError.checksumMismatch(expected: expected, actual: actual)
        }
        return CatalogColor(red: Int(head[0]), green: Int(head[1]), blue: Int(head[2]))
    }
}

/// Bornes des quatre valeurs scalaires de l'effet lumineux DPI.
///
/// Les valeurs sont les codes réellement stockés dans la flash. La luminosité est
/// présentée par l'interface comme 10...100 %, mais reste encodée sur 0...9 ; la vitesse
/// est volontairement présentée comme un niveau firmware 0...9, car le protocole observé
/// ne documente pas une unité de durée.
public struct DPIEffectCodec: Sendable {
    public enum Field: String, CaseIterable, Sendable {
        case mode
        case brightness
        case speed
        case state
    }

    public enum CodecError: Error, Equatable, Sendable {
        case valueOutOfRange(field: Field, value: Int)
        case invalidRawValue(field: Field, value: UInt8)
    }

    public static let modeRange = 0...2
    public static let brightnessRange = 0...9
    public static let speedRange = 0...9
    public static let stateRange = 0...1

    public static let defaultBrightness = 3
    public static let defaultSpeed = 5

    public init() {}

    public static func range(for field: Field) -> ClosedRange<Int> {
        switch field {
        case .mode: modeRange
        case .brightness: brightnessRange
        case .speed: speedRange
        case .state: stateRange
        }
    }

    public func encode(_ value: Int, for field: Field) throws -> UInt8 {
        guard Self.range(for: field).contains(value) else {
            throw CodecError.valueOutOfRange(field: field, value: value)
        }
        return UInt8(value)
    }

    public func decode(_ raw: UInt8, for field: Field) throws -> Int {
        let value = Int(raw)
        guard Self.range(for: field).contains(value) else {
            throw CodecError.invalidRawValue(field: field, value: raw)
        }
        return value
    }
}
