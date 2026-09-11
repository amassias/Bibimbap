import Foundation
import SwiftUI
import Testing

@testable import BibimbapUI

@Suite("Apparence de l'interface")
struct MenuBarPreferencesTests {
    @Test("System reprend l'apparence macOS courante")
    func systemFollowsCurrentMacOSAppearance() {
        let preferences = AppAppearance.system

        #expect(preferences.resolvedColorScheme(for: .dark) == .dark)
        #expect(preferences.resolvedColorScheme(for: .light) == .light)
    }

    @Test("Un mode explicite reste inchangé quelle que soit l'apparence système")
    func explicitAppearanceOverridesSystem() {
        #expect(AppAppearance.dark.resolvedColorScheme(for: .light) == .dark)
        #expect(AppAppearance.light.resolvedColorScheme(for: .dark) == .light)
    }

    @Test("La transition Dark Light System retire l'override explicite")
    @MainActor
    func darkLightSystemTransitionClearsOverride() {
        // Un nom fixe plutôt qu'un UUID par exécution. `removePersistentDomain` vide bien
        // le domaine, mais cfprefsd a déjà écrit le plist et le réécrit derrière nous :
        // le fichier survit à la suppression, quoi qu'on tente. Avec un UUID, chaque
        // lancement de la suite abandonnait donc un dictionnaire vide de plus dans
        // ~/Library/Preferences. Un nom stable borne les dégâts à un seul fichier réutilisé.
        let suiteName = "BibimbapUITests.Appearance"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.removeSuite(named: suiteName)
        }

        let preferences = MenuBarPreferences(defaults: defaults)
        preferences.appearance = .dark
        #expect(preferences.preferredColorScheme == .dark)

        preferences.appearance = .light
        #expect(preferences.preferredColorScheme == .light)

        preferences.appearance = .system
        #expect(preferences.preferredColorScheme == nil)
        #expect(preferences.appearance.resolvedColorScheme(for: .dark) == .dark)
    }
}
