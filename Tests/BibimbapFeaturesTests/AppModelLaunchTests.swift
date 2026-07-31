import BibimbapFeatures
import Testing

@Suite("Démarrage de l'application")
struct AppModelLaunchTests {
    @Test("Un modèle neuf commence sur Vue d'ensemble")
    @MainActor
    func newModelStartsOnOverview() {
        let model = AppModel.simulated()

        #expect(model.section == .overview)

        // Une navigation ordinaire n'est pas réinitialisée par le modèle.
        model.section = .settings
        #expect(model.section == .settings)
    }
}
