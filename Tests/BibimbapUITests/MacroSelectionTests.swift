import Testing
@testable import BibimbapUI

@Suite("Sélection des macros")
struct MacroSelectionTests {
    private let slots = [2, 5, 9]

    @Test("La flèche bas sélectionne la macro suivante")
    func downSelectsNextMacro() {
        #expect(
            MacroSelectionNavigator.slot(
                after: 2,
                in: slots,
                direction: .next
            ) == 5
        )
    }

    @Test("La flèche haut sélectionne la macro précédente")
    func upSelectsPreviousMacro() {
        #expect(
            MacroSelectionNavigator.slot(
                after: 9,
                in: slots,
                direction: .previous
            ) == 5
        )
    }

    @Test("La sélection reste bornée aux deux extrémités")
    func selectionStaysWithinBounds() {
        #expect(
            MacroSelectionNavigator.slot(
                after: 2,
                in: slots,
                direction: .previous
            ) == 2
        )
        #expect(
            MacroSelectionNavigator.slot(
                after: 9,
                in: slots,
                direction: .next
            ) == 9
        )
    }

    @Test("Une liste vide ne sélectionne rien")
    func emptyListHasNoSelection() {
        #expect(
            MacroSelectionNavigator.slot(
                after: nil,
                in: [],
                direction: .next
            ) == nil
        )
    }
}
