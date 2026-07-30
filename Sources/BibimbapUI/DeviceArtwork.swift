import AppKit
import BibimbapFeatures
import BibimbapLocalization
import SwiftUI

/// Photographie officielle associée au CID/MID lu sur la souris.
///
/// Les images sont embarquées : aucune requête réseau n'est faite pendant l'utilisation.
struct DeviceArtwork: View {
    @Bindable var model: AppModel
    var maximumWidth: CGFloat?
    var maximumHeight: CGFloat?

    var body: some View {
        Group {
            if let imageName = model.deviceImageName,
               let image = DeviceArtworkStore.shared.image(named: imageName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image("MouseX2", bundle: .module)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(maxWidth: maximumWidth, maxHeight: maximumHeight)
        .accessibilityLabel(
            L10n.string( "Top view of the mouse") + ": " + model.deviceDisplayName
        )
    }
}

/// Nettoie les quatre zones blanches que les ressources du pilote web Pulsar
/// embarquent derrière la silhouette de la souris. Elles servent de canevas au pilote
/// officiel, mais ressemblent à une grande croix dans une application native.
///
/// Seuls les pixels blancs situés hors du tiers central sont retirés, y compris
/// leurs pixels anticrénelés semi-transparents. La photographie, ses ombres et les
/// boutons latéraux restent donc ceux de Pulsar.
@MainActor
private final class DeviceArtworkStore {
    static let shared = DeviceArtworkStore()

    private let cache = NSCache<NSString, NSImage>()

    func image(named name: String) -> NSImage? {
        if let cached = cache.object(forKey: name as NSString) {
            return cached
        }
        guard let source = Bundle.module.image(forResource: name),
              let cleaned = removingDriverCanvas(from: source) else {
            return Bundle.module.image(forResource: name)
        }
        cache.setObject(cleaned, forKey: name as NSString)
        return cleaned
    }

    private func removingDriverCanvas(from image: NSImage) -> NSImage? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else { return nil }

        let width = source.width
        let height = source.height
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }

        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        let leftLimit = Int(Double(width) * 0.34)
        let rightLimit = Int(Double(width) * 0.66)

        for y in 0..<height {
            for x in 0..<width where x < leftLimit || x > rightLimit {
                let offset = y * bytesPerRow + x * 4
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                let alpha = Int(pixels[offset + 3])
                let brightest = max(red, green, blue)
                let darkest = min(red, green, blue)
                let neutralTolerance = max(3, alpha / 24)
                let isAntialiasedWhite =
                    alpha > 0 &&
                    brightest - darkest <= neutralTolerance &&
                    darkest * 255 >= alpha * 238

                if isAntialiasedWhite {
                    pixels[offset] = 0
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                    pixels[offset + 3] = 0
                }
            }
        }

        guard let output = context.makeImage() else { return nil }
        let cleaned = NSImage(cgImage: output, size: image.size)
        cleaned.isTemplate = false
        return cleaned
    }
}

/// Carte du nombre exact de boutons exposés par le firmware du modèle connecté.
///
/// Les familles Pulsar actuelles déclarent cinq ou six emplacements : clics principaux,
/// molette et deux ou trois commandes supplémentaires. La vue ne crée jamais de bouton
/// absent du catalogue.
struct DeviceButtonMap: View {
    @Bindable var model: AppModel
    let assignments: [DeviceSettings.ButtonAssignment]
    @Binding var highlighted: Int?
    var title = L10n.string( "Button map")

    private var additionalButtonCount: Int {
        max(0, assignments.count - 3)
    }

    var body: some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: Theme.Space.medium) {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text(title)
                        .font(.headline)
                    Text(
                        "\(assignments.count) "
                            + L10n.string("configurable buttons detected")
                            + " · \(additionalButtonCount) "
                            + L10n.string("additional buttons")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

            GeometryReader { proxy in
                ZStack {
                    DeviceArtwork(
                        model: model,
                        maximumWidth: proxy.size.width,
                        maximumHeight: proxy.size.height
                    )

                    ForEach(assignments) { assignment in
                        ButtonMarker(
                            number: assignment.index + 1,
                            isHighlighted: highlighted == assignment.index
                        )
                        .position(
                            x: anchor(for: assignment.index).x * proxy.size.width,
                            y: anchor(for: assignment.index).y * proxy.size.height
                        )
                        .help(buttonRole(assignment.index))
                    }
                }
            }
            .frame(height: 410)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                model.deviceDisplayName + ", \(assignments.count) "
                    + L10n.string( "configurable buttons")
            )
            }
        }
    }

    /// Les photographies officielles partagent un cadrage de dessus carré.
    private func anchor(for index: Int) -> CGPoint {
        switch index {
        case 0: CGPoint(x: 0.39, y: 0.24)
        case 1: CGPoint(x: 0.61, y: 0.24)
        case 2: CGPoint(x: 0.50, y: 0.27)
        case 3: CGPoint(x: 0.29, y: 0.43)
        case 4: CGPoint(x: 0.29, y: 0.54)
        case 5: CGPoint(x: 0.50, y: 0.57)
        default:
            // Le catalogue ne publie actuellement aucun index supérieur, mais ce repli
            // garde une future entrée visible sans prétendre connaître sa géométrie.
            CGPoint(x: 0.72, y: min(CGFloat(0.74), 0.40 + CGFloat(index - 5) * 0.09))
        }
    }

    private func buttonRole(_ index: Int) -> String {
        switch index {
        case 0: L10n.string( "Primary click")
        case 1: L10n.string( "Secondary click")
        case 2: L10n.string( "Wheel click")
        case 3: L10n.string( "Side button 1")
        case 4: L10n.string( "Side button 2")
        case 5: L10n.string( "Additional button")
        default: L10n.format("Button %d", index + 1)
        }
    }
}
