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
