import Testing
@testable import PulsarCatalog
@testable import PulsarProtocol

@Suite("Codec DPI")
struct DPICodecTests {
    let pulsarX1 = DPICodec(
        sensorType: "pulsar x1",
        ranges: DeviceCatalog.embedded.sensors["pulsar x1"]!
    )

    @Test("Les valeurs par défaut de la X2 s'encodent puis se décodent à l'identique",
          arguments: [400, 800, 1500, 3200, 6400, 12800, 10, 10_000, 10_050, 30_000, 30_100, 32_000])
    func roundTrip(dpi: Int) throws {
        let encoded = try pulsarX1.raw(dpi: dpi)
        #expect(try pulsarX1.dpi(raw: encoded.raw, exponentCode: encoded.exponentCode) == dpi)
    }

    @Test("Chaque plage sélectionne son code d'exposant")
    func exponentSelection() throws {
        #expect(try pulsarX1.raw(dpi: 400).exponentCode == 0)
        #expect(try pulsarX1.raw(dpi: 12_800).exponentCode == 2)
        #expect(try pulsarX1.raw(dpi: 31_000).exponentCode == 3)
    }

    @Test("Une valeur intermédiaire est ramenée au pas de sa plage")
    func snapping() throws {
        #expect(try pulsarX1.snap(dpi: 1503) == 1500)
        #expect(try pulsarX1.snap(dpi: 1506) == 1510)
        #expect(try pulsarX1.snap(dpi: 12_780) == 12_800)
    }

    @Test("Les valeurs hors plage sont ramenées aux bornes")
    func clamping() throws {
        #expect(try pulsarX1.snap(dpi: 1) == 10)
        #expect(try pulsarX1.snap(dpi: 99_999) == 32_000)
    }

    @Test("Un palier encodé porte son propre checksum")
    func stageChecksum() throws {
        let block = try pulsarX1.encodeStage(x: 1500, y: 1500)
        #expect(block.count == 4)
        #expect(block.reduce(UInt8(0)) { $0 &+ $1 } == 0x55)
    }

    @Test("Un palier dont le checksum est faux est refusé")
    func stageChecksumIsRequired() throws {
        var block = try pulsarX1.encodeStage(x: 1500, y: 1500)
        block[3] &+= 1

        #expect(throws: DPICodec.CodecError.checksumMismatch(
            expected: PulsarFrame.blockChecksum(over: block.dropLast()),
            actual: block[3]
        )) {
            _ = try pulsarX1.decodeStage(block)
        }
    }

    @Test("Un palier X/Y dissocié conserve les deux axes")
    func asymmetricStage() throws {
        let block = try pulsarX1.encodeStage(x: 800, y: 1600)
        let decoded = try pulsarX1.decodeStage(block)
        #expect(decoded.x == 800)
        #expect(decoded.y == 1600)
    }

    @Test("Le capteur 3955 utilise des blocs de six octets")
    func extendedBlocks() throws {
        let codec = DPICodec(sensorType: "3955", ranges: DeviceCatalog.embedded.sensors["3955"]!)
        #expect(codec.usesExtendedBlock)
        let block = try codec.encodeStage(x: 42_000, y: 42_000)
        #expect(block.count == 6)
        let decoded = try codec.decodeStage(block)
        #expect(decoded.x == 42_000)
        #expect(decoded.y == 42_000)
    }

    @Test("Les plages exposées à l'UI sont celles du capteur et du plafond du modèle")
    func representableRanges() throws {
        #expect(pulsarX1.representableRanges == [
            DPICodec.RepresentableRange(minimum: 10, maximum: 10_000, step: 10),
            DPICodec.RepresentableRange(minimum: 10_050, maximum: 30_000, step: 50),
            DPICodec.RepresentableRange(minimum: 30_100, maximum: 32_000, step: 100),
        ])

        let codec3955 = DPICodec(sensorType: "3955", ranges: DeviceCatalog.embedded.sensors["3955"]!)
        #expect(codec3955.representableRanges(upTo: 42_000) == [
            DPICodec.RepresentableRange(minimum: 50, maximum: 42_000, step: 1),
        ])
    }

    @Test("Tous les capteurs du catalogue savent encoder leurs bornes")
    func everySensorRoundTrips() throws {
        for (name, ranges) in DeviceCatalog.embedded.sensors where !ranges.hasLookupTable {
            let codec = DPICodec(sensorType: name, ranges: ranges)
            for range in ranges.ranges {
                for dpi in [range.minimum, range.minimum + range.step, range.maximum] {
                    let encoded = try codec.raw(dpi: dpi)
                    let decoded = try codec.dpi(raw: encoded.raw, exponentCode: encoded.exponentCode)
                    #expect(decoded == dpi, "\(name) : \(dpi)")
                }
            }
        }
    }
}

@Suite("Codec de polling")
struct ReportRateCodecTests {
    @Test("Les cadences supportées font l'aller-retour",
          arguments: [125, 250, 500, 1000, 2000, 4000, 8000])
    func roundTrip(hertz: Int) throws {
        let code = try #require(ReportRateCodec.code(from: hertz))
        #expect(ReportRateCodec.hertz(from: code) == hertz)
    }

    @Test("Le code lu sur matériel vaut bien 500 Hz")
    func matchesHardwareCapture() {
        #expect(ReportRateCodec.hertz(from: 2) == 500)
    }

    @Test("Une cadence non supportée n'a pas de code")
    func rejectsUnsupported() {
        #expect(ReportRateCodec.code(from: 333) == nil)
    }

    @Test("Les cadences proposées respectent le plafond du modèle")
    func respectsMaximum() {
        #expect(ReportRateCodec.available(upTo: 1000) == [125, 250, 500, 1000])
        #expect(ReportRateCodec.available(upTo: 8000).count == 7)
    }
}
