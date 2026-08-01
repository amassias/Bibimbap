import BibimbapFeatures
import SwiftUI

/// Assemble en-tête, contenu et barre d'actions sans `NavigationSplitView`.
///
/// Existe pour le rendu hors écran : `ImageRenderer` ne sait pas rendre les conteneurs de
/// navigation AppKit, qui produisent une image vide. Cet assemblage montre exactement les
/// mêmes vues, ce qui en fait un miroir fidèle pour juger hiérarchie et densité.
public struct RenderHarness: View {
    @Bindable var model: AppModel
    var showsPendingBar = false
    var showsContent = true

    public init(model: AppModel, showsPendingBar: Bool = false, showsContent: Bool = true) {
        self.model = model
        self.showsPendingBar = showsPendingBar
        self.showsContent = showsContent
    }

    public var body: some View {
        AppShell(
            model: model,
            forcePendingBar: showsPendingBar,
            showsContent: showsContent
        )
    }
}

/// La carte des boutons et ses affectations, hors du shell de navigation.
///
/// L'onglet `Personnaliser` s'appuie sur `ViewThatFits`, qu'`ImageRenderer` ne sait pas
/// mesurer : la planche complète en ressort vide. Cette vue montre les deux panneaux
/// côte à côte sans conteneur adaptatif, ce qui permet de vérifier hors écran ce qui
/// compte ici — le nombre de repères, leur numéro et leur position sur la photographie.
public struct ButtonMapHarness: View {
    @Bindable var model: AppModel
    @State private var highlighted: Int?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.xlarge) {
            DeviceButtonMap(
                model: model,
                buttons: model.buttonPresentations,
                highlighted: $highlighted
            )
            .frame(width: 455)

            VStack(alignment: .leading, spacing: Theme.Space.small) {
                Text(model.deviceDisplayName)
                    .font(.headline)
                ForEach(model.buttonPresentations) { button in
                    HStack(spacing: Theme.Space.small) {
                        ButtonMarker(number: button.displayNumber, isHighlighted: false)
                        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                            Text(button.label)
                            Text("index firmware \(button.firmwareIndex)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(width: 260, alignment: .leading)
        }
        .padding(Theme.Space.xlarge)
    }
}
