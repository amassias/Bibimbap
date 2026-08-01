import BibimbapLocalization
import Foundation
import PulsarCatalog

/// Une commande configurable telle qu'elle est présentée à l'utilisateur.
///
/// Elle rassemble en un seul endroit les deux numérotations que le reste du code doit
/// cesser de confondre :
///
/// - `firmwareIndex` est l'index déclaré par le catalogue. Il adresse la flash, les
///   emplacements de macro et les opérations d'écriture. Il peut être discontinu :
///   certains modèles déclarent `0, 1, 2, 6, 4, 3`.
/// - `displayNumber` est le rang lu à l'écran, toujours de 1 à N, dans l'ordre officiel
///   cMouse. Il n'est jamais calculé à partir de l'index firmware.
///
/// Les lignes d'affectation et les repères de la carte sont construits depuis la même
/// liste : il ne peut donc pas y avoir plus de repères que de lignes, ni l'inverse.
public struct ButtonPresentation: Identifiable, Equatable, Sendable {
    public var assignment: DeviceSettings.ButtonAssignment
    public var profile: ButtonProfile
    /// Numéro montré à l'utilisateur, de 1 à N.
    public var displayNumber: Int

    public var id: Int { firmwareIndex }

    /// Index réellement utilisé par le protocole.
    public var firmwareIndex: Int { profile.index }

    /// Géométrie officielle du repère, absente quand le catalogue n'en publie pas.
    public var geometry: ButtonProfile.Geometry? { profile.geometry }

    public init(
        assignment: DeviceSettings.ButtonAssignment,
        profile: ButtonProfile,
        displayNumber: Int
    ) {
        self.assignment = assignment
        self.profile = profile
        self.displayNumber = displayNumber
    }

    /// Libellé du bouton, tiré du rôle publié par le catalogue.
    ///
    /// Un modèle dont le catalogue ne laisse pas déduire le rôle est nommé par son
    /// numéro visible plutôt que par un rôle supposé depuis l'index.
    public var label: String {
        switch profile.role {
        case .primaryClick: L10n.string("Left Click")
        case .secondaryClick: L10n.string("Right Click")
        case .wheelClick: L10n.string("Middle Click")
        case .back: L10n.string("Back")
        case .forward: L10n.string("Forward")
        case .dpiCycle: L10n.string("DPI Cycle")
        case .dpiLock: L10n.string("DPI Lock")
        case .unknown: numberLabel
        }
    }

    /// « Button N », où N est le numéro visible.
    public var numberLabel: String {
        L10n.format("Button %d", displayNumber)
    }

    /// Position du repère sur la photographie, de 0 à 1 sur chaque axe.
    ///
    /// `nil` quand le catalogue ne publie pas de géométrie : l'affectation reste
    /// affichée, mais aucun repère n'est posé à une place inventée.
    public var normalizedMarker: (x: Double, y: Double)? {
        geometry?.normalizedMarker
    }

    /// Les commandes d'un modèle, dans l'ordre officiel, numérotées de 1 à N.
    ///
    /// Seuls les boutons déclarés par la famille produisent une entrée : une affectation
    /// relue pour un index absent du catalogue est ignorée plutôt qu'affichée.
    public static func list(
        family: DeviceFamily,
        settings: DeviceSettings
    ) -> [ButtonPresentation] {
        family.orderedButtons.enumerated().compactMap { position, profile in
            guard let assignment = settings.buttons.first(where: { $0.index == profile.index })
            else { return nil }
            return ButtonPresentation(
                assignment: assignment,
                profile: profile,
                displayNumber: position + 1
            )
        }
    }
}
