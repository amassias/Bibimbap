import AppKit

/// Actions d'application partagées par les menus macOS et les contrôles dans la fenêtre.
///
/// Les centraliser évite les faux boutons qui changent seulement de section sans accomplir
/// l'action annoncée.
public enum BibimbapApplicationActions {
    private static let helpURL = URL(string: "https://github.com/amassias/Bibimbap#readme")!

    @MainActor
    public static func showAbout() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Bibimbap",
            .applicationVersion:
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "1.2.0",
            .credits: NSAttributedString(
                string: "Native Pulsar mouse configurator for macOS."
            ),
        ])
    }

    @MainActor
    public static func openHelp() {
        NSWorkspace.shared.open(helpURL)
    }

    /// Ouvre directement le volet « Surveillance de l'entrée » des Réglages Système.
    ///
    /// C'est la seule action qui puisse débloquer une permission refusée : l'application
    /// ne peut pas se l'accorder elle-même, et redemander l'accès ne réaffiche plus la
    /// fenêtre système une fois le refus enregistré.
    @MainActor
    public static func openInputMonitoringSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        )!
        NSWorkspace.shared.open(url)
    }
}
