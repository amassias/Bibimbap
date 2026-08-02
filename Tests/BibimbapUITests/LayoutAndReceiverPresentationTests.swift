import PulsarCatalog
import PulsarProtocol
import Testing
@testable import BibimbapUI

@Suite("Présentation et layout des sections")
struct LayoutAndReceiverPresentationTests {
    @Test("Customize conserve deux colonnes dans la largeur de contenu par défaut")
    func customizeColumnsFitTheDefaultContentWidth() {
        #expect(CustomizeLayoutMetrics.minimumColumnWidth == 891)
        #expect(CustomizeLayoutMetrics.usesColumns(availableWidth: 896))
        #expect(!CustomizeLayoutMetrics.usesColumns(availableWidth: 890))
    }

    @Test("Macros empile ses panneaux avant de comprimer la table")
    func macrosChooseStackedLayoutWhenTheEditorWouldBeNarrow() {
        #expect(MacroLayoutMetrics.minimumColumnWidth == 1_144)
        #expect(!MacroLayoutMetrics.usesColumns(availableWidth: 896))
        #expect(MacroLayoutMetrics.usesColumns(availableWidth: 1_144))
    }

    @Test("Le formatage du signal garde une voie distincte pour Sleep")
    func signalPresentationDoesNotGuessSleepFromANumber() {
        #expect(
            WirelessSignalPresentation.state(for: .unknown)
                == WirelessSignalDisplayState.unknown
        )
        #expect(
            WirelessSignalPresentation.state(for: .strength(0))
                == WirelessSignalDisplayState.numeric(0)
        )
        #expect(
            WirelessSignalPresentation.state(for: .unsupported)
                == WirelessSignalDisplayState.unsupported
        )
        #expect(
            WirelessSignalPresentation.label(for: .sleeping) == "Sleep"
        )
        #expect(
            WirelessSignalPresentation.systemImage(for: .sleeping) == "moon.zzz.fill"
        )
    }

    @Test("Une couleur RGB modifie le brouillon sans toucher aux autres couleurs")
    func receiverColorMutationIsBounded() throws {
        let original = DongleLightingState(
            mode: 2,
            colors: [1, 2, 3, 4, 5, 6, 7, 8, 9]
        )
        let updated = try #require(
            ReceiverColorDraft.settingRGB(
                CatalogColor(red: 100, green: 110, blue: 120),
                at: 3,
                in: original
            )
        )

        #expect(updated.mode == original.mode)
        #expect(updated.colors == [1, 2, 3, 100, 110, 120, 7, 8, 9])
        #expect(
            ReceiverColorDraft.settingRGB(
                CatalogColor(red: 1, green: 2, blue: 3),
                at: 4,
                in: original
            ) == nil
        )
    }
}
