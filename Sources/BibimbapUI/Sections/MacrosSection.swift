import BibimbapFeatures
import BibimbapLocalization
import PulsarProtocol
import SwiftUI

/// Macro A : bibliothèque, table d'événements et inspecteur d'affectation.
struct MacrosSection: View {
    @Bindable var model: AppModel
    @State private var selectedSlot: Int?
    @FocusState private var isMacroLibraryFocused: Bool

    private var macroButtons: [DeviceSettings.ButtonAssignment] {
        model.draft.buttons.filter { $0.function == .macro }
    }

    private var macroSlots: [Int] {
        macroButtons.map(macroSlot)
    }

    private var selectedMacroIndex: Int? {
        guard let selectedSlot else { return nil }
        return model.draft.macros.firstIndex { $0.slot == selectedSlot }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xlarge) {
            PremiumSectionHeader(
                title: L10n.string("Macro"),
                subtitle: L10n.string("Create, edit and assign repeatable input sequences.")
            )

            if macroButtons.isEmpty {
                emptyState
            } else {
                macroWorkspace
            }
        }
        .onAppear {
            if selectedSlot == nil,
               let firstAvailableSlot = macroSlots.first(where: { slot in
                   model.draft.macros.contains { $0.slot == slot }
               }) {
                selectedSlot = firstAvailableSlot
            }
        }
    }

    private var macroWorkspace: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.small) {
                libraryPanel
                    .frame(width: 230)

                editorPanel
                    .frame(maxWidth: .infinity)

                inspectorPanel
                    .frame(width: 300)
            }
            .frame(minHeight: 520)

            VStack(spacing: Theme.Space.large) {
                libraryPanel
                editorPanel
                inspectorPanel
            }
        }
    }

    private var emptyState: some View {
        PremiumPanel {
            ContentUnavailableView {
                Label(
                    L10n.string("No button assigned to a macro"),
                    systemImage: "macwindow.badge.plus"
                )
            } description: {
                Text(
                    L10n.string(
                        "Assign the Macro action to a button in Customize. Its hardware slot will then appear here."
                    )
                )
            } actions: {
                Button(L10n.string("Open Customize")) {
                    model.section = .customize
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 420)
        }
        .frame(maxWidth: .infinity)
    }

    private var libraryPanel: some View {
        PremiumPanel(padding: Theme.Space.medium) {
            VStack(alignment: .leading, spacing: Theme.Space.medium) {
                HStack {
                    Text(L10n.string("Macros"))
                        .font(.headline)
                    Spacer()
                    Image(systemName: "plus")
                        .foregroundStyle(.tertiary)
                        .help(
                            L10n.string(
                                "Assign another Macro action in Customize to add a hardware slot."
                            )
                        )
                }

                ForEach(macroButtons) { button in
                    let slot = macroSlot(button)
                    let binding = model.draft.macros.first { $0.slot == slot }
                    Button {
                        selectMacro(slot: slot)
                    } label: {
                        HStack(spacing: Theme.Space.small) {
                            Circle()
                                .fill(selectedSlot == slot ? Color.accentColor : Color.secondary.opacity(0.45))
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                                Text(binding?.macro.name ?? L10n.format("Macro %d", slot + 1))
                                    .lineLimit(1)
                                Text(L10n.format("Button %d", button.index + 1))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Theme.Space.small)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(
                                    selectedSlot == slot
                                        ? Color.accentColor.opacity(0.10)
                                        : Color.clear
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .strokeBorder(
                                    selectedSlot == slot
                                        ? Color.accentColor
                                        : PremiumPalette.hairline.opacity(0.55),
                                    lineWidth: selectedSlot == slot ? 1 : 0.5
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedSlot == slot ? .isSelected : [])
                }

                Spacer()
            }
        }
        .focusable()
        .focused($isMacroLibraryFocused)
        .onMoveCommand { direction in
            moveSelection(direction)
        }
        .onKeyPress(.upArrow) {
            moveSelection(.up)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(.down)
            return .handled
        }
    }

    @ViewBuilder
    private var editorPanel: some View {
        if let index = selectedMacroIndex {
            MacroTableEditor(binding: $model.draft.macros[index])
        } else {
            PremiumPanel {
                ContentUnavailableView(
                    L10n.string("Select a macro"),
                    systemImage: "list.bullet.rectangle"
                )
            }
        }
    }

    @ViewBuilder
    private var inspectorPanel: some View {
        if let index = selectedMacroIndex {
            let slot = model.draft.macros[index].slot
            let button = macroButtons.first { macroSlot($0) == slot }

            PremiumPanel {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.string("Playback"))
                        .font(.headline)
                        .padding(.bottom, Theme.Space.medium)

                    PremiumRow(label: L10n.string("Repeat mode")) {
                        Text(L10n.string("Repeat"))
                            .foregroundStyle(.secondary)
                    }

                    PremiumRow(label: L10n.string("Repeat count")) {
                        Stepper(
                            value: $model.draft.macros[index].repeatCount,
                            in: 1...255
                        ) {
                            Text("\(model.draft.macros[index].repeatCount)")
                                .monospacedDigit()
                                .frame(minWidth: 28)
                        }
                    }

                    PremiumRow(
                        label: L10n.string("Assigned to"),
                        showsDivider: false
                    ) {
                        Text(
                            button.map { L10n.format("Button %d", $0.index + 1) } ?? "—"
                        )
                        .foregroundStyle(Color.accentColor)
                    }

                    Divider()
                        .padding(.vertical, Theme.Space.large)

                    DeviceArtwork(model: model, maximumWidth: 190, maximumHeight: 245)
                        .frame(maxWidth: .infinity)

                    if let button {
                        HStack {
                            Spacer()
                            ButtonMarker(
                                number: button.index + 1,
                                isHighlighted: true
                            )
                            Text(L10n.format("Button %d", button.index + 1))
                                .font(.callout)
                            Spacer()
                        }
                        .padding(.top, Theme.Space.medium)
                    }

                    Spacer()
                }
            }
        } else {
            EmptyView()
        }
    }

    private func macroSlot(_ button: DeviceSettings.ButtonAssignment) -> Int {
        (button.parameter >> 8) & 0xFF
    }

    private func selectMacro(slot: Int) {
        ensureMacro(slot: slot)
        selectedSlot = slot
        isMacroLibraryFocused = true
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let selectionDirection: MacroSelectionDirection
        switch direction {
        case .up:
            selectionDirection = .previous
        case .down:
            selectionDirection = .next
        default:
            return
        }

        guard let slot = MacroSelectionNavigator.slot(
            after: selectedSlot,
            in: macroSlots,
            direction: selectionDirection
        ) else {
            return
        }
        selectMacro(slot: slot)
    }

    private func ensureMacro(slot: Int) {
        guard !model.draft.macros.contains(where: { $0.slot == slot }) else { return }
        model.draft.macros.append(
            DeviceSettings.MacroBinding(
                slot: slot,
                macro: PulsarMacro(
                    name: L10n.format("Macro %d", slot + 1),
                    steps: []
                ),
                repeatCount: 1
            )
        )
    }
}

enum MacroSelectionDirection {
    case previous
    case next
}

enum MacroSelectionNavigator {
    static func slot(
        after currentSlot: Int?,
        in slots: [Int],
        direction: MacroSelectionDirection
    ) -> Int? {
        guard !slots.isEmpty else { return nil }
        guard let currentSlot, let currentIndex = slots.firstIndex(of: currentSlot) else {
            return slots[0]
        }

        switch direction {
        case .previous:
            return slots[max(currentIndex - 1, 0)]
        case .next:
            return slots[min(currentIndex + 1, slots.count - 1)]
        }
    }
}

private struct MacroTableEditor: View {
    @Binding var binding: DeviceSettings.MacroBinding
    @State private var selection: Set<PulsarMacro.Step.ID> = []

    var body: some View {
        PremiumPanel(padding: 0) {
            VStack(spacing: 0) {
                editorHeader
                    .padding(Theme.Space.xlarge)

                Divider()

                if binding.macro.steps.isEmpty {
                    ContentUnavailableView {
                        Label(
                            L10n.string("No events yet"),
                            systemImage: "list.number"
                        )
                    } description: {
                        Text(
                            L10n.string(
                                "Add a mouse or keyboard event to build this macro."
                            )
                        )
                    } actions: {
                        addEventMenu
                    }
                    .frame(minHeight: 380)
                } else {
                    eventTable
                }
            }
        }
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Space.large) {
            HStack {
                TextField("", text: $binding.macro.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .accessibilityLabel(L10n.string("Macro name"))

                Spacer()

                addEventMenu

                Button {
                    selection = Set(MacroEditing.duplicate(
                        ids: selection,
                        in: &binding.macro.steps
                    ))
                } label: {
                    Label(L10n.string("Duplicate"), systemImage: "plus.square.on.square")
                }
                .disabled(selection.isEmpty || binding.macro.steps.count >= PulsarMacro.stepCapacity)

                Button {
                    MacroEditing.moveUp(ids: selection, in: &binding.macro.steps)
                } label: {
                    Label(L10n.string("Move up"), systemImage: "arrow.up")
                }
                .disabled(selection.isEmpty)

                Button {
                    MacroEditing.moveDown(ids: selection, in: &binding.macro.steps)
                } label: {
                    Label(L10n.string("Move down"), systemImage: "arrow.down")
                }
                .disabled(selection.isEmpty)

                Button {
                    MacroEditing.delete(ids: selection, from: &binding.macro.steps)
                    selection.removeAll()
                } label: {
                    Label(L10n.string("Delete"), systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }

            HStack(spacing: Theme.Space.medium) {
                Label(
                    L10n.format(
                        "%d of %d steps",
                        binding.macro.steps.count,
                        PulsarMacro.stepCapacity
                    ),
                    systemImage: "list.number"
                )
                Text(
                    L10n.format(
                        "%d / %d bytes",
                        MacroCodec.encodedLength(binding.macro),
                        MacroCodec.blockLength
                    )
                )
                Text(
                    L10n.format(
                        "Name: %d / %d bytes",
                        binding.macro.name.utf8.count,
                        PulsarMacro.nameCapacity
                    )
                )
                Text(L10n.format("Delays: %@", binding.macro.delaySummary))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var addEventMenu: some View {
        Menu {
            Menu(L10n.string("Keyboard")) {
                ForEach(PulsarInputCatalog.keyboardOptions) { option in
                    Button(option.label) {
                        append(option: option)
                    }
                }
            }
            Menu(L10n.string("Media")) {
                ForEach(PulsarInputCatalog.mediaOptions) { option in
                    Button(option.label) {
                        append(option: option)
                    }
                }
            }
            Divider()
            Menu(L10n.string("Mouse button")) {
                ForEach(PulsarMacro.MouseButtonMask.allCases, id: \.self) { button in
                    Button(button.label) { appendClick(button) }
                }
            }
            Divider()
            Button(L10n.string("Pointer movement")) {
                append(
                    step: PulsarMacro.Step(
                        kind: .movement,
                        action: .none,
                        value: 0,
                        delayMilliseconds: 0
                    )
                )
            }
            Menu(L10n.string("Wheel")) {
                Button(L10n.string("Up")) {
                    append(
                        step: PulsarMacro.Step(
                            kind: .wheel,
                            action: .none,
                            value: 1,
                            delayMilliseconds: 0
                        )
                    )
                }
                Button(L10n.string("Down")) {
                    append(
                        step: PulsarMacro.Step(
                            kind: .wheel,
                            action: .none,
                            value: 255,
                            delayMilliseconds: 0
                        )
                    )
                }
            }
        } label: {
            Label(L10n.string("Add Event"), systemImage: "plus")
        }
        .disabled(binding.macro.steps.count >= PulsarMacro.stepCapacity)
    }

    private var eventTable: some View {
        Table($binding.macro.steps, selection: $selection) {
            TableColumn(L10n.string("Event")) { $step in
                Label(
                    eventName(step),
                    systemImage: eventIcon(step)
                )
            }
            .width(min: 210, ideal: 250)

            TableColumn(L10n.string("Action")) { $step in
                if step.kind?.isPointerEvent == true, step.kind != .mouseButton {
                    Text("—")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $step.action) {
                        Text(PulsarMacro.Step.Action.press.label)
                            .tag(PulsarMacro.Step.Action.press)
                        Text(PulsarMacro.Step.Action.release.label)
                            .tag(PulsarMacro.Step.Action.release)
                    }
                    .labelsHidden()
                }
            }
            .width(min: 120, ideal: 150)

            TableColumn(L10n.string("Value")) { $step in
                valueEditor(for: $step)
            }
            .width(min: 150, ideal: 200)

            TableColumn(L10n.string("Delay")) { $step in
                HStack(spacing: Theme.Space.tight) {
                    TextField("", value: delayBinding(for: $step), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    Text("ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(delayLabel(step.delayMilliseconds))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 150, ideal: 180)
        }
        .frame(minHeight: 420)
    }

    private func eventName(_ step: PulsarMacro.Step) -> String {
        if step.kind == .mouseButton {
            let button = PulsarMacro.MouseButtonMask(rawValue: step.value)?.label
                ?? L10n.string("Unavailable button")
            return L10n.format(
                "%@ — %@",
                step.action == .press ? L10n.string("Mouse down") : L10n.string("Mouse up"),
                button
            )
        }
        if let kind = step.kind,
           [.modifier, .key, .media, .menuKey].contains(kind) {
            let key = PulsarShortcut.Key(kind: kind, value: step.value)
            return PulsarInputCatalog.option(for: key)?.label
                ?? L10n.string("Unavailable input")
        }
        if step.kind == .movement { return L10n.string("Pointer movement") }
        if step.kind == .wheel { return L10n.string("Wheel") }
        return L10n.string("Unavailable event")
    }

    private func eventIcon(_ step: PulsarMacro.Step) -> String {
        step.kind == .mouseButton ? "computermouse" : "keyboard"
    }

    @ViewBuilder
    private func valueEditor(for step: Binding<PulsarMacro.Step>) -> some View {
        switch step.wrappedValue.kind {
        case .modifier, .key, .media, .menuKey:
            inputPicker(for: step)
        case .mouseButton:
            Picker("", selection: Binding(
                get: { step.wrappedValue.value },
                set: { step.wrappedValue.value = $0 }
            )) {
                ForEach(PulsarMacro.MouseButtonMask.allCases, id: \.self) { button in
                    Text(button.label).tag(button.rawValue)
                }
            }
            .labelsHidden()
        case .movement:
            movementEditor(for: step)
        case .wheel:
            Picker("", selection: Binding(
                get: { step.wrappedValue.value },
                set: { step.wrappedValue.value = $0 }
            )) {
                Text(L10n.string("Up")).tag(1)
                Text(L10n.string("Down")).tag(255)
            }
            .labelsHidden()
        case nil:
            Text(L10n.string("Unavailable event"))
                .foregroundStyle(.orange)
        }
    }

    private func inputPicker(for step: Binding<PulsarMacro.Step>) -> some View {
        let kind = step.wrappedValue.kind ?? .key
        let options = PulsarInputCatalog.allOptions.filter { $0.kind == kind }
        let unavailableID = "unavailable-\(step.wrappedValue.id)"
        return Picker("", selection: Binding(
            get: {
                let key = PulsarShortcut.Key(kind: kind, value: step.wrappedValue.value)
                return PulsarInputCatalog.option(for: key)?.id ?? unavailableID
            },
            set: { id in
                guard let option = options.first(where: { $0.id == id }) else { return }
                step.wrappedValue.value = option.value
            }
        )) {
            let key = PulsarShortcut.Key(kind: kind, value: step.wrappedValue.value)
            Text(PulsarInputCatalog.label(for: key)).tag(unavailableID)
            ForEach(options) { option in
                Text(option.label).tag(option.id)
            }
        }
        .labelsHidden()
    }

    private func movementEditor(for step: Binding<PulsarMacro.Step>) -> some View {
        let movement = MacroCodec.movement(from: step.wrappedValue.value)
        return HStack(spacing: Theme.Space.tight) {
            axisField("X", value: movement.x) { value in
                step.wrappedValue.value = MacroCodec.movementValue(x: value, y: movement.y)
            }
            axisField("Y", value: movement.y) { value in
                step.wrappedValue.value = MacroCodec.movementValue(x: movement.x, y: value)
            }
        }
    }

    private func axisField(
        _ label: String,
        value: Int,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("", value: Binding(
                get: { value },
                set: { onChange(max(-127, min(127, $0))) }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 48)
            .monospacedDigit()
        }
    }

    private func delayBinding(for step: Binding<PulsarMacro.Step>) -> Binding<Int> {
        Binding(
            get: { step.wrappedValue.delayMilliseconds },
            set: { step.wrappedValue.delayMilliseconds = max(0, min(0xFFFF, $0)) }
        )
    }

    private func delayLabel(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return L10n.format("(%d ms)", milliseconds) }
        return String(format: "(%.1f s)", Double(milliseconds) / 1_000)
    }

    private func append(option: PulsarInputOption) {
        append(step: PulsarMacro.Step(
            kind: option.kind,
            action: .press,
            value: option.value,
            delayMilliseconds: 10
        ))
    }

    private func append(step: PulsarMacro.Step) {
        let steps = [step]
        guard MacroEditing.insert(
            steps,
            into: &binding.macro.steps,
            after: selection
        ) else { return }
        selection = Set(steps.map(\.id))
    }

    private func appendClick(_ button: PulsarMacro.MouseButtonMask) {
        guard binding.macro.steps.count + 2 <= PulsarMacro.stepCapacity else { return }
        let steps = [
            PulsarMacro.Step(
                kind: .mouseButton,
                action: .press,
                value: button.rawValue,
                delayMilliseconds: 0
            ),
            PulsarMacro.Step(
                kind: .mouseButton,
                action: .release,
                value: button.rawValue,
                delayMilliseconds: 0
            ),
        ]
        let inserted = steps
        guard MacroEditing.insert(inserted, into: &binding.macro.steps, after: selection) else { return }
        selection = Set(inserted.map(\.id))
    }
}
