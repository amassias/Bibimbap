import Foundation
import PulsarCatalog

/// Conversion entre DPI affiché et représentation brute en flash.
///
/// Un palier est stocké comme une valeur brute plus un code d'exposant sur deux bits.
/// Le code sélectionne un facteur d'échelle qui permet de couvrir 10 à 32000 DPI (ou
/// 42000 pour le 3955) avec un octet et demi de résolution.
///
/// ```
/// dpi = (brut + 1) × pas₀   puis  ×5 +10000 si bit 1   puis  ×2 si bit 0
/// ```
///
/// La branche `×5 + 10000` est propre à la famille `pulsar x1` ; les autres capteurs
/// appliquent un simple `×2`.
public struct DPICodec: Sendable {
    public let sensorType: String
    public let ranges: SensorRanges

    public init(sensorType: String, ranges: SensorRanges) {
        self.sensorType = sensorType
        self.ranges = ranges
    }

    public init?(family: DeviceFamily, catalog: DeviceCatalog) {
        guard let ranges = catalog.sensorRanges(for: family) else { return nil }
        self.init(sensorType: family.sensor.type, ranges: ranges)
    }

    public enum CodecError: Error, Equatable, Sendable {
        case unsupportedSensor(String)
        case dpiOutOfRange(Int)
        case noRangeForExponent(UInt8)
        case invalidBlockLength(expected: Int, actual: Int)
        case checksumMismatch(expected: UInt8, actual: UInt8)
    }

    /// Une plage continue de valeurs que le capteur sait réellement représenter.
    public struct RepresentableRange: Equatable, Sendable {
        public var minimum: Int
        public var maximum: Int
        public var step: Int

        public init(minimum: Int, maximum: Int, step: Int) {
            self.minimum = minimum
            self.maximum = maximum
            self.step = step
        }

        public var count: Int {
            guard maximum >= minimum, step > 0 else { return 0 }
            return (maximum - minimum) / step + 1
        }

        public func nearest(to dpi: Int) -> Int {
            let clamped = min(max(dpi, minimum), maximum)
            let offset = clamped - minimum
            let lower = minimum + (offset / step) * step
            let upper = min(lower + step, maximum)
            let lowerDistance = abs(clamped - lower)
            let upperDistance = abs(upper - clamped)
            // Keep the historical round-half-up behaviour used by the firmware
            // controls: an exact midpoint must select the next representable
            // value, not the lower one.
            return upperDistance <= lowerDistance ? upper : lower
        }
    }

    private var usesPulsarX1Scaling: Bool { sensorType == "pulsar x1" }

    /// Vrai si les paliers occupent 6 octets au lieu de 4, dans la zone dédiée.
    public var usesExtendedBlock: Bool { sensorType == "3955" }

    private var baseStep: Int { ranges.ranges.first?.step ?? 1 }

    // MARK: Conversions scalaires

    /// DPI affiché correspondant à une valeur brute et son code d'exposant.
    public func dpi(raw: Int, exponentCode: UInt8) throws -> Int {
        guard !ranges.hasLookupTable else {
            throw CodecError.unsupportedSensor(sensorType)
        }
        guard ranges.range(forExponentCode: exponentCode) != nil else {
            throw CodecError.noRangeForExponent(exponentCode)
        }
        var value = (raw + 1) * baseStep
        if exponentCode & 0b10 != 0 {
            value = usesPulsarX1Scaling ? value * 5 + 10_000 : value * 2
        }
        if exponentCode & 0b01 != 0 {
            value *= 2
        }
        return value
    }

    /// Valeur brute et code d'exposant pour un DPI donné.
    ///
    /// Le DPI est d'abord ramené au pas de sa plage : le matériel ne sait pas
    /// représenter une valeur intermédiaire, et l'accepter silencieusement ferait
    /// diverger l'affichage de l'état réel après relecture.
    public func raw(dpi: Int) throws -> (raw: Int, exponentCode: UInt8) {
        guard !ranges.hasLookupTable else {
            throw CodecError.unsupportedSensor(sensorType)
        }
        let snapped = try snap(dpi: dpi)
        guard let range = ranges.range(containing: snapped) else {
            throw CodecError.dpiOutOfRange(dpi)
        }
        let code = range.exponentCode
        var value = snapped
        if code & 0b01 != 0 { value /= 2 }
        if code & 0b10 != 0 {
            value = usesPulsarX1Scaling ? (value - 10_000) / 5 : value / 2
        }
        return (value / baseStep - 1, code)
    }

    /// Arrondit un DPI à la valeur représentable la plus proche.
    public func snap(dpi: Int) throws -> Int {
        try snap(dpi: dpi, upTo: nil)
    }

    /// Arrondit à une valeur représentable sans dépasser le plafond du modèle.
    public func snap(dpi: Int, upTo maximum: Int?) throws -> Int {
        let available = representableRanges(upTo: maximum)
        guard !available.isEmpty else {
            throw CodecError.unsupportedSensor(sensorType)
        }

        let candidates = available.map { $0.nearest(to: dpi) }
        return candidates.min { lhs, rhs in
            let leftDistance = abs(lhs - dpi)
            let rightDistance = abs(rhs - dpi)
            return leftDistance == rightDistance ? lhs < rhs : leftDistance < rightDistance
        } ?? available[0].minimum
    }

    /// Toutes les valeurs représentables, pour alimenter un pas de curseur cohérent.
    public var representableCount: Int {
        representableRanges.reduce(0) { $0 + $1.count }
    }

    /// Plages continues exposables à l'interface, éventuellement tronquées au plafond
    /// déclaré par la famille de périphérique.
    public var representableRanges: [RepresentableRange] {
        representableRanges(upTo: nil)
    }

    public func representableRanges(upTo maximum: Int?) -> [RepresentableRange] {
        guard !ranges.hasLookupTable else { return [] }
        return ranges.ranges.compactMap { range in
            guard range.step > 0 else { return nil }
            guard let maximum else {
                return RepresentableRange(
                    minimum: range.minimum,
                    maximum: range.maximum,
                    step: range.step
                )
            }

            guard range.minimum <= maximum else { return nil }
            let clippedMaximum = min(range.maximum, maximum)
            let alignedMaximum = range.minimum
                + ((clippedMaximum - range.minimum) / range.step) * range.step
            return RepresentableRange(
                minimum: range.minimum,
                maximum: alignedMaximum,
                step: range.step
            )
        }
    }

    // MARK: Blocs de flash

    /// Encode un palier X/Y en bloc prêt à écrire.
    public func encodeStage(x: Int, y: Int) throws -> [UInt8] {
        let xEncoded = try raw(dpi: x)
        let yEncoded = try raw(dpi: y)

        var block: [UInt8]
        if usesExtendedBlock {
            block = [
                UInt8(truncatingIfNeeded: xEncoded.raw),
                UInt8(truncatingIfNeeded: xEncoded.raw >> 8),
                UInt8(truncatingIfNeeded: yEncoded.raw),
                UInt8(truncatingIfNeeded: yEncoded.raw >> 8),
                attributes(x: xEncoded, y: yEncoded, highShift: 16),
                0,
            ]
        } else {
            block = [
                UInt8(truncatingIfNeeded: xEncoded.raw),
                UInt8(truncatingIfNeeded: yEncoded.raw),
                attributes(x: xEncoded, y: yEncoded, highShift: 8),
                0,
            ]
        }
        block[block.count - 1] = PulsarFrame.blockChecksum(over: block.dropLast())
        return block
    }

    private func attributes(
        x: (raw: Int, exponentCode: UInt8),
        y: (raw: Int, exponentCode: UInt8),
        highShift: Int
    ) -> UInt8 {
        let xHigh = UInt8(truncatingIfNeeded: x.raw >> highShift) & 0b11
        let yHigh = UInt8(truncatingIfNeeded: y.raw >> highShift) & 0b11
        return (xHigh << 2) | (yHigh << 6) | x.exponentCode | (y.exponentCode << 4)
    }

    /// Décode un palier depuis un bloc lu en flash.
    public func decodeStage(_ block: [UInt8]) throws -> (x: Int, y: Int) {
        let expected = usesExtendedBlock ? 6 : 4
        guard block.count >= expected else {
            throw CodecError.invalidBlockLength(expected: expected, actual: block.count)
        }
        let expectedChecksum = PulsarFrame.blockChecksum(over: block.prefix(expected - 1))
        let actualChecksum = block[expected - 1]
        guard expectedChecksum == actualChecksum else {
            throw CodecError.checksumMismatch(expected: expectedChecksum, actual: actualChecksum)
        }
        let attributes = block[usesExtendedBlock ? 4 : 2]
        let xCode = attributes & 0b11
        let yCode = (attributes >> 4) & 0b11
        let xHigh = Int((attributes >> 2) & 0b11)
        let yHigh = Int((attributes >> 6) & 0b11)

        let xRaw: Int
        let yRaw: Int
        if usesExtendedBlock {
            xRaw = Int(block[0]) | Int(block[1]) << 8 | xHigh << 16
            yRaw = Int(block[2]) | Int(block[3]) << 8 | yHigh << 16
        } else {
            xRaw = Int(block[0]) | xHigh << 8
            yRaw = Int(block[1]) | yHigh << 8
        }
        return (try dpi(raw: xRaw, exponentCode: xCode), try dpi(raw: yRaw, exponentCode: yCode))
    }
}

/// Correspondance entre la valeur stockée pour le polling et sa fréquence en Hz.
///
/// Jusqu'à 1 kHz, l'octet porte un diviseur de 1000 : 125 Hz → 8, 500 Hz → 2, 1 kHz → 1.
/// Au-delà, il porte `hz / 125` : 2 kHz → 16, 4 kHz → 32, 8 kHz → 64.
///
/// - Note: le bundle officiel expose deux encodeurs contradictoires. Celui qui est
///   réellement appelé avant l'écriture flash utilise `hz / 2000 × 16`, et son décodeur
///   `code / 16 × 2000` en est l'inverse exact. L'autre, exporté mais jamais appelé,
///   écrirait `hz / 1000 × 16` — le double. C'est le premier qui est repris ici.
public enum ReportRateCodec {
    private static let supported = [125, 250, 500, 1000, 2000, 4000, 8000]

    public static func code(from hertz: Int) -> UInt8? {
        guard supported.contains(hertz) else { return nil }
        let code = hertz > 1000 ? hertz / 125 : 1000 / hertz
        return UInt8(exactly: code)
    }

    public static func hertz(from code: UInt8) -> Int? {
        guard code > 0 else { return nil }
        let hertz = code >= 16 ? Int(code) * 125 : 1000 / Int(code)
        return supported.contains(hertz) ? hertz : nil
    }

    /// Cadences proposables pour un maximum matériel donné.
    public static func available(upTo maximum: Int) -> [Int] {
        supported.filter { $0 <= maximum }
    }
}
