import BibimbapLocalization
import Foundation

/// Ce qu'il reste à trancher lorsqu'un brouillon local survit à une relecture.
///
/// Le principe du projet est que l'état relu fait foi. Mais écraser silencieusement un
/// brouillon parce que le câble a bougé revient à jeter le travail de l'utilisateur sans
/// le dire. La récupération garde donc les deux versions côte à côte et attend un choix
/// explicite — sans jamais écrire quoi que ce soit au périphérique.
public struct DraftRecovery: Equatable, Sendable {
    /// Pourquoi la comparaison a été déclenchée. Le message ne dit pas la même chose
    /// selon qu'on revient d'un débranchement ou que la souris a été touchée à la main.
    public enum Cause: Equatable, Sendable {
        /// Le périphérique est revenu après un débranchement ou une veille.
        case reconnected
        /// Le périphérique a signalé un changement provoqué depuis la souris.
        case deviceReportedChange
        /// L'utilisateur a demandé une relecture et une comparaison explicites.
        case explicitComparison

        public var label: String {
            switch self {
            case .reconnected:
                L10n.string("Le périphérique s'est reconnecté pendant que des modifications attendaient.")
            case .deviceReportedChange:
                L10n.string("Les réglages ont changé sur la souris pendant que des modifications attendaient.")
            case .explicitComparison:
                L10n.string("La relecture demandée a trouvé des différences avec votre brouillon.")
            }
        }
    }

    public var cause: Cause
    /// Ce que l'utilisateur avait préparé, par rapport à la base du brouillon.
    public var localChanges: [PendingChange]
    /// Ce que le périphérique porte désormais, par rapport à la même base.
    public var remoteChanges: [PendingChange]
    /// Les réglages que les deux côtés modifient différemment.
    public var conflicts: [DraftConflict]

    public init(
        cause: Cause = .reconnected,
        localChanges: [PendingChange],
        remoteChanges: [PendingChange],
        conflicts: [DraftConflict]
    ) {
        self.cause = cause
        self.localChanges = localChanges
        self.remoteChanges = remoteChanges
        self.conflicts = conflicts
    }

    public var isEmpty: Bool {
        localChanges.isEmpty && remoteChanges.isEmpty && conflicts.isEmpty
    }
}

/// Un réglage que le brouillon et le périphérique ne décrivent plus de la même façon.
public struct DraftConflict: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var baseValue: String
    public var localValue: String
    public var remoteValue: String

    public init(id: String, label: String, baseValue: String, localValue: String, remoteValue: String) {
        self.id = id
        self.label = label
        self.baseValue = baseValue
        self.localValue = localValue
        self.remoteValue = remoteValue
    }
}

extension DraftRecovery {
    /// Compare un brouillon et un état relu à partir de la base commune.
    ///
    /// Les valeurs affichées viennent de `WritePlanner.changes`, c'est-à-dire des libellés
    /// déjà destinés à l'utilisateur — jamais des blocs d'octets du plan d'écriture.
    public static func between(
        local: [PendingChange],
        remote: [PendingChange],
        cause: Cause
    ) -> DraftRecovery? {
        guard !remote.isEmpty, !local.isEmpty else { return nil }

        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let conflicts = local.compactMap { change -> DraftConflict? in
            guard let opposite = remoteByID[change.id], opposite.after != change.after else { return nil }
            return DraftConflict(
                id: change.id,
                label: change.label,
                baseValue: change.before,
                localValue: change.after,
                remoteValue: opposite.after
            )
        }
        return DraftRecovery(
            cause: cause, localChanges: local, remoteChanges: remote, conflicts: conflicts
        )
    }
}
