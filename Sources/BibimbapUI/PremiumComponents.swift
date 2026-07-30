import BibimbapLocalization
import SwiftUI

/// Vocabulaire visuel partagé par tous les écrans du redesign.
///
/// Les couleurs restent sémantiques : AppKit fournit automatiquement leurs variantes
/// sombre et claire, et l'accent reste celui choisi dans macOS.
enum PremiumPalette {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let elevated = Color(nsColor: .textBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
}

struct PremiumPanel<Content: View>: View {
    var padding: CGFloat = Theme.Space.xlarge
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .fill(PremiumPalette.surface.opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .strokeBorder(PremiumPalette.hairline.opacity(0.72), lineWidth: 0.5)
            )
    }
}
struct PremiumSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(title)
                .font(.title2.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PremiumMetric: View {
    let systemImage: String
    let label: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: Theme.Space.medium) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.medium).monospacedDigit())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

struct PremiumStatusDot: View {
    let label: String
    var color: Color = .green

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PremiumRow<Accessory: View>: View {
    let label: String
    var detail: String?
    var showsDivider = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.large) {
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text(label)
                        .font(.body)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Theme.Space.xlarge)
                accessory
            }
            .frame(minHeight: 48)

            if showsDivider {
                Divider()
            }
        }
    }
}

struct QuickAction: View {
    let systemImage: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.large) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.Space.large)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .fill(isHovering ? Color.accentColor.opacity(0.08) : PremiumPalette.surface.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .strokeBorder(
                        isHovering ? Color.accentColor.opacity(0.65) : PremiumPalette.hairline.opacity(0.72),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animates(isHovering)
    }
}

struct SettingLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
