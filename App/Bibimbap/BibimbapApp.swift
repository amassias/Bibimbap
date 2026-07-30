import AppKit
import BibimbapFeatures
import BibimbapUI
import Foundation
import SwiftUI

/// Ne sert qu'à poser la politique d'activation au bon moment.
///
/// Il faut le faire avant que la première fenêtre n'existe, sinon l'icône du Dock
/// apparaît puis disparaît à chaque lancement en mode barre des menus.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MenuBarPreferences.shared.applyActivationPolicy()
    }
}

@main
struct BibimbapApp: App {
    /// Le transport simulé est activable uniquement pour les captures et le développement.
    /// Une distribution normale utilise toujours le périphérique réel.
    @State private var model = ProcessInfo.processInfo.environment["BIBIMBAP_SIMULATED"] == "1"
        ? AppModel.simulated()
        : AppModel.live()

    @State private var preferences = MenuBarPreferences.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Bibimbap", id: "main") {
            RootView(model: model)
                .frame(minWidth: 980, minHeight: 700)
                .environment(\.locale, preferences.locale)
                .id(preferences.language)
                // L'accessoire de barre des menus lance la même connexion : le garde-fou
                // évite deux balayages quand les deux scènes apparaissent au lancement.
                .task { if model.connection == .idle { await model.connect() } }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Appliquer les modifications") {
                    Task { await model.apply() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canApply)

                Button("Annuler les modifications") {
                    model.revert()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.hasPendingChanges)

                Divider()

                Button("Relire le périphérique") {
                    Task { await model.reload() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        // Accessoire de barre des menus. Le modèle est le même objet que celui de la
        // fenêtre : les deux vues lisent le même état relu, jamais deux copies.
        MenuBarExtra(isInserted: $preferences.isMenuBarIconVisible) {
            MenuBarMenu(model: model, preferences: preferences)
                .environment(\.locale, preferences.locale)
                .id(preferences.language)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}
