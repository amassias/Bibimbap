import SwiftUI

/// Les constantes de mise en forme, en un seul endroit.
///
/// L'accent n'est pas défini ici : il vient de la teinte système choisie par
/// l'utilisateur dans les Réglages de macOS. Imposer un bleu maison à une application
/// qui se veut native serait un contresens.
public enum Theme {
    /// Échelle d'espacement. Toute valeur d'écart vient d'ici.
    public enum Space {
        public static let hairline: CGFloat = 2
        public static let tight: CGFloat = 4
        public static let snug: CGFloat = 6
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let xlarge: CGFloat = 20
        public static let section: CGFloat = 24
        public static let page: CGFloat = 28
    }

    public enum Shell {
        public static let titleBarHeight: CGFloat = 52
        public static let sidebarWidth: CGFloat = 235
        public static let sidebarMinimumWidth: CGFloat = 210
        public static let sidebarMaximumWidth: CGFloat = 420
        public static let deviceHeaderHeight: CGFloat = 142
        public static let footerHeight: CGFloat = 68
        public static let detailMaximumWidth: CGFloat = 1_300
    }

    public enum Radius {
        public static let control: CGFloat = 6
        public static let chip: CGFloat = 8
        public static let group: CGFloat = 10
        public static let panel: CGFloat = 12
    }

    /// Rythme vertical d'une ligne de réglage. Assez d'air pour respirer, assez serré
    /// pour qu'un écran de réglages tienne sans devenir un couloir.
    public enum Row {
        public static let verticalPadding: CGFloat = 10
        public static let horizontalPadding: CGFloat = 14
        public static let minimumHeight: CGFloat = 34
        /// Largeur réservée aux valeurs numériques, pour qu'elles s'alignent en colonne.
        public static let valueWidth: CGFloat = 58
    }

    public enum Motion {
        /// Changements d'état : sélection, bascule, apparition d'un contrôle.
        public static let state = Animation.easeOut(duration: 0.18)
        /// Réagencements : barre d'actions, dépliage d'un détail.
        public static let layout = Animation.easeOut(duration: 0.24)
    }
}

/// Neutralise l'animation quand le système demande de réduire le mouvement.
///
/// Le réglage d'accessibilité n'est pas une suggestion : une animation qui subsiste
/// malgré lui est un défaut, pas une signature.
struct RespectfulAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Anime un changement, sauf si le système demande de réduire le mouvement.
    func animates<Value: Equatable>(_ value: Value, using animation: Animation = Theme.Motion.state) -> some View {
        modifier(RespectfulAnimation(animation: animation, value: value))
    }
}

// MARK: - Vocabulaire typographique

extension Text {
    /// Titre d'un groupe de réglages. Discret et en capitales de casse normale :
    /// il structure sans concurrencer les libellés qu'il coiffe.
    func groupTitle() -> some View {
        font(.subheadline.weight(.semibold))
    }

    /// Texte d'appoint sous un libellé ou un titre.
    func supporting() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Valeur numérique, alignée en colonne avec ses voisines.
    func settingValue() -> some View {
        font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// Rappel discret d'un raccourci clavier, à côté du bouton qu'il déclenche.
///
/// Sur un fond accentué, le gris habituel deviendrait illisible : la teinte suit donc
/// le fond plutôt que de rester secondaire par réflexe.
struct ShortcutHint: View {
    let keys: String
    var onAccent = false

    init(_ keys: String, onAccent: Bool = false) {
        self.keys = keys
        self.onAccent = onAccent
    }

    var body: some View {
        Text(keys)
            .font(.caption.weight(.medium))
            .foregroundStyle(onAccent ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
            .accessibilityHidden(true)
    }
}
