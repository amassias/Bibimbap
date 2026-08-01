import Testing
@testable import PulsarProtocol

@Suite("Édition de macros")
struct MacroEditingTests {
    private func steps(_ count: Int) -> [PulsarMacro.Step] {
        (0..<count).map { index in
            .init(kind: .key, action: .press, value: 4 + index, delayMilliseconds: index * 10)
        }
    }

    @Test("Insertion multiple, duplication et suppression suivent la sélection")
    func multipleSelectionOperations() {
        var original = steps(3)
        let selected = Set([original[0].id, original[2].id])
        let inserted = steps(2)
        #expect(MacroEditing.insert(inserted, into: &original, after: selected))
        #expect(original.count == 5)
        #expect(original[3].value == inserted[0].value)
        #expect(original[4].value == inserted[1].value)

        let duplicatedIDs = MacroEditing.duplicate(ids: selected, in: &original)
        #expect(duplicatedIDs.count == 2)
        #expect(duplicatedIDs.allSatisfy { !selected.contains($0) })

        MacroEditing.delete(ids: selected, from: &original)
        #expect(original.count == 5)
        #expect(original.allSatisfy { !selected.contains($0.id) })
    }

    @Test("Le réordonnancement conserve les identifiants")
    func reorderingPreservesIDs() {
        var original = steps(4)
        let ids = Set([original[1].id, original[2].id])
        let allIDs = Set(original.map(\.id))
        MacroEditing.moveUp(ids: ids, in: &original)
        MacroEditing.moveDown(ids: ids, in: &original)
        #expect(Set(original.map(\.id)) == allIDs)
        #expect(Set(original[1...2].map(\.id)) == ids)
    }

    @Test("Les opérations refusent de dépasser les 70 étapes")
    func stepLimitIsEnforced() {
        var original = steps(PulsarMacro.stepCapacity)
        let extra = steps(1)
        #expect(!MacroEditing.insert(extra, into: &original))
        #expect(MacroEditing.duplicate(ids: Set([original[0].id]), in: &original).isEmpty)
    }
}
