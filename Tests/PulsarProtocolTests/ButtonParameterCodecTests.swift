import Testing
@testable import PulsarProtocol

@Suite("Paramètres de boutons")
struct ButtonParameterCodecTests {
    @Test("Les fonctions souris, DPI et défilement ont un round-trip typé")
    func typedParametersRoundTrip() throws {
        let values: [(PulsarKeyFunction, PulsarButtonParameter)] = [
            (.mouseButton, .mouseButton(.forward)),
            (.dpiSwitch, .dpiSwitch(.previous)),
            (.horizontalScroll, .horizontalScroll(.negative)),
            (.verticalScroll, .verticalScroll(.positive)),
            (.macro, .macro(slot: 3, repeatCount: 5)),
            (.dpiLock, .dpiLock(1_600)),
        ]

        for (function, typed) in values {
            let raw = try ButtonParameterCodec.encode(typed)
            #expect(ButtonParameterCodec.decode(function: function, parameter: raw) == typed)
            try ButtonParameterCodec.validate(function: function, parameter: raw)
        }
    }

    @Test("Rapid-fire est borné sur le nombre de répétitions et l'intervalle")
    func rapidFireBounds() throws {
        let raw = try ButtonParameterCodec.encode(
            .rapidFire(times: 3, intervalMilliseconds: 255)
        )
        #expect(raw == 0xFF03)
        #expect(ButtonParameterCodec.decode(function: .rapidFire, parameter: raw)
            == .rapidFire(times: 3, intervalMilliseconds: 255))

        #expect(throws: ButtonParameterCodec.CodecError.self) {
            try ButtonParameterCodec.validate(function: .rapidFire, parameter: 9 << 8)
        }
        #expect(throws: ButtonParameterCodec.CodecError.self) {
            try ButtonParameterCodec.encode(.rapidFire(times: 4, intervalMilliseconds: 10))
        }
    }

    @Test("Les fonctions sans paramètre refusent un entier résiduel")
    func fixedFunctionsRejectResidualParameter() {
        #expect(ButtonParameterCodec.decode(function: .lighting, parameter: 1) == .unknown(1))
        #expect(throws: ButtonParameterCodec.CodecError.self) {
            try ButtonParameterCodec.validate(function: .profileSwitch, parameter: 0x0100)
        }
    }
}
