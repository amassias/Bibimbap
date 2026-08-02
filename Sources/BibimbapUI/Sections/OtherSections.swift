import AppKit
import BibimbapFeatures
import BibimbapLocalization
import PulsarCatalog
import PulsarProtocol
import SwiftUI

/// Assets des receivers embarqués, choisis d'après la capacité réellement annoncée.
///
/// Le X2 CrazyLight validé avec le protocole sans fil expose le receiver 8K : l'asset
/// `dongle-c` est la vue compacte de ce boîtier. Le type de dongle du handshake décrit
/// des capacités de commandes, pas une référence graphique stable ; le plafond de
/// polling est donc le meilleur repère disponible pour l'illustration.
enum ReceiverArtwork {
    static func imageName(for connection: HIDConnectionSummary) -> String {
        connection.maximumReportRate >= 8_000 ? "dongle-c" : "dongle-a"
    }
}

// MARK: - Overview B

struct OverviewSection: View {
    @Bindable var model: AppModel

    var body: some View {
        if let snapshot = model.snapshot {
            VStack(alignment: .leading, spacing: Theme.Space.xlarge) {
                PremiumSectionHeader(title: L10n.string("Overview"))

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.xlarge) {
                        mouseHero(snapshot)
                            .frame(maxWidth: .infinity)
                        currentSetup(snapshot)
                            .frame(width: 330)
                    }

                    VStack(spacing: Theme.Space.xlarge) {
                        mouseHero(snapshot)
                        currentSetup(snapshot)
                    }
                }

                HStack(spacing: Theme.Space.medium) {
                    QuickAction(
                        systemImage: "gauge.with.dots.needle.50percent",
                        title: L10n.string("Tune performance"),
                        detail: L10n.string("Adjust DPI, polling rate and sensor behavior")
                    ) { model.section = .performance }

                    QuickAction(
                        systemImage: "computermouse",
                        title: L10n.string("Customize buttons"),
                        detail: L10n.string("Remap the controls available on this model")
                    ) { model.section = .customize }

                    QuickAction(
                        systemImage: "macwindow.badge.plus",
                        title: L10n.string("Create macro"),
                        detail: L10n.string("Record and assign repeatable actions")
                    ) { model.section = .macros }
                }
            }
        }
    }

    private func mouseHero(_ snapshot: DeviceSnapshot) -> some View {
        PremiumPanel {
            HStack(spacing: Theme.Space.xlarge) {
                ZStack {
                    Circle()
                        .stroke(PremiumPalette.hairline.opacity(0.68), style: StrokeStyle(lineWidth: 1, dash: [3, 7]))
                        .frame(width: 286, height: 286)

                    DeviceArtwork(model: model, maximumWidth: 205, maximumHeight: 265)
                        .frame(width: 220, height: 286)

                    VStack {
                        Spacer()
                        PremiumStatusDot(label: L10n.string("Connected"))
                            .padding(.bottom, Theme.Space.small)
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Space.xlarge) {
                    PremiumMetric(
                        systemImage: "battery.100percent",
                        label: L10n.string("Battery"),
                        value: snapshot.battery.map { "\($0.percentage)%" } ?? "—",
                        tint: .green
                    )
                    PremiumMetric(
                        systemImage: snapshot.connection.isWired ? "cable.connector" : "wifi",
                        label: L10n.string("Connection"),
                        value: snapshot.connection.label
                    )
                    PremiumMetric(
                        systemImage: "dot.radiowaves.left.and.right",
                        label: L10n.string("Signal"),
                        value: signalLabel(snapshot.signalStrength)
                    )
                }
            }
            .frame(maxWidth: .infinity, minHeight: 336)
        }
    }

    private func currentSetup(_ snapshot: DeviceSnapshot) -> some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.string("Current setup"))
                    .font(.headline)
                    .padding(.bottom, Theme.Space.medium)

                setupRow(
                    icon: "scope",
                    label: L10n.string("Active DPI"),
                    value: activeDPI(snapshot.settings)
                )
                setupRow(
                    icon: "waveform.path.ecg",
                    label: L10n.string("Polling Rate"),
                    value: reportRate(snapshot.settings.reportRateHertz)
                )
                setupRow(
                    icon: "person.crop.circle",
                    label: L10n.string("Profile"),
                    value: snapshot.activeProfile.map { L10n.format("Profile %d", $0 + 1) } ?? "—"
                )
                setupRow(
                    icon: "checkmark.seal",
                    label: L10n.string("Firmware"),
                    value: snapshot.firmwareVersion,
                    showsDivider: false
                )
            }
        }
    }

    private func setupRow(
        icon: String,
        label: String,
        value: String,
        showsDivider: Bool = true
    ) -> some View {
        PremiumRow(label: label, showsDivider: showsDivider) {
            HStack(spacing: Theme.Space.small) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                Text(value)
                    .font(.body.weight(.medium).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func activeDPI(_ settings: DeviceSettings) -> String {
        guard settings.dpiStages.indices.contains(settings.activeStage) else { return "—" }
        return settings.dpiStages[settings.activeStage].x.formatted(.number)
    }

    private func reportRate(_ hertz: Int) -> String {
        hertz >= 1_000 ? "\(hertz / 1_000) kHz" : "\(hertz) Hz"
    }

    private func signalLabel(_ signal: Int?) -> String {
        guard let signal else { return L10n.string("Not reported") }
        return switch signal {
        case 4...: L10n.string("Excellent")
        case 3: L10n.string("Good")
        case 2: L10n.string("Fair")
        default: L10n.string("Weak")
        }
    }
}

// MARK: - Customize A

struct CustomizeSection: View {
    @Bindable var model: AppModel
    @State private var highlighted: Int?

    var body: some View {
        if model.snapshot != nil {
            VStack(alignment: .leading, spacing: Theme.Space.xlarge) {
                PremiumSectionHeader(
                    title: L10n.string("Customize"),
                    subtitle: L10n.format(
                        "%d configurable buttons detected for %@.",
                        buttons.count,
                        model.deviceDisplayName
                    )
                )

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.xlarge) {
                        buttonMap
                            .frame(width: 455)
                        assignmentsPanel
                            .frame(maxWidth: .infinity)
                    }

                    VStack(spacing: Theme.Space.xlarge) {
                        buttonMap
                        assignmentsPanel
                    }
                }
            }
        }
    }

    /// Une seule liste alimente la carte et les lignes d'affectation.
    private var buttons: [ButtonPresentation] { model.buttonPresentations }

    private var buttonMap: some View {
        DeviceButtonMap(
            model: model,
            buttons: buttons,
            highlighted: $highlighted,
            title: L10n.string("Button map")
        )
    }

    private var assignmentsPanel: some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L10n.string("Button assignments"))
                        .font(.headline)
                    Spacer()
                    Button(L10n.string("Restore defaults")) {
                        model.revert()
                    }
                    .buttonStyle(.link)
                    .disabled(!model.hasPendingChanges)
                }
                .padding(.bottom, Theme.Space.medium)

                ForEach(buttons) { button in
                    assignmentRow(button)
                }
            }
        }
    }

    /// La ligne écrit dans le brouillon via l'index firmware du bouton : sa position
    /// dans la liste suit l'ordre d'affichage et ne peut pas servir d'adresse.
    @ViewBuilder
    private func assignmentRow(_ button: ButtonPresentation) -> some View {
        if let position = model.draftButtonPosition(firmwareIndex: button.firmwareIndex) {
            let assignment = Binding<DeviceSettings.ButtonAssignment>(
                get: { model.draft.buttons[position] },
                set: { model.draft.buttons[position] = $0 }
            )
            PremiumRow(
                label: button.label,
                detail: button.numberLabel,
                showsDivider: button.firmwareIndex != buttons.last?.firmwareIndex
            ) {
                VStack(alignment: .trailing, spacing: Theme.Space.small) {
                    Picker("", selection: Binding(
                        get: { assignment.wrappedValue.function },
                        set: { newFunction in
                            var updated = assignment.wrappedValue
                            updated.function = newFunction
                            updated.parameter = defaultParameter(
                                for: newFunction,
                                firmwareIndex: button.firmwareIndex
                            )
                            if newFunction == .keyboardShortcut,
                               updated.shortcut == nil {
                                updated.shortcut = PulsarShortcut(keys: [])
                            }
                            assignment.wrappedValue = updated
                            if newFunction == .macro {
                                ensureMacro(
                                    slot: (updated.parameter >> 8) & 0xFF,
                                    repeatCount: updated.parameter & 0xFF
                                )
                            }
                        }
                    )) {
                        ForEach(assignableFunctions, id: \.self) { function in
                            Text(label(for: function)).tag(function)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)

                    parameterEditor(for: assignment)
                }
            }
            .padding(.horizontal, Theme.Space.small)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(
                        highlighted == button.firmwareIndex
                            ? Color.accentColor.opacity(0.08)
                            : Color.clear
                    )
            )
            .onHover { highlighted = $0 ? button.firmwareIndex : nil }
        }
    }

    @ViewBuilder
    private func parameterEditor(
        for button: Binding<DeviceSettings.ButtonAssignment>
    ) -> some View {
        switch ButtonParameterCodec.decode(
            function: button.wrappedValue.function,
            parameter: button.wrappedValue.parameter
        ) {
        case .disabled:
            Text(L10n.string("No parameter"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .mouseButton:
            mouseButtonEditor(for: button)
        case .dpiSwitch:
            dpiSwitchEditor(for: button)
        case .horizontalScroll:
            scrollEditor(for: button)
        case .verticalScroll:
            scrollEditor(for: button)
        case .rapidFire:
            rapidFireEditor(for: button)
        case .keyboardShortcut:
            ShortcutContextEditor(shortcut: shortcutBinding(for: button))
        case .macro:
            macroEditor(for: button)
        case .reportRateSwitch:
            fixedFunctionEditor(label: L10n.string("Cycle polling rate"))
        case .lighting:
            fixedFunctionEditor(label: L10n.string("Cycle lighting"))
        case .profileSwitch:
            fixedFunctionEditor(label: L10n.string("Cycle profile"))
        case .dpiLock:
            dpiLockEditor(for: button)
        case .unknown:
            VStack(alignment: .trailing, spacing: Theme.Space.hairline) {
                Text(L10n.string("Unsupported parameter"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(L10n.string("Reset to default")) {
                    button.wrappedValue.parameter = defaultParameter(
                        for: button.wrappedValue.function,
                        firmwareIndex: button.wrappedValue.index
                    )
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private func mouseButtonEditor(
        for button: Binding<DeviceSettings.ButtonAssignment>
    ) -> some View {
        Picker(L10n.string("Button"), selection: Binding(
            get: { button.wrappedValue.parameter >> 8 },
            set: { button.wrappedValue.parameter = $0 << 8 }
        )) {
            ForEach(PulsarMacro.MouseButtonMask.allCases, id: \.self) { mask in
                Text(mask.label).tag(mask.rawValue)
            }
        }
        .labelsHidden()
        .frame(width: 190)
    }

    private func dpiSwitchEditor(
        for button: Binding<DeviceSettings.ButtonAssignment>
    ) -> some View {
        Picker(L10n.string("DPI action"), selection: Binding(
            get: { button.wrappedValue.parameter },
            set: { button.wrappedValue.parameter = $0 }
        )) {
            ForEach(PulsarButtonParameter.DPISwitchMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode.rawValue)
            }
        }
        .labelsHidden()
        .frame(width: 190)
    }

    private func scrollEditor(
        for button: Binding<DeviceSettings.ButtonAssignment>
    ) -> some View {
        Picker(L10n.string("Direction"), selection: Binding(
            get: { button.wrappedValue.parameter },
            set: { button.wrappedValue.parameter = $0 }
        )) {
            ForEach(PulsarButtonParameter.ScrollDirection.allCases, id: \.self) { direction in
                Text(direction.label).tag(direction.rawValue)
            }
        }
        .labelsHidden()
        .frame(width: 190)
    }

    private func rapidFireEditor(
        for button: Binding<DeviceSettings.ButtonAssignment>
    ) -> some View {
        let fallbackTimes = 0
        let fallbackInterval = 50
        return VStack(alignment: .trailing, spacing: Theme.Space.hairline) {
            Stepper(value: Binding(
                get: {
                    if case .rapidFire(let times, _) = ButtonParameterCodec.decode(
                        function: .rapidFire,
                        parameter: button.wrappedValue.parameter
                    ) { return times }
                    return fallbackTimes
                },
                set: { newValue in
                    let interval = min(255, max(10, button.wrappedValue.parameter >> 8))
                    button.wrappedValue.parameter = interval << 8 | newValue
                }
            ), in: 0...3) {
                Text(L10n.string("Repeat count"))
                    .font(.caption)
            }
            Stepper(value: Binding(
                get: {
                    if case .rapidFire(_, let interval) = ButtonParameterCodec.decode(
                        function: .rapidFire,
                        parameter: button.wrappedValue.parameter
                    ) { return interval }
                    return fallbackInterval
                },
                set: { newValue in
                    let times = min(3, max(0, button.wrappedValue.parameter & 0xFF))
                    button.wrappedValue.parameter = newValue << 8 | times
                }
            ), in: 10...255) {
                Text(L10n.string("Interval (ms)"))
                    .font(.caption)
            }
        }
    }

    private func dpiLockEditor(
        for button: Binding<DeviceSettings.ButtonAssignment>
    ) -> some View {
        let minimum = model.capabilities?.minimumDPI ?? 50
        let maximum = model.capabilities?.maximumDPI ?? 32_000
        let step = max(1, model.snapshot?.family.dpi.step ?? 10)
        return Stepper(value: Binding(
            get: { button.wrappedValue.parameter },
            set: { value in
                guard let family = model.snapshot?.family,
                      let codec = DPICodec(family: family, catalog: .embedded),
                      let snapped = try? codec.snap(dpi: value)
                else {
                    button.wrappedValue.parameter = value
                    return
                }
                button.wrappedValue.parameter = snapped
            }
        ), in: minimum...maximum, step: step) {
            Text(L10n.format("%d DPI", button.wrappedValue.parameter))
                .font(.caption)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func macroEditor(
        for button: Binding<DeviceSettings.ButtonAssignment>
    ) -> some View {
        let slot = (button.wrappedValue.parameter >> 8) & 0xFF
        if let index = model.draft.macros.firstIndex(where: { $0.slot == slot }) {
            Stepper(value: $model.draft.macros[index].repeatCount, in: 1...255) {
                Text(L10n.format("Repeat %d×", model.draft.macros[index].repeatCount))
                    .font(.caption)
                    .monospacedDigit()
            }
            Button(L10n.string("Open macro editor")) {
                model.section = .macros
            }
            .buttonStyle(.link)
            .font(.caption)
        } else {
            VStack(alignment: .trailing, spacing: Theme.Space.hairline) {
                Text(L10n.string("No macro in this slot"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(L10n.string("Create macro")) {
                    ensureMacro(
                        slot: slot,
                        repeatCount: button.wrappedValue.parameter & 0xFF
                    )
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private func fixedFunctionEditor(label: String) -> some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func shortcutBinding(
        for button: Binding<DeviceSettings.ButtonAssignment>
    ) -> Binding<PulsarShortcut> {
        Binding(
            get: { button.wrappedValue.shortcut ?? PulsarShortcut(keys: []) },
            set: { button.wrappedValue.shortcut = $0 }
        )
    }

    private func defaultParameter(for function: PulsarKeyFunction, firmwareIndex: Int) -> Int {
        switch function {
        case .macro: (firmwareIndex << 8) | 1
        case .mouseButton: 1 << (firmwareIndex + 8)
        case .dpiSwitch: PulsarButtonParameter.DPISwitchMode.cycle.rawValue
        case .horizontalScroll, .verticalScroll: PulsarButtonParameter.ScrollDirection.positive.rawValue
        case .rapidFire: 50 << 8
        case .dpiLock: min(max(model.capabilities?.minimumDPI ?? 800, 800), model.capabilities?.maximumDPI ?? 800)
        case .disabled: 0
        case .keyboardShortcut, .reportRateSwitch, .lighting, .profileSwitch: 0
        }
    }

    private func ensureMacro(slot: Int, repeatCount: Int) {
        guard !model.draft.macros.contains(where: { $0.slot == slot }) else { return }
        model.draft.macros.append(
            DeviceSettings.MacroBinding(
                slot: slot,
                macro: PulsarMacro(
                    name: L10n.format("Macro %d", slot + 1),
                    steps: []
                ),
                repeatCount: max(1, min(255, repeatCount))
            )
        )
    }

    private var assignableFunctions: [PulsarKeyFunction] {
        [.mouseButton, .dpiSwitch, .dpiLock, .verticalScroll, .horizontalScroll,
         .rapidFire, .keyboardShortcut, .macro, .reportRateSwitch, .lighting,
         .profileSwitch, .disabled]
    }

    private func label(for function: PulsarKeyFunction) -> String {
        switch function {
        case .disabled: L10n.string("Disabled")
        case .mouseButton: L10n.string("Mouse button")
        case .dpiSwitch: L10n.string("DPI Cycle")
        case .horizontalScroll: L10n.string("Horizontal scroll")
        case .rapidFire: L10n.string("Rapid Fire")
        case .keyboardShortcut: L10n.string("Keyboard Shortcut")
        case .macro: L10n.string("Macro")
        case .reportRateSwitch: L10n.string("Polling Rate Cycle")
        case .lighting: L10n.string("Lighting")
        case .profileSwitch: L10n.string("Profile Cycle")
        case .dpiLock: L10n.string("DPI Lock")
        case .verticalScroll: L10n.string("Vertical scroll")
        }
    }
}

struct ShortcutContextEditor: View {
    @Binding var shortcut: PulsarShortcut

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.hairline) {
            if shortcut.keys.isEmpty {
                Text(L10n.string("No key selected"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                ForEach(Array(shortcut.keys.indices), id: \.self) { index in
                    HStack(spacing: Theme.Space.tight) {
                        inputPicker(at: index)
                        Button {
                            shortcut.keys.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.string("Remove input"))
                    }
                }
            }

            Menu {
                Menu(L10n.string("Keyboard")) {
                    ForEach(PulsarInputCatalog.keyboardOptions) { option in
                        Button(option.label) { append(option) }
                    }
                }
                Menu(L10n.string("Media")) {
                    ForEach(PulsarInputCatalog.mediaOptions) { option in
                        Button(option.label) { append(option) }
                    }
                }
            } label: {
                Label(L10n.string("Add input"), systemImage: "plus")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .disabled(shortcut.keys.count >= ShortcutCodec.maxKeys)

            Text(shortcut.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 250, alignment: .trailing)
    }

    private func inputPicker(at index: Int) -> some View {
        let unavailableID = "unavailable-\(index)"
        return Picker("", selection: Binding(
            get: {
                guard shortcut.keys.indices.contains(index),
                      let option = PulsarInputCatalog.option(for: shortcut.keys[index])
                else { return unavailableID }
                return option.id
            },
            set: { id in
                guard let option = PulsarInputCatalog.allOptions.first(where: { $0.id == id }),
                      shortcut.keys.indices.contains(index)
                else { return }
                shortcut.keys[index] = PulsarShortcut.Key(
                    kind: option.kind,
                    value: option.value
                )
            }
        )) {
            if shortcut.keys.indices.contains(index) {
                let key = shortcut.keys[index]
                Text(PulsarInputCatalog.label(for: key)).tag(unavailableID)
            }
            ForEach(PulsarInputCatalog.allOptions) { option in
                Text(option.label).tag(option.id)
            }
        }
        .labelsHidden()
        .frame(width: 205)
    }

    private func append(_ option: PulsarInputOption) {
        guard shortcut.keys.count < ShortcutCodec.maxKeys else { return }
        shortcut.keys.append(PulsarShortcut.Key(kind: option.kind, value: option.value))
    }
}

struct ButtonMarker: View {
    let number: Int
    let isHighlighted: Bool

    var body: some View {
        Text("\(number)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(isHighlighted ? .white : Color.accentColor)
            .frame(width: 22, height: 22)
            .background(
                Circle().fill(
                    isHighlighted
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(PremiumPalette.elevated)
                )
            )
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.25))
            .scaleEffect(isHighlighted ? 1.12 : 1)
            .animates(isHighlighted)
    }
}

// MARK: - Power A

struct PowerSection: View {
    @Bindable var model: AppModel

    var body: some View {
        if let capabilities = model.capabilities, let snapshot = model.snapshot {
            VStack(alignment: .leading, spacing: Theme.Space.xlarge) {
                PremiumSectionHeader(title: L10n.string("Power & Dongle"))

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.xlarge) {
                        batteryPanel(snapshot, capabilities: capabilities)
                        receiverPanel(snapshot, capabilities: capabilities)
                    }
                    VStack(spacing: Theme.Space.xlarge) {
                        batteryPanel(snapshot, capabilities: capabilities)
                        receiverPanel(snapshot, capabilities: capabilities)
                    }
                }

                powerBehavior(snapshot, capabilities: capabilities)
            }
        }
    }

    private func batteryPanel(
        _ snapshot: DeviceSnapshot,
        capabilities: DeviceCapabilities
    ) -> some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.string("Battery"))
                    .font(.headline)
                    .padding(.bottom, Theme.Space.large)

                if let battery = snapshot.battery {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(battery.percentage)%")
                            .font(.system(size: 42, weight: .light, design: .rounded))
                            .monospacedDigit()
                        Spacer()
                        VStack(alignment: .trailing, spacing: Theme.Space.tight) {
                            Text(L10n.string("Voltage"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(battery.millivolts) mV")
                                .font(.body.monospacedDigit())
                        }
                    }
                    ProgressView(value: Double(battery.percentage), total: 100)
                        .tint(battery.percentage < 15 ? .red : .green)
                        .padding(.bottom, Theme.Space.large)
                } else {
                    Text(L10n.string("Battery data is not reported over USB."))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, Theme.Space.large)
                }

                if capabilities.supportsPerformanceLevel {
                    PremiumRow(
                        label: L10n.string("Performance level"),
                        detail: L10n.string("The selected level is written to both firmware sleep timers.")
                    ) {
                        Picker("", selection: performanceLevelBinding) {
                            ForEach(capabilities.performanceLevelOptions, id: \.self) { code in
                                Text(DeviceSettings.sleepTimeLabel(for: code)).tag(code)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                } else {
                    PremiumRow(
                        label: L10n.string("Sleep after"),
                        detail: L10n.string("The selected delay is written to the firmware sleep timer.")
                    ) {
                        Picker("", selection: $model.draft.sleepTimeCode) {
                            ForEach(DeviceSettings.supportedSleepTimeCodes, id: \.self) { code in
                                Text(DeviceSettings.sleepTimeLabel(for: code)).tag(code)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }

                PremiumRow(
                    label: L10n.string("Power saving threshold"),
                    showsDivider: capabilities.supportsPerformanceMode
                ) {
                    Picker("", selection: $model.draft.powerSaveBatteryPercent) {
                        Text(L10n.string("Off")).tag(0)
                        ForEach([10, 15, 20, 30, 40, 50], id: \.self) { percent in
                            Text("\(percent)%").tag(percent)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                if capabilities.supportsPerformanceMode {
                    PremiumRow(
                        label: L10n.string("Performance mode"),
                        showsDivider: false
                    ) {
                        Toggle("", isOn: $model.draft.performanceMode)
                            .labelsHidden()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func receiverPanel(
        _ snapshot: DeviceSnapshot,
        capabilities: DeviceCapabilities
    ) -> some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.string("Wireless receiver"))
                    .font(.headline)
                    .padding(.bottom, Theme.Space.large)

                HStack(alignment: .center, spacing: Theme.Space.xlarge) {
                    dongleArtwork(snapshot)
                        .frame(width: 120, height: 150)

                    VStack(spacing: 0) {
                        PremiumRow(label: L10n.string("Connection")) {
                            Text(snapshot.connection.label)
                        }
                        PremiumRow(label: L10n.string("Signal")) {
                            Label(
                                signalLabel(snapshot.signalStrength),
                                systemImage: "circle.fill"
                            )
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(signalColor(snapshot.signalStrength))
                        }
                        PremiumRow(label: L10n.string("Polling capacity")) {
                            Text(reportRate(snapshot.connection.maximumReportRate))
                                .monospacedDigit()
                        }
                        PremiumRow(
                            label: L10n.string("Firmware"),
                            showsDivider: receiverControls(for: capabilities).isEmpty
                        ) {
                            Text(snapshot.dongleVersion ?? snapshot.firmwareVersion)
                                .monospacedDigit()
                        }
                    }
                }

                if model.draft.receiver != nil, !receiverControls(for: capabilities).isEmpty {
                    ReceiverSettingsRows(
                        settings: Binding(
                            get: { model.draft.receiver ?? ReceiverSettings() },
                            set: { model.draft.receiver = $0 }
                        ),
                        capabilities: capabilities.receiver
                    )
                    .padding(.top, Theme.Space.small)
                }

                Divider()
                    .padding(.vertical, Theme.Space.medium)

                HStack {
                    pairingStatus
                    Spacer()
                    Button(pairingButtonLabel) {
                        switch model.pairing {
                        case .searching:
                            model.cancelPairing()
                        default:
                            Task { await model.startPairing() }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var performanceLevelBinding: Binding<Int> {
        Binding(
            get: { model.draft.performanceLevel },
            set: { value in
                model.draft.performanceLevel = value
                model.draft.sleepTimeCode = value
            }
        )
    }

    private func powerBehavior(
        _ snapshot: DeviceSnapshot,
        capabilities: DeviceCapabilities
    ) -> some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.string("Power behavior"))
                    .font(.headline)
                    .padding(.bottom, Theme.Space.medium)

                HStack(spacing: Theme.Space.section) {
                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        Text(L10n.string("Current mode"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(snapshot.connection.isWired
                             ? L10n.string("Charge and play")
                             : L10n.string("Wireless"))
                    }

                    Divider()
                        .frame(height: 38)

                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        Text(L10n.string("DPI lighting"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.draft.dpiEffect.mode.label)
                    }

                    Spacer()

                    if capabilities.supportsLongDistance {
                        Toggle(
                            L10n.string("Long range mode"),
                            isOn: $model.draft.longDistance
                        )
                        .toggleStyle(.switch)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pairingStatus: some View {
        switch model.pairing {
        case .idle:
            Text(L10n.string("Ready to pair"))
                .foregroundStyle(.secondary)
        case .searching(let seconds):
            Label("\(seconds) s", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color.accentColor)
        case .succeeded:
            Label(L10n.string("Paired"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var pairingButtonLabel: String {
        if case .searching = model.pairing {
            return L10n.string("Cancel")
        }
        return L10n.string("Pair device")
    }

    private func signalLabel(_ signal: Int?) -> String {
        guard let signal else { return L10n.string("Not reported") }
        return switch signal {
        case 4...: L10n.string("Excellent")
        case 3: L10n.string("Good")
        case 2: L10n.string("Fair")
        default: L10n.string("Weak")
        }
    }

    private func signalColor(_ signal: Int?) -> Color {
        guard let signal else { return .secondary }
        return switch signal {
        case 4...: .green
        case 2...3: .yellow
        default: .orange
        }
    }

    private func reportRate(_ hertz: Int) -> String {
        hertz >= 1_000 ? L10n.format("Up to %d kHz", hertz / 1_000) : "\(hertz) Hz"
    }

    @ViewBuilder
    private func dongleArtwork(_ snapshot: DeviceSnapshot) -> some View {
        if snapshot.connection.isWired {
            Image(systemName: "cable.connector")
                .font(.system(size: 58, weight: .ultraLight))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.string("Wired connection"))
        } else {
            let imageName = ReceiverArtwork.imageName(for: snapshot.connection)
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.group)
                    .fill(PremiumPalette.canvas.opacity(0.46))
                RoundedRectangle(cornerRadius: Theme.Radius.group)
                    .strokeBorder(PremiumPalette.hairline.opacity(0.5), lineWidth: 0.5)

                if let image = Bundle.module.image(forResource: imageName) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                        .shadow(color: .black.opacity(0.35), radius: 7, y: 3)
                } else {
                    // Le fallback reste explicite si une distribution omet par erreur
                    // une ressource SPM : le panneau ne redevient pas silencieusement vide.
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(L10n.string("Pulsar wireless receiver"))
        }
    }

}

/// Éditeur des commandes récepteur dont les getters ont effectivement répondu.
/// Toutes les mutations restent dans `DeviceSettings` : la barre Apply du modèle
/// construit ensuite le plan, écrit, puis relit chaque commande.
private struct ReceiverSettingsRows: View {
    @Binding var settings: ReceiverSettings
    let capabilities: ReceiverCapabilities

    private let rgbModes = [0, 1, 2, 3]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if capabilities.supportsRGBLighting, settings.rgbLighting != nil {
                Text(L10n.string("Receiver lighting"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.bottom, Theme.Space.tight)

                PremiumRow(
                    label: L10n.string("Enabled"),
                    detail: L10n.string("Turns off the receiver LEDs without changing their colors.")
                ) {
                    Toggle("", isOn: rgbEnabledBinding)
                        .labelsHidden()
                }

                PremiumRow(label: L10n.string("Mode")) {
                    Picker("", selection: rgbModeBinding) {
                        ForEach(rgbModes, id: \.self) { mode in
                            Text(rgbModeLabel(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                ForEach(0..<3, id: \.self) { colorIndex in
                    PremiumRow(
                        label: L10n.format("Color %d", colorIndex + 1),
                        showsDivider: colorIndex != 2
                    ) {
                        ColorPicker(
                            "",
                            selection: rgbColorBinding(colorIndex * 3),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                    }
                }
            }

            if capabilities.supportsEffect, settings.effect != nil {
                Text(L10n.string("Receiver effect"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, Theme.Space.medium)
                    .padding(.bottom, Theme.Space.tight)

                PremiumRow(label: L10n.string("Effect")) {
                    Picker("", selection: effectIntBinding(\.mode)) {
                        ForEach(ReceiverLightEffect.supportedModes, id: \.self) { mode in
                            Text(effectModeLabel(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                PremiumRow(label: L10n.string("Color")) {
                    ColorPicker(
                        "",
                        selection: effectColorBinding,
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }

                PremiumRow(label: L10n.string("Speed")) {
                    valueSlider(binding: effectIntBinding(\.speed))
                }

                PremiumRow(label: L10n.string("Brightness"), showsDivider: false) {
                    valueSlider(binding: effectIntBinding(\.brightness))
                }
            }

            if capabilities.supportsDPILighting, settings.dpiLightEnabled != nil {
                PremiumRow(
                    label: L10n.string("DPI lighting"),
                    detail: L10n.string("Controls the indicator on the receiver.")
                ) {
                    Toggle("", isOn: dpiLightBinding)
                        .labelsHidden()
                }
            }

            if capabilities.supportsButtonMode, settings.buttonMode != nil {
                Text(L10n.string("Receiver button"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, Theme.Space.medium)
                    .padding(.bottom, Theme.Space.tight)

                PremiumRow(label: L10n.string("Function"), showsDivider: false) {
                    Picker("", selection: buttonModeBinding) {
                        ForEach(capabilities.buttonModeOptions, id: \.self) { mode in
                            Text(buttonFunctionLabel(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            if capabilities.supportsButtonFunctions, !settings.buttonFunctions.isEmpty {
                Text(L10n.string("Receiver button effects"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, Theme.Space.medium)
                    .padding(.bottom, Theme.Space.tight)

                ForEach($settings.buttonFunctions) { $function in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L10n.format("Button %d", function.index + 1))
                            .font(.caption.weight(.semibold))
                            .padding(.top, Theme.Space.tight)

                        PremiumRow(label: L10n.string("Mode")) {
                            Picker("", selection: $function.mode) {
                                ForEach(ReceiverLightEffect.supportedModes, id: \.self) { mode in
                                    Text(receiverFunctionModeLabel(mode)).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }

                        PremiumRow(label: L10n.string("Color")) {
                            ColorPicker(
                                "",
                                selection: buttonColorBinding(function.index),
                                supportsOpacity: false
                            )
                            .labelsHidden()
                        }

                        PremiumRow(label: L10n.string("Speed")) {
                            valueSlider(binding: buttonIntBinding(function.index, \.speed))
                        }

                        PremiumRow(
                            label: L10n.string("Brightness"),
                            showsDivider: function.id != settings.buttonFunctions.last?.id
                        ) {
                            valueSlider(binding: buttonIntBinding(function.index, \.brightness))
                        }
                    }
                }
            }
        }
    }

    private var rgbEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.rgbLighting?.isEnabled ?? false },
            set: { enabled in
                guard var lighting = settings.rgbLighting else { return }
                lighting = lighting.setting(enabled: enabled)
                settings.rgbLighting = lighting
            }
        )
    }

    private var rgbModeBinding: Binding<Int> {
        Binding(
            get: { Int(settings.rgbLighting?.mode ?? 0) },
            set: { mode in
                guard var lighting = settings.rgbLighting else { return }
                lighting.mode = UInt8(clamping: mode)
                settings.rgbLighting = lighting
            }
        )
    }

    private func rgbColorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                guard let lighting = settings.rgbLighting,
                      lighting.colors.indices.contains(index + 2) else { return .white }
                let color = CatalogColor(
                    red: Int(lighting.colors[index]),
                    green: Int(lighting.colors[index + 1]),
                    blue: Int(lighting.colors[index + 2])
                )
                return color.swiftUIColor
            },
            set: { color in
                guard var lighting = settings.rgbLighting,
                      lighting.colors.indices.contains(index + 2) else { return }
                let catalogColor = CatalogColor(color)
                lighting.colors[index] = UInt8(clamping: catalogColor.red)
                lighting.colors[index + 1] = UInt8(clamping: catalogColor.green)
                lighting.colors[index + 2] = UInt8(clamping: catalogColor.blue)
                settings.rgbLighting = lighting
            }
        )
    }

    private func effectIntBinding(
        _ keyPath: WritableKeyPath<ReceiverLightEffect, Int>
    ) -> Binding<Int> {
        Binding(
            get: { settings.effect?[keyPath: keyPath] ?? 0 },
            set: { value in
                guard var effect = settings.effect else { return }
                effect[keyPath: keyPath] = value
                settings.effect = effect
            }
        )
    }

    private var effectColorBinding: Binding<Color> {
        Binding(
            get: { settings.effect?.color.swiftUIColor ?? .white },
            set: { color in
                guard var effect = settings.effect else { return }
                effect.color = CatalogColor(color)
                settings.effect = effect
            }
        )
    }

    private var dpiLightBinding: Binding<Bool> {
        Binding(
            get: { settings.dpiLightEnabled ?? false },
            set: { settings.dpiLightEnabled = $0 }
        )
    }

    private var buttonModeBinding: Binding<Int> {
        Binding(
            get: { settings.buttonMode ?? 0 },
            set: { settings.buttonMode = $0 }
        )
    }

    private func buttonColorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                settings.buttonFunctions.first(where: { $0.index == index })?.color.swiftUIColor
                    ?? .white
            },
            set: { color in
                guard let position = settings.buttonFunctions.firstIndex(where: { $0.index == index })
                else { return }
                settings.buttonFunctions[position].color = CatalogColor(color)
            }
        )
    }

    private func buttonIntBinding(
        _ index: Int,
        _ keyPath: WritableKeyPath<ReceiverButtonFunction, Int>
    ) -> Binding<Int> {
        Binding(
            get: {
                settings.buttonFunctions.first(where: { $0.index == index })?[keyPath: keyPath] ?? 0
            },
            set: { value in
                guard let position = settings.buttonFunctions.firstIndex(where: { $0.index == index })
                else { return }
                settings.buttonFunctions[position][keyPath: keyPath] = value
            }
        )
    }

    private func valueSlider(binding: Binding<Int>) -> some View {
        HStack(spacing: Theme.Space.small) {
            Slider(
                value: Binding(
                    get: { Double(binding.wrappedValue) },
                    set: { binding.wrappedValue = Int($0.rounded()) }
                ),
                in: 0...9,
                step: 1
            )
            .frame(width: 112)
            Text("\(binding.wrappedValue + 1)")
                .monospacedDigit()
                .frame(width: 24, alignment: .trailing)
        }
    }

    private func rgbModeLabel(_ mode: Int) -> String {
        switch mode {
        case 0: L10n.string("Off")
        case 1: L10n.string("Rainbow")
        case 2: L10n.string("Breathing")
        case 3: L10n.string("Fixed")
        default: L10n.format("Mode %d", mode)
        }
    }

    private func effectModeLabel(_ mode: Int) -> String {
        switch mode {
        case 0: L10n.string("Off")
        case 1: L10n.string("Rainbow")
        case 2: L10n.string("Breathing")
        case 3: L10n.string("Fixed")
        case 4: L10n.string("Neon")
        case 5: L10n.string("Rainbow breathing")
        case 6: L10n.string("Fixed rainbow")
        default: L10n.format("Mode %d", mode)
        }
    }

    private func receiverFunctionModeLabel(_ mode: Int) -> String {
        L10n.format("Mode %d", mode)
    }

    private func buttonFunctionLabel(_ mode: Int) -> String {
        switch mode {
        case 0: L10n.string("Off")
        case 1: L10n.string("Polling rate")
        case 2: L10n.string("Lift-off distance")
        case 3: L10n.string("Debounce")
        case 4: L10n.string("Motion Sync")
        case 5: L10n.string("Profile")
        case 6: L10n.string("Performance mode")
        case 7: L10n.string("Turbo mode")
        case 8: L10n.string("Fan mode")
        default: L10n.format("Function %d", mode)
        }
    }
}
