import CoreGraphics
import Testing
@testable import BibimbapUI

@Suite("Disposition de Performance")
struct PerformanceLayoutTests {
    @Test("La disposition côte à côte réserve les deux colonnes")
    func splitLayoutHasAnExplicitMinimumWidth() {
        #expect(
            PerformanceLayout.splitMinimumWidth ==
                PerformanceLayout.mainColumnMinimumWidth
                + PerformanceLayout.columnSpacing
                + PerformanceLayout.inspectorWidth
        )
        #expect(PerformanceLayout.splitFits(width: PerformanceLayout.splitMinimumWidth))
        #expect(!PerformanceLayout.splitFits(width: PerformanceLayout.splitMinimumWidth - 1))
    }

    @Test("Les cartes DPI gardent une largeur lisible avant de se mettre en grille")
    func stageCardsHaveAReadableMinimumWidth() {
        #expect(PerformanceLayout.stageCardMinimumWidth >= 100)
        #expect(
            PerformanceLayout.mainColumnMinimumWidth >=
                PerformanceLayout.stageCardMinimumWidth * 4
                + PerformanceLayout.columnSpacing * 3
        )
    }

    @Test("La prévisualisation n'anime que l'effet de respiration actif")
    func previewAnimationIsGated() {
        #expect(PerformancePreviewSchedule.shouldAnimate(
            isEnabled: true,
            isBreathing: true,
            isViewActive: true
        ))
        #expect(!PerformancePreviewSchedule.shouldAnimate(
            isEnabled: false,
            isBreathing: true,
            isViewActive: true
        ))
        #expect(!PerformancePreviewSchedule.shouldAnimate(
            isEnabled: true,
            isBreathing: false,
            isViewActive: true
        ))
        #expect(!PerformancePreviewSchedule.shouldAnimate(
            isEnabled: true,
            isBreathing: true,
            isViewActive: false
        ))
    }
}
