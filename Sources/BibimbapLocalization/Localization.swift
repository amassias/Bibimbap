import Foundation

/// Langues proposées par l'application.
///
/// L'anglais est volontairement la valeur de repli, indépendamment de la langue de
/// macOS. Le choix reste local à Bibimbap et peut être changé sans redémarrage.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case french = "fr"

    public var id: String { rawValue }
    public var locale: Locale { Locale(identifier: rawValue) }

    public var nativeName: String {
        switch self {
        case .english: "English"
        case .french: "Français"
        }
    }
}

/// Résout explicitement les chaînes dans la langue choisie par Bibimbap.
///
/// `String(localized:)` suit normalement les préférences globales de macOS. Ici, le
/// produit demande un anglais par défaut et un sélecteur interne ; le code de langue
/// est donc lu à chaque résolution afin que les libellés calculés hors des vues SwiftUI
/// suivent eux aussi le changement instantanément.
public enum L10n {
    public static let defaultsKey = "appLanguage"

    public static var language: AppLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return .english
        }
        return language
    }

    public static func string(
        _ key: String,
        comment: StaticString? = nil
    ) -> String {
        let localizedBundle = Bundle.main.path(
            forResource: language.rawValue,
            ofType: "lproj"
        )
        .flatMap(Bundle.init(path:))

        return (localizedBundle ?? .main).localizedString(
            forKey: key,
            value: key,
            table: nil
        )
    }

    /// Localise d'abord un format stable, puis y injecte les valeurs. Garder les
    /// variables hors de la clé permet au catalogue anglais/français de retrouver
    /// exactement la même entrée à chaque exécution.
    public static func format(
        _ resource: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: string(resource),
            locale: language.locale,
            arguments: arguments
        )
    }
}
