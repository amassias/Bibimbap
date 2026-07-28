import PulsarCatalog
import SwiftUI

/// Un groupe de réglages : un titre discret, puis une liste encadrée.
///
/// La forme reprend celle des Réglages de macOS, où l'encadré délimite un groupe plutôt
/// qu'il ne « décore » une carte. D'où l'absence d'ombre et de dégradé : le trait et le
/// fond suffisent à séparer, et empiler des cartes ornementées transformerait un écran
/// de réglages en catalogue.
struct SettingsGroup<Content: View, Accessory: View>: View {
    var title: String?
    var subtitle: String?
    /// Petit contrôle logé à droite du titre, pour un réglage qui porte sur le groupe
    /// entier plutôt que sur une de ses lignes.
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.large) {
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text(title).groupTitle()
                        if let subtitle {
                            Text(subtitle)
                                .supporting()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: Theme.Space.small)
                    accessory
                        .controlSize(.small)
                }
                .padding(.horizontal, Theme.Space.tight)
            }

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, Theme.Row.horizontalPadding)
            .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.group))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.group)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )
        }
    }
}

/// Une ligne de réglage : libellé à gauche, contrôle à droite.
///
/// `showsDivider` est piloté par l'appelant plutôt que déduit, parce qu'un groupe masque
/// des lignes selon les capacités du modèle : lui seul sait laquelle est réellement la
/// dernière.
struct SettingsRow<Control: View>: View {
    let label: String
    var help: String?
    var showsDivider = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.large) {
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text(label)
                    if let help {
                        Text(help)
                            .supporting()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.xlarge)
                control
                    .labelsHidden()
            }
            .padding(.vertical, Theme.Row.verticalPadding)
            .frame(minHeight: Theme.Row.minimumHeight)

            if showsDivider {
                Divider()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Curseur suivi de sa valeur, alignée en colonne d'une ligne à l'autre.
///
/// La valeur occupe une largeur fixe : sans cela, passer de « 9 ms » à « 10 ms » décale
/// le curseur, et une rangée de réglages se met à frémir à chaque glissement.
struct ValueSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var width: CGFloat = 176
    var format: (Int) -> String

    var body: some View {
        HStack(spacing: Theme.Space.medium) {
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
            .frame(width: width)

            Text(format(value))
                .settingValue()
                .frame(width: Theme.Row.valueWidth, alignment: .trailing)
                .contentTransition(.numericText())
                .animates(value)
        }
    }
}

/// Sélecteur segmenté, pour un choix court et mutuellement exclusif.
struct SegmentedChoice<Value: Hashable>: View {
    let values: [Value]
    let title: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(values, id: \.self) { value in
                Text(title(value)).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

extension SettingsGroup where Accessory == EmptyView {
    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

extension CatalogColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(
            red: Int((resolved.redComponent * 255).rounded()),
            green: Int((resolved.greenComponent * 255).rounded()),
            blue: Int((resolved.blueComponent * 255).rounded())
        )
    }
}
