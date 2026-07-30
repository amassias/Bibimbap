import BibimbapFeatures
import BibimbapLocalization
import SwiftUI

/// Performance reprend la composition validée : réglages de précision à gauche,
/// capteur et mouvement dans un inspecteur stable à droite.
struct PerformanceSection: View {
    @Bindable var model: AppModel

    var body: some View {
        if let capabilities = model.capabilities {
            VStack(alignment: .leading, spacing: Theme.Space.xlarge) {
                PremiumSectionHeader(title: L10n.string("Performance"))

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.large) {
                        mainColumn(capabilities)
                            .frame(maxWidth: .infinity)
                        inspectorColumn(capabilities)
                            .frame(width: 400)
                    }

                    VStack(spacing: Theme.Space.xlarge) {
                        mainColumn(capabilities)
                        inspectorColumn(capabilities)
                    }
                }
            }
        }
    }

    private func mainColumn(_ capabilities: DeviceCapabilities) -> some View {
        VStack(spacing: Theme.Space.large) {
            dpiPanel(capabilities)
            pollingPanel(capabilities)
            trackingPanel(capabilities)
        }
    }

    private func inspectorColumn(_ capabilities: DeviceCapabilities) -> some View {
        VStack(spacing: Theme.Space.large) {
            sensorPanel(capabilities)
            if capabilities.supportsRotation {
                rotationPanel
            }
            dpiBehaviorPanel
        }
    }

    // MARK: DPI

    private func dpiPanel(_ capabilities: DeviceCapabilities) -> some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: Theme.Space.large) {
                HStack {
                    Text(L10n.string("DPI Stages"))
                        .font(.headline)
                    Spacer()
                    Menu {
                        ForEach(1...capabilities.maximumStages, id: \.self) { count in
                            Button(L10n.format("%d stages", count)) {
                                model.draft.enabledStageCount = count
                                model.draft.activeStage = min(
                                    model.draft.activeStage,
                                    count - 1
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: Theme.Space.snug) {
                            Text(L10n.string("Stages"))
                                .foregroundStyle(.secondary)
                            Text("\(model.draft.enabledStageCount)")
                                .monospacedDigit()
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                HStack(spacing: Theme.Space.small) {
                    ForEach(
                        model.draft.dpiStages.prefix(model.draft.enabledStageCount)
                    ) { stage in
                        if let index = model.draft.dpiStages.firstIndex(
                            where: { $0.index == stage.index }
                        ) {
                            DPIStageCard(
                                stage: $model.draft.dpiStages[index],
                                isActive: model.draft.activeStage == stage.index
                            ) {
                                model.draft.activeStage = stage.index
                            }
                        }
                    }
                }

                if model.draft.dpiStages.indices.contains(model.draft.activeStage) {
                    activeDPISlider(capabilities)
                }
            }
        }
    }

    private func activeDPISlider(_ capabilities: DeviceCapabilities) -> some View {
        let activeIndex = model.draft.activeStage
        let stage = $model.draft.dpiStages[activeIndex]

        return VStack(spacing: Theme.Space.small) {
            HStack {
                Text(capabilities.minimumDPI.formatted(.number))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(capabilities.maximumDPI.formatted(.number))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Theme.Space.medium) {
                Slider(
                    value: Binding(
                        get: { Double(stage.wrappedValue.x) },
                        set: { rawValue in
                            let value = Int(rawValue.rounded())
                            let symmetric = stage.wrappedValue.isSymmetric
                            stage.wrappedValue.x = value
                            if symmetric { stage.wrappedValue.y = value }
                        }
                    ),
                    in: Double(capabilities.minimumDPI)...Double(capabilities.maximumDPI),
                    step: 50
                )

                TextField(
                    "",
                    value: Binding(
                        get: { stage.wrappedValue.x },
                        set: { value in
                            let symmetric = stage.wrappedValue.isSymmetric
                            stage.wrappedValue.x = value
                            if symmetric { stage.wrappedValue.y = value }
                        }
                    ),
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 96)
            }
        }
    }

    // MARK: Polling and tracking

    private func pollingPanel(_ capabilities: DeviceCapabilities) -> some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: Theme.Space.medium) {
                HStack {
                    Text(L10n.string("Polling Rate"))
                        .font(.headline)
                    Spacer()
                    if let connection = model.snapshot?.connection {
                        Text(
                            L10n.format(
                                "Maximum %d Hz via %@.",
                                connection.maximumReportRate,
                                connection.label
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: Theme.Space.small) {
                    ForEach(capabilities.availableReportRates, id: \.self) { rate in
                        SelectableValueButton(
                            title: reportRate(rate),
                            isSelected: model.draft.reportRateHertz == rate
                        ) {
                            model.draft.reportRateHertz = rate
                        }
                    }
                }
            }
        }
    }

    private func trackingPanel(_ capabilities: DeviceCapabilities) -> some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                PrecisionSlider(
                    title: L10n.string("Lift-Off Distance"),
                    help: L10n.string("Height at which the sensor stops tracking."),
                    value: $model.draft.liftOffMillimetres,
                    range: 1...2,
                    format: { "\($0) mm" }
                )

                Divider()

                PrecisionSlider(
                    title: L10n.string("Debounce Time"),
                    help: debounceHelp(capabilities),
                    value: $model.draft.debounceMilliseconds,
                    range: 0...capabilities.maximumDebounce,
                    format: { "\($0) ms" }
                )
            }
        }
    }

    // MARK: Inspector

    private func sensorPanel(_ capabilities: DeviceCapabilities) -> some View {
        let toggles: [(String, String, Binding<Bool>)] = [
            (capabilities.supportsMotionSync, L10n.string("Motion Sync"),
             L10n.string("Synchronizes sensor data with each report."),
             $model.draft.motionSync),
            (capabilities.supportsRippleControl, L10n.string("Ripple Control"),
             L10n.string("Smooths out tracking micro-vibrations."),
             $model.draft.rippleControl),
            (capabilities.supportsAngleSnap, L10n.string("Angle Snap"),
             L10n.string("Constrains cursor movement to the axes."),
             $model.draft.angleSnap),
            (capabilities.supportsPerformanceMode, L10n.string("Performance mode"),
             L10n.string("Raises the sensor scan rate."),
             $model.draft.performanceMode),
        ].filter(\.0).map { ($0.1, $0.2, $0.3) }

        return PremiumPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.string("Sensor & Motion"))
                    .font(.headline)
                    .padding(.bottom, Theme.Space.medium)

                ForEach(Array(toggles.enumerated()), id: \.offset) { index, item in
                    PremiumRow(
                        label: item.0,
                        detail: item.1,
                        showsDivider: index != toggles.count - 1
                    ) {
                        Toggle("", isOn: item.2)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    private var rotationPanel: some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: Theme.Space.large) {
                HStack {
                    Text(L10n.string("Mouse Rotation Calibration"))
                        .font(.headline)
                    Spacer()
                    Text("\(model.draft.rotationDegrees)°")
                        .font(.title3.weight(.medium).monospacedDigit())
                }

                ZStack {
                    Circle()
                        .stroke(PremiumPalette.hairline, lineWidth: 1)
                        .frame(width: 110, height: 110)
                    Image(systemName: "computermouse")
                        .font(.system(size: 58, weight: .ultraLight))
                        .foregroundStyle(Color.accentColor)
                        .rotationEffect(.degrees(Double(model.draft.rotationDegrees)))
                        .animates(model.draft.rotationDegrees)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: Theme.Space.medium) {
                    Text("−30°").font(.caption).foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(model.draft.rotationDegrees) },
                            set: { model.draft.rotationDegrees = Int($0.rounded()) }
                        ),
                        in: -30...30,
                        step: 1
                    )
                    Text("30°").font(.caption).foregroundStyle(.secondary)
                    Button(L10n.string("Reset")) {
                        model.draft.rotationDegrees = 0
                    }
                    .disabled(model.draft.rotationDegrees == 0)
                }
            }
        }
    }

    private var dpiBehaviorPanel: some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.string("DPI Indicator"))
                    .font(.headline)
                    .padding(.bottom, Theme.Space.medium)

                PremiumRow(label: L10n.string("Effect")) {
                    Picker("", selection: $model.draft.dpiEffect.mode) {
                        ForEach(DeviceSettings.DPIEffect.Mode.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                PremiumRow(
                    label: L10n.string("Brightness"),
                    showsDivider: false
                ) {
                    Text("\((model.draft.dpiEffect.brightness + 1) * 10)%")
                        .monospacedDigit()
                    Slider(
                        value: Binding(
                            get: { Double(model.draft.dpiEffect.brightness) },
                            set: { model.draft.dpiEffect.brightness = Int($0.rounded()) }
                        ),
                        in: 0...9,
                        step: 1
                    )
                    .frame(width: 130)
                }
            }
        }
    }

    private func debounceHelp(_ capabilities: DeviceCapabilities) -> String {
        model.draft.debounceMilliseconds > capabilities.debounceWarningThreshold
            ? L10n.string("This value may make click latency noticeable.")
            : L10n.string("Ignores mechanical bounce from the switch.")
    }

    private func reportRate(_ hertz: Int) -> String {
        hertz >= 1_000 ? "\(hertz / 1_000) kHz" : "\(hertz) Hz"
    }
}

private struct DPIStageCard: View {
    @Binding var stage: DeviceSettings.DPIStage
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.small) {
                HStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(stage.color.swiftUIColor)
                        .frame(width: 9, height: 13)
                    Text("\(stage.index + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Text(stage.x.formatted(.number))
                    .font(.body.weight(.medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(Theme.Space.medium)
            .frame(maxWidth: .infinity, minHeight: 74)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(
                        isActive
                            ? Color.accentColor.opacity(0.10)
                            : isHovering ? Color.primary.opacity(0.04) : PremiumPalette.elevated.opacity(0.34)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .strokeBorder(
                        isActive ? Color.accentColor : PremiumPalette.hairline.opacity(0.65),
                        lineWidth: isActive ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animates(isHovering)
        .accessibilityLabel(
            L10n.format("Stage %d", stage.index + 1) + ", \(stage.x) DPI"
        )
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct SelectableValueButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.monospacedDigit())
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.medium)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(isSelected ? Color.accentColor.opacity(0.10) : PremiumPalette.elevated.opacity(0.34))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(
                            isSelected ? Color.accentColor : PremiumPalette.hairline.opacity(0.65),
                            lineWidth: isSelected ? 1.5 : 0.5
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PrecisionSlider: View {
    let title: String
    let help: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let format: (Int) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.medium) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text(title)
                        .font(.headline)
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(format(value))
                    .font(.body.weight(.medium).monospacedDigit())
            }

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
        }
    }
}
