import Foundation
import Testing

/// Vérifie que le catalogue de chaînes couvre réellement ce que le code demande.
///
/// `L10n.string` retombe sur la clé quand le catalogue ne la connaît pas. C'est un
/// repli silencieux : rien ne casse, rien ne s'affiche en rouge, et la langue source
/// de la clé fuit simplement dans l'autre langue. Le projet écrit ses clés tantôt en
/// anglais tantôt en français, donc une clé manquante montrait bel et bien du français
/// dans l'interface anglaise — « emplacement 0x00000000 » sous le sélecteur de profil.
///
/// Ce test relit les sources plutôt que l'application : c'est la seule façon de voir
/// une clé oubliée avant qu'elle n'atteigne l'écran.
@Suite("Couverture du catalogue de chaînes")
struct CatalogCoverageTests {
    /// Racine du dépôt, déduite de l'emplacement de ce fichier.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // BibimbapLocalizationTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // racine

    static let catalogURL = repositoryRoot
        .appending(path: "App/Bibimbap/Localizable.xcstrings")

    /// Clés littérales passées à `L10n.string` / `L10n.format`.
    ///
    /// Seuls les littéraux sont détectables, et c'est suffisant : une clé calculée ne
    /// pourrait de toute façon pas être traduite à l'avance.
    static func keysUsedInSources() throws -> [String: String] {
        let pattern = #"L10n\.(?:string|format)\(\s*"((?:[^"\\]|\\.)*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        var keys: [String: String] = [:]

        for directory in ["Sources", "App"] {
            let root = repositoryRoot.appending(path: directory)
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }

            for case let url as URL in walker where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)

                for match in regex.matches(in: source, range: range) {
                    guard let captured = Range(match.range(at: 1), in: source) else { continue }
                    let key = String(source[captured])
                        .replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\n", with: "\n")
                    keys[key] = url.lastPathComponent
                }
            }
        }

        return keys
    }

    static func catalogEntries() throws -> [String: [String: String]] {
        let data = try Data(contentsOf: catalogURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = root?["strings"] as? [String: Any] ?? [:]

        return strings.mapValues { entry in
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            return localizations.compactMapValues { localization in
                ((localization as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            }
        }
    }

    @Test("Chaque clé utilisée par le code existe dans le catalogue")
    func everyKeyIsDeclared() throws {
        let used = try Self.keysUsedInSources()
        let catalog = try Self.catalogEntries()
        #expect(!used.isEmpty, "Aucune clé détectée : l'extraction est cassée.")

        let missing = used.filter { catalog[$0.key] == nil }
            .map { "\($0.value) : \"\($0.key)\"" }
            .sorted()

        #expect(
            missing.isEmpty,
            """
            \(missing.count) clé(s) absente(s) du catalogue. Sans entrée, L10n affiche la \
            clé telle quelle, donc sa langue source fuit dans l'autre langue :
            \(missing.joined(separator: "\n"))
            """
        )
    }

    @Test("Chaque clé est traduite dans les deux langues")
    func everyKeyIsTranslatedInBothLanguages() throws {
        let used = try Self.keysUsedInSources()
        let catalog = try Self.catalogEntries()

        let incomplete = used.keys.compactMap { key -> String? in
            guard let localizations = catalog[key] else { return nil }
            let absent = ["en", "fr"].filter { language in
                (localizations[language] ?? "").isEmpty
            }
            return absent.isEmpty ? nil : "\"\(key)\" → manque \(absent.joined(separator: ", "))"
        }.sorted()

        #expect(incomplete.isEmpty, "\(incomplete.joined(separator: "\n"))")
    }

    /// Type attendu pour chaque argument d'un format, indexé par sa position.
    ///
    /// Une traduction a le droit de passer en spécificateurs positionnels — le français
    /// le fait souvent pour réordonner la phrase — donc `%d` et `%1$d` décrivent bien le
    /// même argument. Ce qui ne doit pas changer, c'est le nombre d'arguments et le type
    /// attendu à chaque position : perdre un `%@` ou le voir devenir `%d` fait planter le
    /// formatage à l'exécution, dans la langue qu'on teste le moins.
    static func argumentTypes(_ text: String) throws -> [Int: String] {
        let specifier = try NSRegularExpression(pattern: #"%(?:%|(\d+)\$)?([@dfs])?"#)
        let range = NSRange(text.startIndex..., in: text)
        var types: [Int: String] = [:]
        var nextImplicitPosition = 1

        for match in specifier.matches(in: text, range: range) {
            // `%%` est un pourcentage littéral, pas un argument.
            guard let type = Range(match.range(at: 2), in: text).map({ String(text[$0]) })
            else { continue }

            let position: Int
            if let explicit = Range(match.range(at: 1), in: text),
               let parsed = Int(text[explicit]) {
                position = parsed
            } else {
                position = nextImplicitPosition
                nextImplicitPosition += 1
            }
            types[position] = type
        }

        return types
    }

    @Test("Les traductions conservent les arguments de format de la clé")
    func translationsKeepFormatArguments() throws {
        let used = try Self.keysUsedInSources()
        let catalog = try Self.catalogEntries()

        let mismatched = try used.keys.compactMap { key -> String? in
            guard let localizations = catalog[key] else { return nil }
            let expected = try Self.argumentTypes(key)

            let wrong = try localizations.filter { _, value in
                try Self.argumentTypes(value) != expected
            }.keys.sorted()

            return wrong.isEmpty ? nil : "\"\(key)\" → \(wrong.joined(separator: ", "))"
        }.sorted()

        #expect(mismatched.isEmpty, "\(mismatched.joined(separator: "\n"))")
    }
}
