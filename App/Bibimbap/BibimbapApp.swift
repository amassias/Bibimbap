import BibimbapFeatures
import BibimbapUI
import Foundation
import SwiftUI

@main
struct BibimbapApp: App {
    /// Le transport simulé est activable uniquement pour les captures et le développement.
    /// Une distribution normale utilise toujours le périphérique réel.
    @State private var model = ProcessInfo.processInfo.environment["BIBIMBAP_SIMULATED"] == "1"
        ? AppModel.simulated()
        : AppModel.live()

    var body: some Scene {
        Window("Bibimbap", id: "main") {
            RootView(model: model)
                .frame(minWidth: 980, minHeight: 700)
                .preferredColorScheme(.light)
                .task { await model.connect() }
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
    }
}
