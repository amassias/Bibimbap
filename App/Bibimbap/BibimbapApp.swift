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
            AppWindowContent(model: model, preferences: preferences)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Bibimbap") {
                    BibimbapApplicationActions.showAbout()
                }
            }

            CommandGroup(replacing: .help) {
                Button("Bibimbap Help") {
                    BibimbapApplicationActions.openHelp()
                }
                .keyboardShortcut("?", modifiers: .command)
            }

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

                Button(model.requiresExplicitReread
                       ? "Récupérer l'état matériel"
                       : model.hasPendingChanges
                           ? "Relire et comparer"
                           : "Relire le périphérique") {
                    Task {
                        if model.requiresExplicitReread {
                            await model.recoverUncertainHardware()
                        } else {
                            await model.rereadAndCompare()
                        }
                    }
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

/// Contenu de la fenêtre principale, séparé de la scène pour observer l'apparence
/// macOS qui entoure l'override éventuel de Bibimbap.
private struct AppWindowContent: View {
    let model: AppModel
    @Bindable var preferences: MenuBarPreferences

    var body: some View {
        RootView(model: model)
            .frame(minWidth: 980, minHeight: 700)
            .environment(\.locale, preferences.locale)
            // En mode System, nil retire l'override explicite et laisse macOS piloter
            // l'apparence; l'identifiant force SwiftUI à reconstruire le contenu.
            .preferredColorScheme(preferences.preferredColorScheme)
            .id("\(preferences.language.rawValue)-\(preferences.appearance.rawValue)")
            // L'accessoire de barre des menus lance la même connexion : le garde-fou
            // évite deux balayages quand les deux scènes apparaissent au lancement.
            .task { if model.connection == .idle { await model.connect() } }
    }
}
