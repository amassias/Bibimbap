import Testing
@testable import PulsarProtocol

@Suite("Codec de raccourcis")
struct ShortcutCodecTests {
    private let shortcut = PulsarShortcut(keys: [
        .init(kind: .modifier, value: 8),
        .init(kind: .key, value: 4),
        .init(kind: .media, value: 0x00CD),
    ])

    @Test("Un raccourci clavier et média revient identique")
    func roundTrip() throws {
        let block = try ShortcutCodec.encode(shortcut)
        #expect(block.count == ShortcutCodec.blockLength)
        #expect(block[0] == 6)
        #expect(ShortcutCodec.decode(block) == shortcut)

        var image = FlashImage()
        image.write(block, at: FlashMap.shortcut(slot: 2))
        #expect(ShortcutCodec.decode(from: image, slot: 2) == shortcut)
    }

    @Test("Les relâchements sont encodés en ordre inverse")
    func releasesReversePresses() throws {
        let block = try ShortcutCodec.encode(shortcut)
        let firstRelease = 1 + 3 * shortcut.keys.count
        #expect(block[firstRelease] & 0x0F == shortcut.keys[2].kind.rawValue)
        #expect(block[firstRelease + 1] == 0xCD)
        #expect(block[firstRelease + 2] == 0)
    }

    @Test("Un bloc vierge devient une combinaison vide")
    func blankBlockIsEmpty() throws {
        #expect(ShortcutCodec.decode([UInt8](repeating: 0xFF, count: 32))
            == PulsarShortcut(keys: []))
        #expect(try ShortcutCodec.encode(PulsarShortcut(keys: []))
            == [UInt8](repeating: 0xFF, count: 32))
    }

    @Test("Un checksum ou un nombre de touches invalide est rejeté")
    func malformedBlocksAreRejected() throws {
        var block = try ShortcutCodec.encode(shortcut)
        block[7] = block[7] &+ 1
        #expect(ShortcutCodec.decode(block) == nil)

        #expect(throws: ShortcutCodec.CodecError.self) {
            try ShortcutCodec.encode(PulsarShortcut(keys: Array(repeating: .init(
                kind: .key, value: 4
            ), count: 6)))
        }
    }
}
