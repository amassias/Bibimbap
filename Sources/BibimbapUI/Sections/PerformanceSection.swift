import Foundation
import BibimbapFeatures
import BibimbapLocalization
import PulsarCatalog
import SwiftUI

/// Geometry contracts for the two-column Performance composition.
///
/// The split candidate is given a real minimum width so `ViewThatFits` cannot declare it
/// valid merely by squeezing stage cards and picker rows into unreadable widths.
enum PerformanceLayout {
    static let columnSpacing: CGFloat = Theme.Space.large
    static let inspectorWidth: CGFloat = 360
    static let mainColumnMinimumWidth: CGFloat = 500
    static let stageCardMinimumWidth: CGFloat = 108

    static var splitMinimumWidth: CGFloat {
        mainColumnMinimumWidth + columnSpacing + inspectorWidth
    }

    static func splitFits(width: CGFloat) -> Bool {
        width >= splitMinimumWidth
    }
}

enum PerformancePreviewSchedule {
    static func shouldAnimate(
        isEnabled: Bool,
        isBreathing: Bool,
        isViewActive: Bool
    ) -> Bool {
        isEnabled && isBreathing && isViewActive
    }
}

/// Performance reprend la composition validée : réglages de précision à gauche,
/// capteur et mouvement dans un inspecteur stable à droite.
struct PerformanceSection: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlockedDPIAxes: Set<Int> = []

    var body: some View {
        if let capabilities = model.capabilities {
            VStack(alignment: .leading, spacing: Theme.Space.xlarge) {
                PremiumSectionHeader(title: L10n.string("Performance"))

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.large) {
                        mainColumn(capabilities)
                            .frame(maxWidth: .infinity)
                        inspectorColumn(capabilities)
                            .frame(width: PerformanceLayout.inspectorWidth)
                    }
                    .frame(minWidth: PerformanceLayout.splitMinimumWidth, alignment: .top)

                    VStack(spacing: Theme.Space.xlarge) {
                        mainColumn(capabilities)
                        inspectorColumn(capabilities)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
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
        return PremiumPanel {
            VStack(alignment: .leading, spacing: Theme.Space.large) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.medium) {
                    Text(L10n.string("DPI Stages"))
                        .font(.headline)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: Theme.Space.small)
                    if capabilities.supportsDPIEditing {
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
                    } else {
                        Label(
                            L10n.string("Read-only sensor"),
                            systemImage: "lock"
                        )
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    }
                }

                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: PerformanceLayout.stageCardMinimumWidth),
                            spacing: Theme.Space.small
                        ),
                    ],
                    alignment: .leading,
                    spacing: Theme.Space.small
                ) {
                    ForEach(
                        model.draft.dpiStages.prefix(model.draft.enabledStageCount)
                    ) { stage in
                        if let index = model.draft.dpiStages.firstIndex(
                            where: { $0.index == stage.index }
                        ) {
                            DPIStageCard(
                                stage: $model.draft.dpiStages[index],
                                isActive: model.draft.activeStage == stage.index,
                                allowsSelection: capabilities.supportsDPIEditing
                            ) {
                                model.draft.activeStage = stage.index
                            }
                        }
                    }
                }

                if capabilities.supportsDPIEditing,
                   model.draft.dpiStages.indices.contains(model.draft.activeStage) {
                    activeDPIEditor(capabilities)
                } else if !capabilities.supportsDPIEditing {
                    Text(L10n.string("DPI editing is unavailable because this sensor uses an unsupported lookup table."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func activeDPIEditor(_ capabilities: DeviceCapabilities) -> some View {
        let activeIndex = model.draft.activeStage
        let stage = $model.draft.dpiStages[activeIndex]
        let stageID = stage.wrappedValue.index
        let isLocked = !unlockedDPIAxes.contains(stageID)

        return VStack(spacing: Theme.Space.small) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text(L10n.string("DPI values"))
                        .font(.headline)
                    Text(representableDPIHint(capabilities))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    L10n.string("Lock X/Y"),
                    isOn: Binding(
                        get: { isLocked },
                        set: { setAxesLocked($0, stage: stage) }
                    )
                )
                .toggleStyle(.switch)
            }

            dpiAxisRow(
                axis: .x,
                value: dpiAxisBinding(.x, stage: stage, locked: isLocked),
                capabilities: capabilities
            )
            dpiAxisRow(
                axis: .y,
                value: dpiAxisBinding(.y, stage: stage, locked: isLocked),
                capabilities: capabilities
            )

            HStack(alignment: .center, spacing: Theme.Space.medium) {
                Text(L10n.string("Stage color"))
                    .font(.subheadline.weight(.medium))
                ColorPicker(
                    "",
                    selection: Binding(
                        get: { stage.wrappedValue.color.swiftUIColor },
                        set: { stage.wrappedValue.color = CatalogColor($0) }
                    ),
                    supportsOpacity: false
                )
                .labelsHidden()
                Text(rgbDescription(stage.wrappedValue.color))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: Theme.Space.small) {
                Text(L10n.string("Palette"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(DPIColorPalette.colors, id: \.self) { color in
                    Button {
                        stage.wrappedValue.color = color
                    } label: {
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(rgbDescription(color))
                }
            }
        }
    }

    private enum DPIAxis {
        case x, y

        var label: String {
            switch self {
            case .x: "X"
            case .y: "Y"
            }
        }
    }

    private func dpiAxisRow(
        axis: DPIAxis,
        value: Binding<Int>,
        capabilities: DeviceCapabilities
    ) -> some View {
        HStack(spacing: Theme.Space.medium) {
            Text(axis.label)
                .font(.subheadline.weight(.semibold))
                .frame(width: 16, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { rawValue in
                        let rounded = Int(rawValue.rounded())
                        value.wrappedValue = capabilities.snapDPI(rounded) ?? rounded
                    }
                ),
                in: Double(capabilities.minimumDPI)...Double(capabilities.maximumDPI),
                step: Double(capabilities.minimumDPIStep)
            )

            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 96)
                .accessibilityLabel(L10n.format("DPI axis %@", axis.label))
        }
    }

    private func dpiAxisBinding(
        _ axis: DPIAxis,
        stage: Binding<DeviceSettings.DPIStage>,
        locked: Bool
    ) -> Binding<Int> {
        Binding(
            get: {
                axis == .x ? stage.wrappedValue.x : stage.wrappedValue.y
            },
            set: { value in
                if locked {
                    stage.wrappedValue.x = value
                    stage.wrappedValue.y = value
                } else if axis == .x {
                    stage.wrappedValue.x = value
                } else {
                    stage.wrappedValue.y = value
                }
            }
        )
    }

    private func setAxesLocked(_ locked: Bool, stage: Binding<DeviceSettings.DPIStage>) {
        if locked {
            unlockedDPIAxes.remove(stage.wrappedValue.index)
            stage.wrappedValue.y = stage.wrappedValue.x
        } else {
            unlockedDPIAxes.insert(stage.wrappedValue.index)
        }
    }

    private func representableDPIHint(_ capabilities: DeviceCapabilities) -> String {
        capabilities.dpiRepresentableRanges.map { range in
            let minimum = range.minimum.formatted(.number)
            let maximum = range.maximum.formatted(.number)
            return L10n.format("%@–%@ (step %d)", minimum, maximum, range.step)
        }.joined(separator: " · ")
    }

    private func rgbDescription(_ color: CatalogColor) -> String {
        "RGB \(color.red), \(color.green), \(color.blue)"
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

                if !capabilities.sensorModeOptions.isEmpty {
                    PremiumRow(
                        label: L10n.string("Sensor mode"),
                        detail: L10n.string("Selects the sensor power profile reported by the receiver.")
                    ) {
                        Picker("", selection: $model.draft.sensorMode) {
                            ForEach(capabilities.sensorModeOptions, id: \.self) { mode in
                                Text(sensorModeLabel(mode)).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }

                if !capabilities.fanModeOptions.isEmpty {
                    PremiumRow(
                        label: L10n.string("Fan mode"),
                        detail: L10n.string("Controls the receiver cooling profile.")
                    ) {
                        Picker("", selection: $model.draft.fanMode) {
                            ForEach(capabilities.fanModeOptions, id: \.self) { mode in
                                Text(fanModeLabel(mode)).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }
            }
        }
    }

    private func sensorModeLabel(_ mode: Int) -> String {
        switch mode {
        case 0: "LP"
        case 1: "HP"
        default: L10n.format("Mode %d", mode)
        }
    }

    private func fanModeLabel(_ mode: Int) -> String {
        mode == 0 ? L10n.string("Off") : L10n.format("Level %d", mode)
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
        let colors = model.draft.dpiStages
            .prefix(model.draft.enabledStageCount)
            .map(\.color)

        return PremiumPanel {
            VStack(alignment: .leading, spacing: Theme.Space.medium) {
                Text(L10n.string("DPI Indicator"))
                    .font(.headline)

                DPIEffectPreview(
                    effect: model.draft.dpiEffect,
                    colors: Array(colors),
                    isActive: scenePhase == .active
                )

                PremiumRow(label: L10n.string("Effect")) {
                    Picker("", selection: $model.draft.dpiEffect.mode) {
                        ForEach(DeviceSettings.DPIEffect.Mode.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                PremiumRow(label: L10n.string("DPI indicator")) {
                    Toggle("", isOn: $model.draft.dpiEffect.enabled)
                        .labelsHidden()
                }

                if model.draft.dpiEffect.mode == .steady {
                    PremiumRow(
                        label: L10n.string("Brightness"),
                        detail: L10n.string("The firmware represents 10–100% in ten levels."),
                        showsDivider: false
                    ) {
                        Text("\((model.draft.dpiEffect.brightness + 1) * 10)%")
                            .monospacedDigit()
                        Slider(
                            value: Binding(
                                get: { Double(model.draft.dpiEffect.brightness) },
                                set: { model.draft.dpiEffect.brightness = Int($0.rounded()) }
                            ),
                            in: Double(DeviceSettings.DPIEffect.brightnessRange.lowerBound)...Double(DeviceSettings.DPIEffect.brightnessRange.upperBound),
                            step: 1
                        )
                        .frame(width: 130)
                    }
                }

                if model.draft.dpiEffect.mode == .breathing {
                    PremiumRow(
                        label: L10n.string("Speed"),
                        detail: L10n.string("Firmware level 0–9; higher values preview faster.")
                    ) {
                        Text("\(model.draft.dpiEffect.speed)")
                            .monospacedDigit()
                        Slider(
                            value: Binding(
                                get: { Double(model.draft.dpiEffect.speed) },
                                set: { model.draft.dpiEffect.speed = Int($0.rounded()) }
                            ),
                            in: Double(DeviceSettings.DPIEffect.speedRange.lowerBound)...Double(DeviceSettings.DPIEffect.speedRange.upperBound),
                            step: 1
                        )
                        .frame(width: 130)
                    }
                }

                Text(L10n.string("Preview only — Apply writes the checked values and confirms them by read-back."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    let allowsSelection: Bool
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

                Text(stage.x == stage.y
                     ? stage.x.formatted(.number)
                     : L10n.format("X %@ · Y %@", stage.x.formatted(.number), stage.y.formatted(.number)))
                    .font(.body.weight(.medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(Theme.Space.medium)
            .frame(
                minWidth: PerformanceLayout.stageCardMinimumWidth,
                maxWidth: .infinity,
                minHeight: 74
            )
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
        .disabled(!allowsSelection)
        .onHover { isHovering = $0 }
        .animates(isHovering)
        .accessibilityLabel(
            L10n.format("Stage %d", stage.index + 1) + ", X \(stage.x), Y \(stage.y) DPI"
        )
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private enum DPIColorPalette {
    static let colors: [CatalogColor] = [
        CatalogColor(red: 255, green: 59, blue: 48),
        CatalogColor(red: 255, green: 149, blue: 0),
        CatalogColor(red: 255, green: 204, blue: 0),
        CatalogColor(red: 52, green: 199, blue: 89),
        CatalogColor(red: 0, green: 199, blue: 190),
        CatalogColor(red: 50, green: 173, blue: 230),
        CatalogColor(red: 88, green: 86, blue: 214),
        CatalogColor(red: 175, green: 82, blue: 222),
        CatalogColor(red: 255, green: 255, blue: 255),
    ]
}

private struct DPIEffectPreview: View {
    let effect: DeviceSettings.DPIEffect
    let colors: [CatalogColor]
    let isActive: Bool

    @ViewBuilder
    var body: some View {
        if PerformancePreviewSchedule.shouldAnimate(
            isEnabled: effect.enabled,
            isBreathing: effect.mode == .breathing,
            isViewActive: isActive
        ) {
            TimelineView(.animation(minimumInterval: 0.12)) { context in
                preview(phase: breathingPhase(at: context.date.timeIntervalSinceReferenceDate))
            }
        } else {
            preview(phase: effect.enabled && effect.mode != .off ? 1 : 0)
        }
    }

    private func breathingPhase(at time: TimeInterval) -> Double {
        let duration = max(0.35, 2.4 - Double(effect.speed) * 0.2)
        return (sin(time / duration * 2 * Double.pi) + 1) / 2
    }

    private func preview(phase: Double) -> some View {
        let isActive = effect.enabled && effect.mode != .off
        let brightness = Double(min(max(effect.brightness, 0), 9) + 1) / 10
        let intensity = isActive
            ? effect.mode == .breathing ? 0.25 + phase * 0.75 : 1
            : 0.12

        return HStack(spacing: Theme.Space.small) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 22, height: 22)
                    .opacity(isActive ? brightness * intensity : intensity)
            }
            if colors.isEmpty {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 22, height: 22)
                    .opacity(intensity)
            }
            Spacer()
            Text(effect.mode.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.medium)
        .padding(.vertical, Theme.Space.small)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(PremiumPalette.elevated.opacity(0.45))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("DPI lighting preview"))
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
