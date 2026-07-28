import BibimbapFeatures
import PulsarCatalog
import SwiftUI

/// Réglages de performance, composés comme un inspecteur macOS compact.
///
/// La hiérarchie suit le visuel de référence : le DPI forme un bloc continu, puis les
/// réglages ponctuels se lisent comme des rangées. Rien n'est déplacé dans une seconde
/// colonne, afin que les valeurs et les contrôles restent sur les mêmes axes.
struct PerformanceSection: View {
    @Bindable var model: AppModel

    var body: some View {
        if let capabilities = model.capabilities {
            VStack(alignment: .leading, spacing: Theme.Space.xlarge) {
                dpiGroup(capabilities)
                pollingGroup(capabilities)
                trackingGroup(capabilities)
                sensorGroup(capabilities)
                if capabilities.supportsRotation {
                    rotationGroup
                }
            }
        }
    }

    // MARK: - DPI

    private func dpiGroup(_ capabilities: DeviceCapabilities) -> some View {
        SettingsGroup(title: String(localized: "DPI")) {
            SettingsRow(label: String(localized: "Paliers DPI")) {
                HStack(spacing: Theme.Space.small) {
                    ForEach(model.draft.dpiStages.prefix(model.draft.enabledStageCount)) { stage in
                        if let index = model.draft.dpiStages.firstIndex(where: { $0.index == stage.index }) {
                            InlineDPIStage(
                                stage: $model.draft.dpiStages[index],
                                isActive: model.draft.activeStage == stage.index
                            ) {
                                model.draft.activeStage = stage.index
                            }
                        }
                    }

                    Menu {
                        ForEach(1...capabilities.maximumStages, id: \.self) { count in
                            Button("\(count) paliers") {
                                model.draft.enabledStageCount = count
                                model.draft.activeStage = min(model.draft.activeStage, count - 1)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(String(localized: "Nombre de paliers actifs"))
                }
            }

            SettingsRow(label: String(localized: "Effet DPI")) {
                InlineRadioGroup(
                    values: DeviceSettings.DPIEffect.Mode.allCases,
                    title: \.label,
                    selection: $model.draft.dpiEffect.mode
                )
            }

            SettingsRow(label: String(localized: "Luminosité")) {
                PercentageSlider(value: $model.draft.dpiEffect.brightness)
            }

            SettingsRow(label: String(localized: "Vitesse"), showsDivider: false) {
                PercentageSlider(value: $model.draft.dpiEffect.speed)
            }
        }
    }

    // MARK: - Cadence et suivi

    private func pollingGroup(_ capabilities: DeviceCapabilities) -> some View {
        SettingsGroup {
            SettingsRow(
                label: String(localized: "Taux de rafraîchissement"),
                help: model.snapshot.map {
                    String(localized: "Maximum \($0.connection.maximumReportRate) Hz via \($0.connection.label).")
                },
                showsDivider: false
            ) {
                InlineRadioGroup(
                    values: capabilities.availableReportRates,
                    title: { $0 >= 1000 ? "\($0 / 1000) kHz" : "\($0) Hz" },
                    selection: $model.draft.reportRateHertz
                )
            }
        }
    }

    private func trackingGroup(_ capabilities: DeviceCapabilities) -> some View {
        SettingsGroup {
            SettingsRow(
                label: String(localized: "Distance de décrochage"),
                help: String(localized: "Hauteur à laquelle le capteur cesse de suivre.")
            ) {
                ValueSlider(
                    value: $model.draft.liftOffMillimetres,
                    range: 1...2,
                    width: 260
                ) { "\($0) mm" }
            }

            SettingsRow(
                label: String(localized: "Temps de rebond"),
                help: debounceHelp(capabilities),
                showsDivider: false
            ) {
                ValueSlider(
                    value: $model.draft.debounceMilliseconds,
                    range: 0...capabilities.maximumDebounce,
                    width: 260
                ) { "\($0) ms" }
            }
        }
    }

    private func debounceHelp(_ capabilities: DeviceCapabilities) -> String {
        model.draft.debounceMilliseconds > capabilities.debounceWarningThreshold
            ? String(localized: "Cette valeur peut rendre la latence des clics perceptible.")
            : String(localized: "Ignore les rebonds mécaniques du contacteur.")
    }

    // MARK: - Capteur

    private func sensorGroup(_ capabilities: DeviceCapabilities) -> some View {
        let toggles: [(String, String, Binding<Bool>)] = [
            (capabilities.supportsMotionSync, String(localized: "Motion Sync"),
             String(localized: "Synchronise les données du capteur avec chaque rapport."),
             $model.draft.motionSync),
            (capabilities.supportsRippleControl, String(localized: "Ripple Control"),
             String(localized: "Lisse les micro-vibrations du suivi."),
             $model.draft.rippleControl),
            (capabilities.supportsAngleSnap, String(localized: "Angle Snap"),
             String(localized: "Contraint le déplacement du curseur aux axes."),
             $model.draft.angleSnap),
            (capabilities.supportsPerformanceMode, String(localized: "Mode performance"),
             String(localized: "Augmente la fréquence de balayage du capteur."),
             $model.draft.performanceMode),
        ].filter(\.0).map { ($0.1, $0.2, $0.3) }

        return SettingsGroup {
            ForEach(Array(toggles.enumerated()), id: \.offset) { offset, entry in
                SettingsRow(
                    label: entry.0,
                    help: entry.1,
                    showsDivider: offset != toggles.count - 1
                ) {
                    Toggle("", isOn: entry.2)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Rotation

    private var rotationGroup: some View {
        SettingsGroup {
            SettingsRow(
                label: String(localized: "Calibration de rotation"),
                help: String(localized: "Compense une prise en main légèrement de biais."),
                showsDivider: false
            ) {
                HStack(spacing: Theme.Space.medium) {
                    Button("Réinitialiser") {
                        model.draft.rotationDegrees = 0
                    }
                    .controlSize(.small)
                    .disabled(model.draft.rotationDegrees == 0)

                    Text("−30°")
                        .supporting()
                    Slider(
                        value: Binding(
                            get: { Double(model.draft.rotationDegrees) },
                            set: { model.draft.rotationDegrees = Int($0.rounded()) }
                        ),
                        in: -30...30,
                        step: 1
                    )
                    .frame(width: 260)
                    Text("30°")
                        .supporting()
                    Text("\(model.draft.rotationDegrees)°")
                        .settingValue()
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
    }
}

/// Un palier DPI en ligne : couleur, numéro et valeur éditable.
private struct InlineDPIStage: View {
    @Binding var stage: DeviceSettings.DPIStage
    let isActive: Bool
    let select: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            RoundedRectangle(cornerRadius: 2)
                .fill(stage.color.swiftUIColor)
                .frame(width: 10, height: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
                )

            Text("\(stage.index + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isActive {
                TextField("", value: Binding(
                    get: { stage.x },
                    set: { value in
                        let wasSymmetric = stage.isSymmetric
                        stage.x = value
                        if wasSymmetric { stage.y = value }
                    }
                ), format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 48)
            } else {
                Text(stage.isSymmetric ? "\(stage.x)" : "\(stage.x)×\(stage.y)")
                    .monospacedDigit()
                    .frame(minWidth: 48, alignment: .trailing)
            }
        }
        .font(.callout)
        .padding(.horizontal, Theme.Space.small)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(isActive
                      ? Color.accentColor.opacity(0.08)
                      : isHovering ? Color.primary.opacity(0.035) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(
                    isActive ? Color.accentColor : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .animates(isActive)
        .animates(isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Palier \(stage.index + 1), \(stage.x) DPI")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Choix exclusifs compacts avec la grammaire visuelle des boutons radio macOS.
private struct InlineRadioGroup<Value: Hashable>: View {
    let values: [Value]
    let title: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: Theme.Space.large) {
            ForEach(values, id: \.self) { value in
                Button {
                    selection = value
                } label: {
                    HStack(spacing: Theme.Space.snug) {
                        ZStack {
                            Circle()
                                .strokeBorder(
                                    selection == value ? Color.accentColor : Color.secondary.opacity(0.45),
                                    lineWidth: 1
                                )
                                .frame(width: 14, height: 14)
                            if selection == value {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        Text(title(value))
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .font(.callout)
    }
}

private struct PercentageSlider: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: Theme.Space.medium) {
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0.rounded()) }
                ),
                in: 0...9,
                step: 1
            )
            .frame(width: 360)

            Text("\((value + 1) * 10) %")
                .settingValue()
                .frame(width: Theme.Row.valueWidth, alignment: .trailing)
        }
    }
}
