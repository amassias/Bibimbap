import Foundation

/// Opérations pures de l'éditeur de macros.
///
/// Elles travaillent sur les identifiants des étapes plutôt que sur une position
/// supposée par l'interface. Cela rend les sélections multiples déterministes et évite
/// qu'une suppression ou un déplacement ne vise une autre ligne après une mise à jour.
public enum MacroEditing {
    @discardableResult
    public static func insert(
        _ newSteps: [PulsarMacro.Step],
        into steps: inout [PulsarMacro.Step],
        after selection: Set<PulsarMacro.Step.ID> = []
    ) -> Bool {
        guard !newSteps.isEmpty,
              steps.count + newSteps.count <= PulsarMacro.stepCapacity
        else { return false }

        let insertionIndex = insertionIndex(after: selection, in: steps)
        steps.insert(contentsOf: newSteps, at: insertionIndex)
        return true
    }

    public static func delete(
        ids: Set<PulsarMacro.Step.ID>,
        from steps: inout [PulsarMacro.Step]
    ) {
        guard !ids.isEmpty else { return }
        steps.removeAll { ids.contains($0.id) }
    }

    @discardableResult
    public static func duplicate(
        ids: Set<PulsarMacro.Step.ID>,
        in steps: inout [PulsarMacro.Step]
    ) -> [PulsarMacro.Step.ID] {
        let selected = steps.filter { ids.contains($0.id) }
        guard !selected.isEmpty,
              steps.count + selected.count <= PulsarMacro.stepCapacity
        else { return [] }

        let copies = selected.map { step -> PulsarMacro.Step in
            var copy = step
            copy.id = UUID()
            return copy
        }
        let insertionIndex = insertionIndex(after: ids, in: steps)
        steps.insert(contentsOf: copies, at: insertionIndex)
        return copies.map(\.id)
    }

    public static func moveUp(
        ids: Set<PulsarMacro.Step.ID>,
        in steps: inout [PulsarMacro.Step]
    ) {
        guard steps.count > 1 else { return }
        for index in steps.indices where ids.contains(steps[index].id) {
            guard index > steps.startIndex,
                  !ids.contains(steps[index - 1].id)
            else { continue }
            steps.swapAt(index, index - 1)
        }
    }

    public static func moveDown(
        ids: Set<PulsarMacro.Step.ID>,
        in steps: inout [PulsarMacro.Step]
    ) {
        guard steps.count > 1 else { return }
        for index in steps.indices.reversed() where ids.contains(steps[index].id) {
            guard index < steps.index(before: steps.endIndex),
                  !ids.contains(steps[index + 1].id)
            else { continue }
            steps.swapAt(index, index + 1)
        }
    }

    private static func insertionIndex(
        after ids: Set<PulsarMacro.Step.ID>,
        in steps: [PulsarMacro.Step]
    ) -> Int {
        guard let last = steps.lastIndex(where: { ids.contains($0.id) }) else {
            return steps.endIndex
        }
        return last + 1
    }
}

public extension PulsarMacro {
    /// Résumé court, lisible dans l'éditeur et indépendant du format interne.
    var delaySummary: String {
        guard !steps.isEmpty else { return "—" }
        let total = steps.reduce(0) { $0 + max(0, $1.delayMilliseconds) }
        if total < 1_000 { return "\(total) ms" }
        let seconds = Double(total) / 1_000
        return String(format: "%.1f s", seconds)
    }
}
