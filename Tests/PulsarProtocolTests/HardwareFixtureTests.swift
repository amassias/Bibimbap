import Foundation
import Testing
@testable import PulsarCatalog
@testable import PulsarProtocol

/// Capture réelle relue par les tests, pour vérifier que les décodeurs retrouvent
/// bien les réglages affichés par le configurateur officiel au moment de la lecture.
struct HardwareFixture: Decodable {
    struct Device: Decodable {
        var vendorID: UInt16
        var productID: UInt16
        var cid: Int
        var mid: Int
        var connectionType: UInt8
        var firmware: String
    }

    struct Expected: Decodable {
        var reportRateHertz: Int
        var dpiStageCount: Int
        var activeStage: Int
        var liftOffMillimetres: Int
        var debounceMilliseconds: Int
        var motionSync: Bool
        var angleSnap: Bool
        var rippleControl: Bool
        var sleepMinutes: Int
        var dpiStages: [Int]
    }

    var description: String
    var device: Device
    var expected: Expected
    var coreRegion: [UInt8]

    static func load(_ name: String) throws -> HardwareFixture {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(HardwareFixture.self, from: Data(contentsOf: url))
    }

    var image: FlashImage {
        var image = FlashImage()
        image.write(coreRegion, at: 0)
        return image
    }
}

@Suite("Capture X2 CrazyLight")
struct HardwareFixtureTests {
    let fixture = try! HardwareFixture.load("x2-crazylight-core")

    var family: DeviceFamily {
        DeviceCatalog.embedded.family(cid: fixture.device.cid, mid: fixture.device.mid)!
    }

    @Test("Le modèle capturé est reconnu par le catalogue embarqué")
    func recognisedByCatalog() throws {
        let catalog = DeviceCatalog.embedded
        #expect(catalog.recognizes(vendorID: fixture.device.vendorID, productID: fixture.device.productID))
        #expect(catalog.connection(forProductID: fixture.device.productID) == .wired)

        let family = try #require(catalog.family(cid: fixture.device.cid, mid: fixture.device.mid))
        #expect(family.sensor.type == "pulsar x1")
        #expect(family.dpi.maximum == 32_000)
        #expect(family.buttons.count == 6)
        #expect(family.firmware.deviceVersion == fixture.device.firmware)
    }

    @Test("Le polling se relit à sa valeur affichée")
    func reportRate() throws {
        let code = try #require(ScalarSetting.decode(from: fixture.image, at: FlashMap.reportRate))
        #expect(ReportRateCodec.hertz(from: code) == fixture.expected.reportRateHertz)
    }

    @Test("Les réglages scalaires passent leur checksum et valent ce qui est attendu")
    func scalarSettings() throws {
        let image = fixture.image
        func value(_ address: UInt16) throws -> UInt8 {
            try #require(ScalarSetting.decode(from: image, at: address))
        }
        #expect(try value(FlashMap.maxDPIStage) == UInt8(fixture.expected.dpiStageCount))
        #expect(try value(FlashMap.currentDPI) == UInt8(fixture.expected.activeStage))
        #expect(try value(FlashMap.liftOffDistance) == UInt8(fixture.expected.liftOffMillimetres))
        #expect(try value(FlashMap.debounceTime) == UInt8(fixture.expected.debounceMilliseconds))
        #expect(try value(FlashMap.sleepTime) == UInt8(fixture.expected.sleepMinutes))
        #expect(try value(FlashMap.motionSync) == (fixture.expected.motionSync ? 1 : 0))
        #expect(try value(FlashMap.angleSnap) == (fixture.expected.angleSnap ? 1 : 0))
        #expect(try value(FlashMap.rippleControl) == (fixture.expected.rippleControl ? 1 : 0))
    }

    @Test("Les paliers DPI se décodent aux valeurs affichées")
    func dpiStages() throws {
        let codec = try #require(DPICodec(family: family, catalog: .embedded))
        let image = fixture.image
        for (index, expected) in fixture.expected.dpiStages.enumerated() {
            let address = FlashMap.dpiValue(stage: index, extended: codec.usesExtendedBlock)
            let block = image.slice(at: address, count: FlashMap.dpiStageStride)
            let decoded = try codec.decodeStage(block)
            #expect(decoded.x == expected, "palier \(index + 1)")
            #expect(decoded.y == expected, "palier \(index + 1)")
        }
    }

    @Test("Les couleurs de palier correspondent aux valeurs par défaut du catalogue")
    func dpiColours() throws {
        let image = fixture.image
        for (index, stage) in family.dpi.stages.enumerated() {
            let bytes = image.slice(at: FlashMap.dpiColor(stage: index), count: 3)
            let colour = CatalogColor(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]))
            #expect(colour == stage.color, "palier \(index + 1)")
        }
    }

    @Test("Un palier ré-encodé reproduit exactement les octets lus")
    func stageRoundTrip() throws {
        let codec = try #require(DPICodec(family: family, catalog: .embedded))
        let image = fixture.image
        for index in 0..<fixture.expected.dpiStages.count {
            let address = FlashMap.dpiValue(stage: index, extended: false)
            let original = image.slice(at: address, count: FlashMap.dpiStageStride)
            let decoded = try codec.decodeStage(original)
            let reencoded = try codec.encodeStage(x: decoded.x, y: decoded.y)
            #expect(reencoded == original, "palier \(index + 1)")
        }
    }

    @Test("Les fonctions de boutons se décodent")
    func buttonFunctions() throws {
        let image = fixture.image
        let expected: [(PulsarKeyFunction, Int)] = [
            (.mouseButton, 0x0100),
            (.mouseButton, 0x0200),
            (.mouseButton, 0x0400),
            (.macro, 0x0301),
            (.macro, 0x0401),
            (.dpiSwitch, 0x0100),
        ]
        for (index, entry) in expected.enumerated() {
            let block = image.slice(at: FlashMap.keyFunction(button: index), count: 4)
            #expect(PulsarKeyFunction(rawValue: block[0]) == entry.0, "bouton \(index)")
            #expect(Int(block[1]) << 8 | Int(block[2]) == entry.1, "bouton \(index)")
            #expect(PulsarFrame.blockChecksum(over: block.dropLast()) == block[3], "bouton \(index)")
        }
    }
}
