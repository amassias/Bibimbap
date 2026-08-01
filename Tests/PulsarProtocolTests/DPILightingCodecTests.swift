import Testing
@testable import PulsarCatalog
@testable import PulsarProtocol

@Suite("Codecs couleur et effet DPI")
struct DPILightingCodecTests {
    @Test("Une couleur s'encode avec son checksum puis se relit")
    func colorRoundTrip() throws {
        let color = CatalogColor(red: 12, green: 128, blue: 250)
        let block = try DPIColorCodec().encode(color)

        #expect(block.count == 4)
        #expect(PulsarFrame.blockChecksum(over: block.dropLast()) == block.last)
        #expect(try DPIColorCodec().decode(block) == color)
    }

    @Test("Une couleur dont le checksum est faux est refusée")
    func colorChecksumIsRequired() throws {
        var block = try DPIColorCodec().encode(CatalogColor(red: 1, green: 2, blue: 3))
        block[3] &+= 1

        #expect(throws: DPIColorCodec.CodecError.checksumMismatch(
            expected: PulsarFrame.blockChecksum(over: block.dropLast()),
            actual: block[3]
        )) {
            _ = try DPIColorCodec().decode(block)
        }
    }

    @Test("Les niveaux d'effet ont des bornes et un round-trip de code")
    func effectLevelsRoundTrip() throws {
        let codec = DPIEffectCodec()
        for field in DPIEffectCodec.Field.allCases {
            let range = DPIEffectCodec.range(for: field)
            for value in [range.lowerBound, range.upperBound] {
                let raw = try codec.encode(value, for: field)
                #expect(try codec.decode(raw, for: field) == value)
            }
        }
    }

    @Test("Les niveaux d'effet hors bornes ne sont jamais encodés")
    func effectLevelsRejectInvalidValues() {
        let codec = DPIEffectCodec()
        #expect(throws: DPIEffectCodec.CodecError.valueOutOfRange(
            field: .speed,
            value: DPIEffectCodec.speedRange.upperBound + 1
        )) {
            _ = try codec.encode(DPIEffectCodec.speedRange.upperBound + 1, for: .speed)
        }
        #expect(throws: DPIEffectCodec.CodecError.invalidRawValue(field: .brightness, value: 255)) {
            _ = try codec.decode(255, for: .brightness)
        }
    }
}
