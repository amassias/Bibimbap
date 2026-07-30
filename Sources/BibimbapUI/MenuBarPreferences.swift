import AppKit
import BibimbapLocalization
import Observation
import SwiftUI

/// Préférences de présence de l'application : icône dans la barre des menus, icône du Dock.
///
/// Ces deux réglages ne sont pas indépendants. Masquer le Dock alors que la barre des
/// menus est vide rendrait l'application injoignable : il resterait un processus vivant
/// sans aucun moyen de le rappeler. La contrainte est tenue ici plutôt que par une
/// consigne dans l'interface.
@MainActor
@Observable
public final class MenuBarPreferences {
    public static let shared = MenuBarPreferences()

    private enum Key {
        static let menuBarIcon = "menuBarIconVisible"
        static let dockIcon = "dockIconHidden"
        static let language = L10n.defaultsKey
        static let appearance = "appAppearance"
    }

    private let defaults: UserDefaults

    public var isMenuBarIconVisible: Bool {
        didSet {
            // Voir la note de classe : on ne se retire jamais les deux points d'entrée.
            if !isMenuBarIconVisible && isDockIconHidden {
                isDockIconHidden = false
            }
            defaults.set(isMenuBarIconVisible, forKey: Key.menuBarIcon)
        }
    }

    public var isDockIconHidden: Bool {
        didSet {
            if isDockIconHidden && !isMenuBarIconVisible {
                isMenuBarIconVisible = true
            }
            defaults.set(isDockIconHidden, forKey: Key.dockIcon)
            applyActivationPolicy()
        }
    }

    public var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
        }
    }

    public var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
        }
    }

    public var locale: Locale { language.locale }
    public var preferredColorScheme: ColorScheme? { appearance.colorScheme }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // L'icône de barre des menus est présente par défaut ; le Dock aussi.
        isMenuBarIconVisible = defaults.object(forKey: Key.menuBarIcon) as? Bool ?? true
        isDockIconHidden = defaults.object(forKey: Key.dockIcon) as? Bool ?? false
        language = defaults.string(forKey: Key.language)
            .flatMap(AppLanguage.init(rawValue:))
            ?? .english
        appearance = defaults.string(forKey: Key.appearance)
            .flatMap(AppAppearance.init(rawValue:))
            ?? .system
    }

    /// Aligne la politique d'activation sur la préférence, au lancement et à chaque bascule.
    ///
    /// À appeler depuis `applicationWillFinishLaunching`, pas depuis l'initialiseur de la
    /// scène : `NSApp` n'existe pas encore à ce moment-là, et l'application s'arrête net.
    public func applyActivationPolicy() {
        NSApplication.shared.setActivationPolicy(isDockIconHidden ? .accessory : .regular)
    }
}

public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case dark
    case system
    case light

    public var id: String { rawValue }

    public var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .system: nil
        case .light: .light
        }
    }
}
