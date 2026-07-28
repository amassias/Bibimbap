import BibimbapFeatures
import PulsarCatalog
import PulsarProtocol
import SwiftUI

// MARK: - Vue d'ensemble

struct OverviewSection: View {
    @Bindable var model: AppModel

    var body: some View {
        if let snapshot = model.snapshot, let capabilities = model.capabilities {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(title: String(localized: "Périphérique")) {
                    row(String(localized: "Modèle"), snapshot.productName)
                    row(String(localized: "Identifiant"), "CID \(snapshot.identity.cid) · MID \(snapshot.identity.mid)")
                    row(String(localized: "Capteur"), snapshot.family.sensor.type)
                    row(String(localized: "Connexion"),
                        "\(snapshot.connection.label) — jusqu'à \(snapshot.connection.maximumReportRate) Hz")
                    row(String(localized: "Firmware"), snapshot.firmwareVersion, showsDivider: snapshot.dongleVersion != nil)
                    if let dongle = snapshot.dongleVersion {
                        row(String(localized: "Firmware du récepteur"), dongle, showsDivider: false)
                    }
                }

                SettingsGroup(title: String(localized: "Réglages actuels")) {
                    row(String(localized: "Polling"), "\(snapshot.settings.reportRateHertz) Hz")
                    row(String(localized: "Palier actif"),
                        dpiSummary(snapshot.settings))
                    row(String(localized: "Distance de décrochage"), "\(snapshot.settings.liftOffMillimetres) mm")
                    row(String(localized: "Temps de rebond"), "\(snapshot.settings.debounceMilliseconds) ms")
                    row(String(localized: "Mise en veille"),
                        snapshot.settings.sleepMinutes == 0
                            ? String(localized: "Jamais")
                            : String(localized: "\(snapshot.settings.sleepMinutes) min"),
                        showsDivider: false)
                }

                SettingsGroup(
                    title: String(localized: "Capacités détectées"),
                    subtitle: String(localized: "Déduites du catalogue embarqué et du sondage des commandes.")
                ) {
                    capabilityRow(String(localized: "Motion Sync"), capabilities.supportsMotionSync)
                    capabilityRow(String(localized: "Ripple Control"), capabilities.supportsRippleControl)
                    capabilityRow(String(localized: "Angle Snap"), capabilities.supportsAngleSnap)
                    capabilityRow(String(localized: "Mode performance"), capabilities.supportsPerformanceMode)
                    capabilityRow(String(localized: "Calibration de rotation"), capabilities.supportsRotation)
                    capabilityRow(String(localized: "Profils matériels"), capabilities.supportsProfiles)
                    capabilityRow(String(localized: "Mode longue portée"), capabilities.supportsLongDistance)
                    capabilityRow(String(localized: "Ventilateur"), capabilities.supportsFanMode, showsDivider: false)
                }
            }
        }
    }

    private func dpiSummary(_ settings: DeviceSettings) -> String {
        guard settings.activeStage < settings.dpiStages.count else { return "—" }
        let stage = settings.dpiStages[settings.activeStage]
        return stage.isSymmetric
            ? String(localized: "Palier \(stage.index + 1) — \(stage.x) DPI")
            : String(localized: "Palier \(stage.index + 1) — \(stage.x) × \(stage.y) DPI")
    }

    private func row(_ label: String, _ value: String, showsDivider: Bool = true) -> some View {
        SettingsRow(label: label, showsDivider: showsDivider) {
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }

    private func capabilityRow(_ label: String, _ supported: Bool, showsDivider: Bool = true) -> some View {
        SettingsRow(label: label, showsDivider: showsDivider) {
            Label(
                supported ? String(localized: "Pris en charge") : String(localized: "Non disponible"),
                systemImage: supported ? "checkmark.circle.fill" : "minus.circle"
            )
            .font(.callout)
            .foregroundStyle(supported ? Color.green : Color.secondary)
        }
    }
}

// MARK: - Personnaliser

struct CustomizeSection: View {
    @Bindable var model: AppModel
    @State private var highlighted: Int?

    var body: some View {
        if model.snapshot != nil {
            HStack(alignment: .top, spacing: Theme.Space.xlarge) {
                MouseSchematic(
                    buttons: model.draft.buttons,
                    highlighted: $highlighted
                )
                .frame(width: 220)

                SettingsGroup(
                    title: String(localized: "Affectation des boutons"),
                    subtitle: String(localized: "Survolez une ligne pour situer le bouton sur le schéma.")
                ) {
                    ForEach($model.draft.buttons) { $button in
                        SettingsRow(
                            label: String(localized: "Bouton \(button.index + 1)"),
                            help: positionHint(button.index),
                            showsDivider: button.index != model.draft.buttons.count - 1
                        ) {
                            HStack(spacing: Theme.Space.small) {
                                Picker("", selection: Binding(
                                    get: { button.function },
                                    set: { newFunction in
                                        button.function = newFunction
                                        button.parameter = defaultParameter(
                                            for: newFunction, buttonIndex: button.index
                                        )
                                    }
                                )) {
                                    ForEach(assignableFunctions, id: \.self) { function in
                                        Text(label(for: function)).tag(function)
                                    }
                                }
                                .frame(width: 186)

                                if button.function == .dpiLock {
                                    TextField("", value: $button.parameter, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .monospacedDigit()
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 68)
                                }
                            }
                        }
                        .onHover { highlighted = $0 ? button.index : nil }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Paramètre cohérent pour une fonction fraîchement choisie.
    ///
    /// Une macro pointe l'emplacement du bouton en poids fort et son nombre de
    /// répétitions en poids faible : laisser l'ancien paramètre ferait pointer un
    /// emplacement arbitraire.
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

    private func label(for function: PulsarKeyFunction) -> String {
        switch function {
        case .disabled: String(localized: "Désactivé")
        case .mouseButton: String(localized: "Bouton souris")
        case .dpiSwitch: String(localized: "Changement de DPI")
        case .horizontalScroll: String(localized: "Défilement horizontal")
        case .rapidFire: String(localized: "Tir rapide")
        case .keyboardShortcut: String(localized: "Raccourci clavier")
        case .macro: String(localized: "Macro")
        case .reportRateSwitch: String(localized: "Changement de polling")
        case .lighting: String(localized: "Éclairage")
        case .profileSwitch: String(localized: "Changement de profil")
        case .dpiLock: String(localized: "Verrouillage DPI")
        case .verticalScroll: String(localized: "Défilement vertical")
        }
    }

    private func positionHint(_ index: Int) -> String? {
        switch index {
        case 0: String(localized: "Clic principal")
        case 1: String(localized: "Clic secondaire")
        case 2: String(localized: "Molette")
        case 3, 4: String(localized: "Flanc gauche")
        default: nil
        }
    }
}

/// Schéma de repérage des boutons.
///
/// Les coordonnées du catalogue positionnent des étiquettes sur le visuel du fabricant,
/// pas des boutons sur un boîtier : les reprendre telles quelles empilait quatre repères
/// dans le même coin. Le schéma place donc les boutons par rôle, ce qui est à la fois
/// honnête — c'est une aide au repérage, pas une photo — et lisible.
struct MouseSchematic: View {
    let buttons: [DeviceSettings.ButtonAssignment]
    @Binding var highlighted: Int?

    /// Position relative de chaque bouton, par index.
    private func anchor(for index: Int) -> CGPoint {
        switch index {
        case 0: CGPoint(x: 0.29, y: 0.14)
        case 1: CGPoint(x: 0.71, y: 0.14)
        case 2: CGPoint(x: 0.50, y: 0.20)
        case 3: CGPoint(x: 0.10, y: 0.34)
        case 4: CGPoint(x: 0.10, y: 0.45)
        case 5: CGPoint(x: 0.50, y: 0.40)
        default: CGPoint(x: 0.50, y: 0.62)
        }
    }

    var body: some View {
        SettingsGroup(title: String(localized: "Repérage")) {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    MouseOutline()
                        .fill(.background.tertiary)
                    MouseOutline()
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)

                    // Séparation des deux clics principaux et molette.
                    Path { path in
                        path.move(to: CGPoint(x: size.width / 2, y: size.height * 0.02))
                        path.addLine(to: CGPoint(x: size.width / 2, y: size.height * 0.30))
                    }
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(.tertiary)
                        .frame(width: 8, height: 20)
                        .position(x: size.width / 2, y: size.height * 0.14)

                    ForEach(buttons) { button in
                        let point = anchor(for: button.index)
                        ButtonMarker(
                            number: button.index + 1,
                            isHighlighted: highlighted == button.index
                        )
                        .position(x: point.x * size.width, y: point.y * size.height)
                    }
                }
            }
            .frame(height: 250)
            .padding(.vertical, Theme.Space.large)
            .accessibilityHidden(true)
        }
    }
}

/// Silhouette neutre : un boîtier arrondi, sans reproduire le dessin du fabricant.
struct MouseOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: w * 0.5, y: 0))
        path.addCurve(to: CGPoint(x: w * 0.96, y: h * 0.42),
                      control1: CGPoint(x: w * 0.82, y: 0),
                      control2: CGPoint(x: w * 0.96, y: h * 0.18))
        path.addCurve(to: CGPoint(x: w * 0.5, y: h),
                      control1: CGPoint(x: w * 0.96, y: h * 0.82),
                      control2: CGPoint(x: w * 0.78, y: h))
        path.addCurve(to: CGPoint(x: w * 0.04, y: h * 0.42),
                      control1: CGPoint(x: w * 0.22, y: h),
                      control2: CGPoint(x: w * 0.04, y: h * 0.82))
        path.addCurve(to: CGPoint(x: w * 0.5, y: 0),
                      control1: CGPoint(x: w * 0.04, y: h * 0.18),
                      control2: CGPoint(x: w * 0.18, y: 0))
        path.closeSubpath()
        return path
    }
}

struct ButtonMarker: View {
    let number: Int
    let isHighlighted: Bool

    var body: some View {
        Text("\(number)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(isHighlighted ? .white : Color.accentColor)
            .frame(width: 18, height: 18)
            .background(
                Circle().fill(isHighlighted
                              ? AnyShapeStyle(Color.accentColor)
                              : AnyShapeStyle(.background))
            )
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .scaleEffect(isHighlighted ? 1.18 : 1)
            .animates(isHighlighted)
    }
}

// MARK: - Alimentation et dongle

struct PowerSection: View {
    @Bindable var model: AppModel

    var body: some View {
        if let capabilities = model.capabilities, let snapshot = model.snapshot {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(title: String(localized: "Économie d'énergie")) {
                    SettingsRow(
                        label: String(localized: "Mise en veille"),
                        help: String(localized: "Délai d'inactivité avant la mise en veille du capteur.")
                    ) {
                        HStack(spacing: 10) {
                            Slider(
                                value: Binding(
                                    get: { Double(model.draft.sleepMinutes) },
                                    set: { model.draft.sleepMinutes = Int($0.rounded()) }
                                ),
                                in: 0...30,
                                step: 1
                            )
                            .frame(width: 180)
                            Text(model.draft.sleepMinutes == 0
                                 ? String(localized: "Jamais")
                                 : String(localized: "\(model.draft.sleepMinutes) min"))
                                .monospacedDigit()
                                .frame(width: 62, alignment: .trailing)
                        }
                    }

                    SettingsRow(
                        label: String(localized: "Seuil de basse consommation"),
                        help: String(localized: "Niveau de batterie sous lequel la souris réduit sa consommation."),
                        showsDivider: capabilities.supportsLongDistance
                    ) {
                        HStack(spacing: 10) {
                            Slider(
                                value: Binding(
                                    get: { Double(model.draft.powerSaveBatteryPercent) },
                                    set: { model.draft.powerSaveBatteryPercent = Int($0.rounded()) }
                                ),
                                in: 0...50,
                                step: 5
                            )
                            .frame(width: 180)
                            Text(model.draft.powerSaveBatteryPercent == 0
                                 ? String(localized: "Désactivé")
                                 : "\(model.draft.powerSaveBatteryPercent) %")
                                .monospacedDigit()
                                .frame(width: 72, alignment: .trailing)
                        }
                    }

                    if capabilities.supportsLongDistance {
                        SettingsRow(
                            label: String(localized: "Mode longue portée"),
                            help: String(localized: "Augmente la puissance d'émission au détriment de l'autonomie."),
                            showsDivider: false
                        ) {
                            Toggle("", isOn: $model.draft.longDistance)
                                .toggleStyle(.switch)
                        }
                    }
                }

                if let battery = snapshot.battery {
                    SettingsGroup(title: String(localized: "Batterie")) {
                        SettingsRow(label: String(localized: "Niveau")) {
                            Text("\(battery.percentage) %")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        SettingsRow(label: String(localized: "Tension"), showsDivider: false) {
                            Text("\(battery.millivolts) mV")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
