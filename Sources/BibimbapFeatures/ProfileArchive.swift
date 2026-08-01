import BibimbapLocalization
import Foundation
import PulsarCatalog
import PulsarProtocol

/// Sauvegarde locale d'un jeu de réglages, en JSON versionné.
///
/// La sauvegarde n'est jamais la source de vérité : les réglages actifs restent ceux
/// relus depuis la souris. Un fichier ne sert qu'à repeupler un brouillon, que
/// l'utilisateur applique ensuite comme n'importe quelle autre modification.
public struct ProfileArchive: Codable, Equatable, Sendable {
    /// Incrémenté dès qu'un champ change de sens. Un fichier plus récent que le lecteur
    /// est refusé plutôt que réinterprété de travers.
    public static let currentVersion = 1

    public var version: Int
    public var createdAt: Date
    public var deviceName: String
    public var cid: Int
    public var mid: Int
    public var sensorType: String
    public var settings: DeviceSettings

    public init(snapshot: DeviceSnapshot) {
        version = Self.currentVersion
        createdAt = Date()
        deviceName = snapshot.productName
        cid = snapshot.identity.cid
        mid = snapshot.identity.mid
        sensorType = snapshot.family.sensor.type
        settings = snapshot.settings
    }

    public enum ArchiveError: Error, LocalizedError, Equatable {
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                L10n.format("This backup uses version %d, which this app cannot read.", version)
            }
        }
    }

    public static func decode(from data: Data) throws -> ProfileArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(ProfileArchive.self, from: data)
        guard archive.version <= currentVersion else {
            throw ArchiveError.unsupportedVersion(archive.version)
        }
        return archive
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Adapte les réglages sauvegardés aux capacités du périphérique connecté.
    ///
    /// Renvoie les réglages retenus et la liste de ce qui a été écarté. Un champ qui ne
    /// passe pas est remplacé par la valeur actuelle du périphérique, jamais forcé :
    /// appliquer un réglage qu'un modèle ne sait pas représenter reviendrait à écrire
    /// n'importe quoi dans sa flash.
    public func settings(
        fittingFamily family: DeviceFamily,
        capabilities: DeviceCapabilities,
        catalog: DeviceCatalog,
        current: DeviceSettings
    ) -> (settings: DeviceSettings, skipped: [String]) {
        var result = current
        var skipped: [String] = []

        if capabilities.availableReportRates.contains(settings.reportRateHertz) {
            result.reportRateHertz = settings.reportRateHertz
        } else {
            skipped.append(L10n.format("Polling (%d Hz)", settings.reportRateHertz))
        }

        if settings.debounceMilliseconds <= capabilities.maximumDebounce {
            result.debounceMilliseconds = settings.debounceMilliseconds
        } else {
            skipped.append(L10n.string( "Temps de rebond"))
        }

        result.liftOffMillimetres = settings.liftOffMillimetres
        result.sleepTimeCode = settings.sleepTimeCode
        result.powerSaveBatteryPercent = settings.powerSaveBatteryPercent
        result.dpiEffect = settings.dpiEffect

        /// Reprend un interrupteur si le modèle le gère, le signale sinon.
        func adopt(
            _ supported: Bool,
            _ saved: Bool,
            into target: inout Bool,
            labelled label: String
        ) {
            if supported {
                target = saved
            } else if saved {
                skipped.append(label)
            }
        }

        adopt(capabilities.supportsMotionSync, settings.motionSync,
              into: &result.motionSync, labelled: L10n.string( "Motion Sync"))
        adopt(capabilities.supportsAngleSnap, settings.angleSnap,
              into: &result.angleSnap, labelled: L10n.string( "Angle Snap"))
        adopt(capabilities.supportsRippleControl, settings.rippleControl,
              into: &result.rippleControl, labelled: L10n.string( "Ripple Control"))
        adopt(capabilities.supportsPerformanceMode, settings.performanceMode,
              into: &result.performanceMode, labelled: L10n.string( "Mode performance"))

        if capabilities.supportsRotation {
            result.rotationDegrees = settings.rotationDegrees
        } else if settings.rotationDegrees != 0 {
            skipped.append(L10n.string( "Calibration de rotation"))
        }

        if capabilities.supportsLongDistance {
            result.longDistance = settings.longDistance
        } else if settings.longDistance {
            skipped.append(L10n.string( "Mode longue portée"))
        }

        // Paliers DPI : seuls ceux que le capteur sait représenter sont repris.
        if let codec = DPICodec(family: family, catalog: catalog) {
            let count = min(settings.enabledStageCount, capabilities.maximumStages)
            result.enabledStageCount = max(1, count)
            result.activeStage = min(settings.activeStage, result.enabledStageCount - 1)

            for saved in settings.dpiStages {
                guard let index = result.dpiStages.firstIndex(where: { $0.index == saved.index }) else { continue }
                let snappedX = (try? codec.snap(dpi: saved.x)) ?? result.dpiStages[index].x
                let snappedY = (try? codec.snap(dpi: saved.y)) ?? result.dpiStages[index].y
                if snappedX != saved.x || snappedY != saved.y {
                    skipped.append(L10n.format("Stage %d adjusted to %d DPI", saved.index + 1, snappedX))
                }
                result.dpiStages[index].x = snappedX
                result.dpiStages[index].y = snappedY
                result.dpiStages[index].color = saved.color
            }
        }

        // Boutons : uniquement ceux qui existent sur ce modèle. La correspondance passe
        // par l'index firmware, jamais par la position dans la liste, qui suit l'ordre
        // d'affichage officiel et diffère d'un modèle à l'autre.
        for saved in settings.buttons {
            guard let index = result.buttons.firstIndex(where: { $0.index == saved.index }) else {
                skipped.append(L10n.format(
                    "Firmware button %d (not available on this model)", saved.index
                ))
                continue
            }
            result.buttons[index] = saved
        }

        // Un emplacement de macro porte l'index firmware du bouton qui le référence.
        // Comparer au nombre de boutons écarterait à tort l'emplacement 6 d'un modèle
        // qui déclare les index 0, 1, 2, 6, 4, 3.
        result.macros = settings.macros.filter {
            capabilities.firmwareButtonIndices.contains($0.slot)
        }
        let droppedMacros = settings.macros.count - result.macros.count
        if droppedMacros > 0 {
            skipped.append(L10n.format("%d macro(s) outside this model's slots", droppedMacros))
        }

        return (result, skipped)
    }
}
