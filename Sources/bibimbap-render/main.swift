import AppKit
import BibimbapFeatures
import BibimbapUI
import SwiftUI

/// Rendu hors écran de l'interface, en PNG.
///
/// Sert à regarder le résultat réel — hiérarchie, densité, alignements, clair et sombre —
/// sans dépendre d'une capture d'écran. Le modèle est alimenté par le transport simulé,
/// donc le rendu ne demande aucun matériel.
///
/// Le rendu utilise le même shell trois colonnes que l'application.
///
///     swift run bibimbap-render [dossier]

@MainActor
func render(
    _ view: some View,
    named name: String,
    size: CGSize,
    scheme: ColorScheme,
    into directory: URL
) -> Bool {
    let renderer = ImageRenderer(
        content: view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "fr_FR"))
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
    )
    renderer.scale = 2

    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else {
        print("  échec du rendu : \(name)")
        return false
    }

    let suffix = scheme == .dark ? "sombre" : "clair"
    try? png.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
    return true
}

/// Planche de contrôle de l'icône de barre des menus.
///
/// L'icône est un carré de 18 points : c'est à cette taille qu'elle doit rester lisible,
/// et à cette taille qu'on ne voit rien sur un écran de développement. La planche montre
/// donc chaque état deux fois, à sa taille réelle et agrandi.
struct MenuBarIconSheet: View {
    struct Variant: Identifiable {
        var label: String
        var percent: Int?
        var charging = false
        var connected = true
        var id: String { label }
    }

    let variants: [Variant] = [
        .init(label: "100 %", percent: 100),
        .init(label: "72 %", percent: 72),
        .init(label: "38 %", percent: 38),
        .init(label: "9 %", percent: 9),
        .init(label: "en charge", percent: 60, charging: true),
        .init(label: "filaire", percent: nil),
        .init(label: "absente", percent: nil, connected: false),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            ForEach(variants) { variant in
                VStack(spacing: 14) {
                    icon(variant, side: MenuBarIcon.side * 6)
                    icon(variant, side: MenuBarIcon.side)
                    Text(variant.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(32)
    }

    private func icon(_ variant: Variant, side: CGFloat) -> some View {
        Image(nsImage: MenuBarIcon.image(
            batteryPercent: variant.percent,
            isCharging: variant.charging,
            isConnected: variant.connected
        ))
        .resizable()
        .renderingMode(.template)
        .interpolation(.high)
        .frame(width: side, height: side)
        .foregroundStyle(.primary)
    }
}

@MainActor
func main() async {
    let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : "./.render")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let model = AppModel.simulated()
    await model.connect()

    let canvas = CGSize(width: 1440, height: 900)
    let schemes: [ColorScheme] = CommandLine.arguments.contains("--clair")
        ? [.light]
        : [.light, .dark]

    for scheme in schemes {
        print("\(scheme == .dark ? "Sombre" : "Clair") :")

        for (section, name) in [
            (AppModel.Section.overview, "vue-ensemble"),
            (.performance, "performance"),
            (.customize, "personnaliser"),
            (.macros, "macros"),
            (.power, "alimentation"),
            (.settings, "reglages"),
        ] {
            model.section = section
            if section == .performance {
                model.draft.debounceMilliseconds = 6
            }
            let ok = render(
                RenderHarness(model: model),
                named: name,
                size: canvas,
                scheme: scheme,
                into: directory
            )
            if ok { print("  \(name)") }
            model.revert()
        }

        // L'état « modifications en attente » est la signature de l'application.
        model.section = .performance
        model.draft.debounceMilliseconds = 6
        model.draft.motionSync.toggle()
        model.draft.dpiStages[0].x = 1600
        model.draft.dpiStages[0].y = 1600
        if render(RenderHarness(model: model, showsPendingBar: true),
                  named: "modifications-en-attente",
                  size: canvas,
                  scheme: scheme, into: directory) {
            print("  modifications-en-attente")
        }
        model.revert()

        if render(MenuBarIconSheet(),
                  named: "barre-des-menus-icone",
                  size: CGSize(width: 1180, height: 240),
                  scheme: scheme, into: directory) {
            print("  barre-des-menus-icone")
        }
    }

    await model.disconnect()
    print("\nRendus dans \(directory.path)")
}

await main()
