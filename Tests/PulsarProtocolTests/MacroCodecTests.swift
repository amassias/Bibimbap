import Testing
@testable import PulsarProtocol

@Suite("Codec de macros")
struct MacroCodecTests {
    private func sample() -> PulsarMacro {
        PulsarMacro(name: "Recharge rapide", steps: [
            .init(kind: .key, action: .press, value: 4, delayMilliseconds: 25),
            .init(kind: .key, action: .release, value: 4, delayMilliseconds: 10),
            .init(kind: .mouseButton, action: .press, value: 1, delayMilliseconds: 0),
            .init(kind: .mouseButton, action: .release, value: 1, delayMilliseconds: 0),
            .init(kind: .movement, action: .none, value: MacroCodec.movementValue(x: -20, y: 12),
                  delayMilliseconds: 10),
            .init(kind: .wheel, action: .none, value: 255, delayMilliseconds: 0),
        ])
    }

    @Test("Encodage puis décodage restituent la macro")
    func roundTrip() throws {
        let macro = sample()
        let block = try MacroCodec.encode(macro)

        var image = FlashImage()
        image.write(block, at: FlashMap.macro(slot: 0))
        let decoded = try #require(MacroCodec.decode(from: image, slot: 0))

        #expect(decoded.name == macro.name)
        #expect(decoded.steps.count == macro.steps.count)
        for (original, restored) in zip(macro.steps, decoded.steps) {
            #expect(restored.kindCode == original.kindCode)
            #expect(restored.action == original.action)
            #expect(restored.value == original.value)
            #expect(restored.delayMilliseconds == original.delayMilliseconds)
        }
    }

    @Test("L'appui s'écrit 2 et le relâchement 1")
    func actionEncodingIsInverted() throws {
        let block = try MacroCodec.encode(PulsarMacro(name: "T", steps: [
            .init(kind: .key, action: .press, value: 4, delayMilliseconds: 0),
            .init(kind: .key, action: .release, value: 4, delayMilliseconds: 0),
            .init(kind: .movement, action: .none, value: 0, delayMilliseconds: 0),
        ]))
        #expect(block[MacroCodec.stepsOffset] >> 6 == 2)
        #expect(block[MacroCodec.stepsOffset + 5] >> 6 == 1)
        #expect(block[MacroCodec.stepsOffset + 10] >> 6 == 0)
    }

    @Test("La valeur est petit-boutiste et le délai gros-boutiste")
    func endiannessDiffersWithinAStep() throws {
        let block = try MacroCodec.encode(PulsarMacro(name: "T", steps: [
            .init(kind: .key, action: .press, value: 0x1234, delayMilliseconds: 0xABCD),
        ]))
        let offset = MacroCodec.stepsOffset
        #expect(block[offset + 1] == 0x34)
        #expect(block[offset + 2] == 0x12)
        #expect(block[offset + 3] == 0xAB)
        #expect(block[offset + 4] == 0xCD)
    }

    @Test("Le checksum couvre le compteur et les étapes, pas le nom")
    func checksumScope() throws {
        let block = try MacroCodec.encode(sample())
        #expect(MacroCodec.verify(block))

        // Modifier le nom ne doit pas invalider le checksum…
        var renamed = block
        renamed[2] = renamed[2] &+ 1
        #expect(MacroCodec.verify(renamed))

        // …mais toucher à une étape, si.
        var altered = block
        altered[MacroCodec.stepsOffset + 1] = altered[MacroCodec.stepsOffset + 1] &+ 1
        #expect(!MacroCodec.verify(altered))
    }

    @Test("Un emplacement jamais écrit ne produit pas de macro")
    func emptySlotDecodesToNil() {
        // Une flash vierge est remplie de 0xFF : longueur de nom et nombre d'étapes
        // sont hors bornes, il ne faut rien inventer.
        #expect(MacroCodec.decode(from: FlashImage(), slot: 0) == nil)
    }

    @Test("Un bloc au nom trop long ou trop long en étapes est rejeté")
    func rejectsOversizedMacros() {
        #expect(throws: MacroCodec.CodecError.self) {
            try MacroCodec.encode(PulsarMacro(name: String(repeating: "a", count: 31), steps: []))
        }
        #expect(throws: MacroCodec.CodecError.self) {
            try MacroCodec.encode(PulsarMacro(
                name: "T",
                steps: Array(repeating: .init(kind: .key, action: .press, value: 4, delayMilliseconds: 0),
                             count: 71)
            ))
        }
    }

    @Test("Un nom accentué survit à l'aller-retour UTF-8")
    func handlesAccentedNames() throws {
        let macro = PulsarMacro(name: "Séquence éclair", steps: [
            .init(kind: .key, action: .press, value: 4, delayMilliseconds: 10),
        ])
        let block = try MacroCodec.encode(macro)
        var image = FlashImage()
        image.write(block, at: FlashMap.macro(slot: 2))
        #expect(MacroCodec.decode(from: image, slot: 2)?.name == "Séquence éclair")
    }

    @Test("Une nature inconnue traverse l'aller-retour sans être perdue")
    func preservesUnknownKinds() throws {
        let macro = PulsarMacro(name: "X", steps: [
            .init(kindCode: 9, action: .none, value: 7, delayMilliseconds: 0),
        ])
        let block = try MacroCodec.encode(macro)
        var image = FlashImage()
        image.write(block, at: FlashMap.macro(slot: 1))
        let decoded = try #require(MacroCodec.decode(from: image, slot: 1))
        #expect(decoded.steps.first?.kindCode == 9)
        #expect(decoded.steps.first?.kind == nil)
    }

    @Test("Les déplacements se décomposent en offsets signés",
          arguments: [(0, 0), (12, -20), (-127, 127), (127, -127)])
    func movementRoundTrip(x: Int, y: Int) {
        let value = MacroCodec.movementValue(x: x, y: y)
        let decoded = MacroCodec.movement(from: value)
        #expect(decoded.x == x)
        #expect(decoded.y == y)
    }

    @Test("Les emplacements ne se chevauchent pas")
    func slotsAreDisjoint() throws {
        let block = try MacroCodec.encode(sample())
        #expect(block.count <= MacroCodec.blockLength)
        #expect(FlashMap.macro(slot: 1) - FlashMap.macro(slot: 0) == UInt16(MacroCodec.blockLength))
    }
}
