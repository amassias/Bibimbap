import BibimbapFeatures
import PulsarProtocol
import SwiftUI

/// Édition des macros affectées aux boutons.
///
/// Le firmware réserve un emplacement par bouton : une macro n'existe donc que si un
/// bouton lui est affecté. La section le dit plutôt que d'afficher une liste vide.
struct MacrosSection: View {
    @Bindable var model: AppModel
    @State private var selection: Int?

    private var macroButtons: [DeviceSettings.ButtonAssignment] {
        model.draft.buttons.filter { $0.function == .macro }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if macroButtons.isEmpty {
                ContentUnavailableView {
                    Label("Aucun bouton affecté à une macro", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Chaque macro occupe l'emplacement du bouton auquel elle est affectée. Assignez la fonction « Macro » à un bouton dans Personnaliser pour en créer une.")
                } actions: {
                    Button("Ouvrir Personnaliser") { model.section = .customize }
                        .buttonStyle(.borderedProminent)
                }
                .frame(minHeight: 260)
            } else {
                ForEach(macroButtons) { button in
                    macroCard(for: button)
                }
            }
        }
    }

    @ViewBuilder
    private func macroCard(for button: DeviceSettings.ButtonAssignment) -> some View {
        let slot = (button.parameter >> 8) & 0xFF

        if let index = model.draft.macros.firstIndex(where: { $0.slot == slot }) {
            MacroEditor(binding: $model.draft.macros[index], buttonIndex: button.index)
        } else {
            SettingsGroup(
                title: String(localized: "Bouton \(button.index + 1)"),
                subtitle: String(localized: "Emplacement \(slot) — aucune macro enregistrée.")
            ) {
                SettingsRow(label: String(localized: "Créer une macro"), showsDivider: false) {
                    Button("Créer") {
                        model.draft.macros.append(DeviceSettings.MacroBinding(
                            slot: slot,
                            macro: PulsarMacro(name: String(localized: "Macro \(slot + 1)"), steps: []),
                            repeatCount: 1
                        ))
                    }
                }
            }
        }
    }
}

/// Édition d'une macro : nom, répétitions, et liste d'étapes ordonnée.
struct MacroEditor: View {
    @Binding var binding: DeviceSettings.MacroBinding
    let buttonIndex: Int

    @State private var selection: PulsarMacro.Step.ID?

    private var nameByteCount: Int { binding.macro.name.utf8.count }

    var body: some View {
        SettingsGroup(
            title: String(localized: "Bouton \(buttonIndex + 1)"),
            subtitle: String(localized: "Emplacement \(binding.slot) · \(binding.macro.steps.count)/\(PulsarMacro.stepCapacity) étapes")
        ) {
            SettingsRow(
                label: String(localized: "Nom"),
                help: String(localized: "\(nameByteCount)/\(PulsarMacro.nameCapacity) octets — les accents en comptent deux.")
            ) {
                TextField("", text: $binding.macro.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }

            SettingsRow(
                label: String(localized: "Répétitions"),
                help: String(localized: "Nombre d'exécutions à chaque appui du bouton.")
            ) {
                Stepper(value: $binding.repeatCount, in: 1...255) {
                    Text("\(binding.repeatCount)")
                        .monospacedDigit()
                        .frame(minWidth: 26)
                }
            }

            SettingsRow(label: String(localized: "Étapes"), showsDivider: false) {
                HStack(spacing: 8) {
                    Menu("Ajouter") {
                        Button("Appui de touche") { append(kind: .key, action: .press, value: 4) }
                        Button("Relâchement de touche") { append(kind: .key, action: .release, value: 4) }
                        Divider()
                        Button("Clic gauche") { appendClick(.left) }
                        Button("Clic droit") { appendClick(.right) }
                        Button("Clic molette") { appendClick(.middle) }
                        Divider()
                        Button("Déplacement") { append(kind: .movement, action: .none, value: 0) }
                        Button("Molette vers le haut") { append(kind: .wheel, action: .none, value: 1) }
                        Button("Molette vers le bas") { append(kind: .wheel, action: .none, value: 255) }
                    }
                    .fixedSize()
                    .disabled(binding.macro.steps.count >= PulsarMacro.stepCapacity)

                    Button("Supprimer", role: .destructive) {
                        binding.macro.steps.removeAll { $0.id == selection }
                        selection = nil
                    }
                    .disabled(selection == nil)
                }
            }
        }
        .overlay(alignment: .bottom) { EmptyView() }

        if !binding.macro.steps.isEmpty {
            stepTable
        }
    }

    private var stepTable: some View {
        Table($binding.macro.steps, selection: $selection) {
            TableColumn("Nature") { $step in
                Text(step.kind?.label ?? String(localized: "Inconnue (\(step.kindCode))"))
                    .foregroundStyle(step.kind == nil ? .secondary : .primary)
            }
            .width(160)

            TableColumn("État") { $step in
                if step.kind?.isPointerEvent == true && step.kind != .mouseButton {
                    Text("—").foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $step.action) {
                        Text(PulsarMacro.Step.Action.press.label).tag(PulsarMacro.Step.Action.press)
                        Text(PulsarMacro.Step.Action.release.label).tag(PulsarMacro.Step.Action.release)
                    }
                    .labelsHidden()
                }
            }
            .width(130)

            TableColumn("Valeur") { $step in
                if step.kind == .movement {
                    movementFields(step: $step)
                } else {
                    TextField("", value: $step.value, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                }
            }
            .width(150)

            TableColumn("Délai") { $step in
                HStack(spacing: 4) {
                    TextField("", value: $step.delayMilliseconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                    Text("ms").foregroundStyle(.secondary).font(.caption)
                }
            }
            .width(110)
        }
        .frame(minHeight: 180, maxHeight: 320)
    }

    private func movementFields(step: Binding<PulsarMacro.Step>) -> some View {
        let offsets = MacroCodec.movement(from: step.wrappedValue.value)
        return HStack(spacing: 4) {
            axis("X", value: offsets.x) { newX in
                step.wrappedValue.value = MacroCodec.movementValue(x: newX, y: offsets.y)
            }
            axis("Y", value: offsets.y) { newY in
                step.wrappedValue.value = MacroCodec.movementValue(x: offsets.x, y: newY)
            }
        }
    }

    private func axis(_ label: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: Binding(get: { value }, set: set), format: .number)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 48)
        }
    }

    private func append(kind: PulsarMacro.Step.Kind, action: PulsarMacro.Step.Action, value: Int) {
        // 10 ms est le plancher accepté par le firmware pour un délai non nul.
        let delay = kind.isPointerEvent ? 0 : 10
        binding.macro.steps.append(
            PulsarMacro.Step(kind: kind, action: action, value: value, delayMilliseconds: delay)
        )
    }

    private func appendClick(_ button: PulsarMacro.MouseButtonMask) {
        binding.macro.steps.append(
            PulsarMacro.Step(kind: .mouseButton, action: .press,
                             value: button.rawValue, delayMilliseconds: 0)
        )
        binding.macro.steps.append(
            PulsarMacro.Step(kind: .mouseButton, action: .release,
                             value: button.rawValue, delayMilliseconds: 0)
        )
    }
}
