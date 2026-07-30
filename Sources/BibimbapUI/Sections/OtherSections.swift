import BibimbapFeatures
import BibimbapLocalization
import PulsarProtocol
import SwiftUI

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
                        model.draft.buttons.count,
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

    private var buttonMap: some View {
        DeviceButtonMap(
            model: model,
            assignments: model.draft.buttons,
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

                ForEach($model.draft.buttons) { $button in
                    PremiumRow(
                        label: buttonRole(button.index),
                        detail: L10n.format("Button %d", button.index + 1),
                        showsDivider: button.index != model.draft.buttons.last?.index
                    ) {
                        Picker("", selection: Binding(
                            get: { button.function },
                            set: { newFunction in
                                button.function = newFunction
                                button.parameter = defaultParameter(
                                    for: newFunction,
                                    buttonIndex: button.index
                                )
                            }
                        )) {
                            ForEach(assignableFunctions, id: \.self) { function in
                                Text(label(for: function)).tag(function)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    .padding(.horizontal, Theme.Space.small)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(
                                highlighted == button.index
                                    ? Color.accentColor.opacity(0.08)
                                    : Color.clear
                            )
                    )
                    .onHover { highlighted = $0 ? button.index : nil }
                }
            }
        }
    }

    private func defaultParameter(for function: PulsarKeyFunction, buttonIndex: Int) -> Int {
        switch function {
        case .macro: (buttonIndex << 8) | 1
        case .mouseButton: 1 << (buttonIndex + 8)
        case .dpiLock: 800
        case .disabled: 0
        default: 0x0100
        }
    }

    private var assignableFunctions: [PulsarKeyFunction] {
        [.mouseButton, .dpiSwitch, .dpiLock, .verticalScroll, .horizontalScroll,
         .rapidFire, .keyboardShortcut, .macro, .reportRateSwitch, .lighting,
         .profileSwitch, .disabled]
    }

    private func buttonRole(_ index: Int) -> String {
        switch index {
        case 0: L10n.string("Left Click")
        case 1: L10n.string("Right Click")
        case 2: L10n.string("Middle Click")
        case 3: L10n.string("Back")
        case 4: L10n.string("Forward")
        case 5: L10n.string("DPI Cycle")
        default: L10n.format("Button %d", index + 1)
        }
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

                PremiumRow(
                    label: L10n.string("Sleep after"),
                    detail: L10n.string("The selected delay is written to both firmware sleep timers.")
                ) {
                    Picker("", selection: $model.draft.sleepTimeCode) {
                        ForEach(DeviceSettings.supportedSleepTimeCodes, id: \.self) { code in
                            Text(DeviceSettings.sleepTimeLabel(for: code)).tag(code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
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
                            .foregroundStyle(.green)
                        }
                        PremiumRow(label: L10n.string("Polling capacity")) {
                            Text(reportRate(snapshot.connection.maximumReportRate))
                                .monospacedDigit()
                        }
                        PremiumRow(
                            label: L10n.string("Firmware"),
                            showsDivider: snapshot.dongleLighting != nil
                        ) {
                            Text(snapshot.dongleVersion ?? snapshot.firmwareVersion)
                                .monospacedDigit()
                        }
                        if let lighting = snapshot.dongleLighting {
                            PremiumRow(
                                label: L10n.string("Receiver lighting"),
                                detail: L10n.string("Turns off the receiver LEDs without changing their colors."),
                                showsDivider: false
                            ) {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { lighting.isEnabled },
                                        set: { enabled in
                                            Task { await model.setDongleLightEnabled(enabled) }
                                        }
                                    )
                                )
                                .labelsHidden()
                                .disabled(model.connection.isBusy)
                                .accessibilityLabel(L10n.string("Receiver lighting"))
                            }
                        }
                    }
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
        return signal >= 4 ? L10n.string("Excellent") : L10n.string("Connected")
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
            Image(dongleImageName(for: snapshot.identity.dongleType), bundle: .module)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(L10n.string("Pulsar wireless receiver"))
        }
    }

    private func dongleImageName(for type: Int) -> String {
        switch type {
        case 1:
            "dongle-b"
        case 2, 4:
            "dongle-a"
        default:
            "dongle-c"
        }
    }

}
