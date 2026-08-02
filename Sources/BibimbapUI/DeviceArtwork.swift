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

/// Dimensions partagées par la carte et la composition adaptative de Customize.
///
/// La largeur minimale de la colonne d'affectation laisse une ligne garder son libellé
/// et son sélecteur, tandis que les éditeurs de paramètres peuvent descendre sur une
/// seconde ligne. Elle est volontairement assez compacte pour que la fenêtre par défaut
/// conserve deux colonnes, mais assez large pour ne jamais demander à un éditeur de se
/// comprimer horizontalement.
enum CustomizeLayoutMetrics {
    static let mapWidth: CGFloat = 455
    static let assignmentMinimumWidth: CGFloat = 420
    static let columnSpacing: CGFloat = Theme.Space.large
    static let canvasHeight: CGFloat = 410

    static var minimumColumnWidth: CGFloat {
        mapWidth + columnSpacing + assignmentMinimumWidth
    }

    static func usesColumns(availableWidth: CGFloat) -> Bool {
        availableWidth >= minimumColumnWidth
    }
}

/// Carte des commandes exposées par le modèle connecté.
///
/// La liste vient de `AppModel.buttonPresentations`, la même que celle des lignes
/// d'affectation : autant de repères que de lignes, ni plus ni moins. Chaque repère est
/// posé à partir de la géométrie officielle du catalogue ; un bouton sans géométrie
/// publiée n'en reçoit pas, et la vue le dit.
struct DeviceButtonMap: View {
    @Bindable var model: AppModel
    let buttons: [ButtonPresentation]
    @Binding var highlighted: Int?
    var title = L10n.string( "Button map")

    private var buttonsWithoutGeometry: [ButtonPresentation] {
        buttons.filter { $0.normalizedMarker == nil }
    }

    var body: some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: Theme.Space.medium) {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text(title)
                        .font(.headline)
                    Text(
                        "\(buttons.count) "
                            + L10n.string("configurable buttons detected")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                canvas
                    .frame(height: CustomizeLayoutMetrics.canvasHeight)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(
                        model.deviceDisplayName + ", \(buttons.count) "
                            + L10n.string( "configurable buttons")
                    )

                if !buttonsWithoutGeometry.isEmpty {
                    Text(
                        L10n.string("Position unavailable on the map:") + " "
                            + buttonsWithoutGeometry.map(\.numberLabel).joined(separator: ", ")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Photographie et repères partagent le même carré, donc le même cadrage.
    ///
    /// Les visuels officiels sont carrés : un carré centré dans l'espace disponible
    /// coïncide exactement avec ce que `scaledToFit` affiche, et les coordonnées
    /// normalisées du catalogue s'y appliquent directement.
    private var canvas: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                DeviceArtwork(model: model, maximumWidth: side, maximumHeight: side)

                ForEach(buttons) { button in
                    if let marker = button.normalizedMarker {
                        ButtonMarker(
                            number: button.displayNumber,
                            isHighlighted: highlighted == button.firmwareIndex
                        )
                        .position(
                            x: marker.x * side,
                            y: marker.y * side
                        )
                        .help(button.label)
                        .accessibilityLabel(button.numberLabel + ": " + button.label)
                        .onHover { isHovering in
                            if isHovering {
                                highlighted = button.firmwareIndex
                            } else if highlighted == button.firmwareIndex {
                                highlighted = nil
                            }
                        }
                    }
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
