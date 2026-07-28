import Testing
@testable import PulsarProtocol

@Suite("Trame")
struct PulsarFrameTests {
    @Test("La somme du report ID et de la trame vaut 0x55")
    func checksumInvariant() {
        let frames = [
            PulsarFrame(command: .encryptionData, payload: [1, 2, 3, 4, 0, 0, 0, 0]),
            PulsarFrame(command: .readFlashData, address: 0x0100, declaredLength: 10),
            PulsarFrame(command: .writeFlashData, address: 0x00A0, payload: Array(repeating: 0xAB, count: 10)),
            PulsarFrame(command: .batteryLevel),
        ]
        for frame in frames {
            let sum = frame.encoded().reduce(UInt8(0)) { $0 &+ $1 } &+ PulsarFrame.reportID
            #expect(sum == PulsarFrame.checksumTarget)
        }
    }

    @Test("Encodage et décodage sont réciproques")
    func roundTrip() throws {
        let original = PulsarFrame(command: .writeFlashData, address: 0x1234, payload: [9, 8, 7])
        let decoded = try PulsarFrame(decoding: original.encoded())
        #expect(decoded.command == .writeFlashData)
        #expect(decoded.address == 0x1234)
        #expect(decoded.payload.prefix(3) == [9, 8, 7])
    }

    @Test("Le champ longueur d'une lecture flash porte le nombre d'octets demandés")
    func readLengthIsNotPayloadCount() {
        let frame = PulsarFrame(command: .readFlashData, address: 0x0040, declaredLength: 10)
        let bytes = frame.encoded()
        #expect(bytes[4] == 10)
        #expect(frame.payload.isEmpty)
    }

    @Test("Une trame de longueur inattendue est rejetée")
    func rejectsWrongLength() {
        #expect(throws: PulsarFrame.DecodingError.wrongLength(4)) {
            try PulsarFrame(decoding: [1, 2, 3, 4])
        }
    }

    @Test("Un checksum faux est rejeté")
    func rejectsBadChecksum() throws {
        var bytes = PulsarFrame(command: .batteryLevel).encoded()
        bytes[15] = bytes[15] &+ 1
        #expect(throws: (any Error).self) {
            try PulsarFrame(decoding: bytes)
        }
    }

    @Test("Une commande inconnue est rejetée")
    func rejectsUnknownCommand() {
        var bytes = [UInt8](repeating: 0, count: PulsarFrame.length)
        bytes[0] = 99
        bytes[15] = PulsarFrame.checksum(over: bytes.dropLast())
        #expect(throws: PulsarFrame.DecodingError.unknownCommand(99)) {
            try PulsarFrame(decoding: bytes)
        }
    }

    @Test("Le statut 1 signale une commande absente du modèle")
    func unsupportedStatus() {
        #expect(PulsarFrame(command: .getLongRangeMode, status: 1).isUnsupported)
        #expect(!PulsarFrame(command: .getLongRangeMode, status: 0).isUnsupported)
    }

    @Test("Le checksum de bloc complète la somme à 0x55, sans report ID")
    func blockChecksum() {
        let block: [UInt8] = [0x27, 0x27, 0x00]
        let checksum = PulsarFrame.blockChecksum(over: block)
        #expect(checksum == 0x07)
        #expect((block + [checksum]).reduce(UInt8(0)) { $0 &+ $1 } == 0x55)
    }
}

@Suite("Notification de changement")
struct ChangeNotificationTests {
    @Test("Les bitmasks se décomposent en groupes à relire")
    func decodesBitmasks() {
        let notification = PulsarChangeNotification(primary: 0b0010_0011, secondary: 0b0000_0101)
        #expect(notification.battery)
        #expect(notification.generalSettings)
        #expect(notification.profile)
        #expect(!notification.lighting)
        #expect(notification.dpi)
        #expect(notification.dpiEffect)
        #expect(!notification.buttons)
    }

    @Test("Des bitmasks nuls ne déclenchent aucune relecture")
    func emptyIsEmpty() {
        #expect(PulsarChangeNotification(primary: 0, secondary: 0).isEmpty)
    }
}

@Suite("Type de connexion")
struct ConnectionTypeTests {
    @Test("Chaque type porte son plafond de polling", arguments: [
        (PulsarConnectionType.wireless1k, false, 1000),
        (.wireless4k, false, 4000),
        (.wired1k, true, 1000),
        (.wired8k, true, 8000),
        (.wireless2k, false, 2000),
        (.wireless8k, false, 8000),
    ])
    func maximumRates(type: PulsarConnectionType, wired: Bool, hertz: Int) {
        #expect(type.isWired == wired)
        #expect(type.maximumReportRate == hertz)
    }
}
