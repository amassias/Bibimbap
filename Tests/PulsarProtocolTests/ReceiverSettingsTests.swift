import Testing
@testable import PulsarCatalog
@testable import PulsarProtocol

@Suite("Codec des réglages récepteur")
struct ReceiverSettingsTests {
    @Test("L'effet récepteur encode le mode, la couleur et les trois niveaux")
    func effectPayload() {
        let effect = ReceiverLightEffect(
            mode: 3,
            color: CatalogColor(red: 10, green: 20, blue: 30),
            speed: 4,
            brightness: 8,
            duration: 12
        )

        #expect(effect.payload == [3, 10, 20, 30, 4, 8, 12])
    }

    @Test("La fonction d'un bouton récepteur conserve son index et sa couleur")
    func buttonFunctionPayload() {
        let function = ReceiverButtonFunction(
            index: 2,
            mode: 5,
            color: CatalogColor(red: 1, green: 2, blue: 3),
            speed: 6,
            brightness: 7,
            duration: 9
        )

        #expect(function.payload == [2, 5, 1, 2, 3, 6, 7, 9])
    }

    @Test("Désactiver le RGB ne remplace aucune des trois couleurs")
    func disablingPreservesAllColors() {
        let original = DongleLightingState(
            mode: 3,
            colors: [1, 2, 3, 4, 5, 6, 7, 8, 9]
        )

        #expect(original.setting(enabled: false).colors == original.colors)
        #expect(original.setting(enabled: true).colors == original.colors)
    }

    @Test("Le RGB du dongle encode exactement le mode et les neuf canaux")
    func dongleLightingPayloadIsExact() {
        let state = DongleLightingState(
            mode: 2,
            colors: [10, 20, 30, 40, 50, 60, 70, 80, 90]
        )

        #expect(state.payload == [2, 10, 20, 30, 40, 50, 60, 70, 80, 90])
        #expect(DongleLightingState(payload: state.payload) == state)
        #expect(DongleLightingState(payload: Array(repeating: 0, count: 9)) == nil)
    }
}
