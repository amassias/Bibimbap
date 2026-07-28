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
                String(localized: "Cette sauvegarde est en version \(version), que cette application ne sait pas relire.")
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
            skipped.append(String(localized: "Polling (\(settings.reportRateHertz) Hz)"))
        }

        if settings.debounceMilliseconds <= capabilities.maximumDebounce {
            result.debounceMilliseconds = settings.debounceMilliseconds
        } else {
            skipped.append(String(localized: "Temps de rebond"))
        }

        result.liftOffMillimetres = settings.liftOffMillimetres
        result.sleepMinutes = settings.sleepMinutes
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
              into: &result.motionSync, labelled: String(localized: "Motion Sync"))
        adopt(capabilities.supportsAngleSnap, settings.angleSnap,
              into: &result.angleSnap, labelled: String(localized: "Angle Snap"))
        adopt(capabilities.supportsRippleControl, settings.rippleControl,
              into: &result.rippleControl, labelled: String(localized: "Ripple Control"))
        adopt(capabilities.supportsPerformanceMode, settings.performanceMode,
              into: &result.performanceMode, labelled: String(localized: "Mode performance"))

        if capabilities.supportsRotation {
            result.rotationDegrees = settings.rotationDegrees
        } else if settings.rotationDegrees != 0 {
            skipped.append(String(localized: "Calibration de rotation"))
        }

        if capabilities.supportsLongDistance {
            result.longDistance = settings.longDistance
        } else if settings.longDistance {
            skipped.append(String(localized: "Mode longue portée"))
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
                    skipped.append(String(localized: "Palier \(saved.index + 1) ramené à \(snappedX) DPI"))
                }
                result.dpiStages[index].x = snappedX
                result.dpiStages[index].y = snappedY
                result.dpiStages[index].color = saved.color
            }
        }

        // Boutons : uniquement ceux qui existent sur ce modèle.
        for saved in settings.buttons {
            guard let index = result.buttons.firstIndex(where: { $0.index == saved.index }) else {
                skipped.append(String(localized: "Bouton \(saved.index + 1) (absent de ce modèle)"))
                continue
            }
            result.buttons[index] = saved
        }

        result.macros = settings.macros.filter { $0.slot < capabilities.buttonCount }
        let droppedMacros = settings.macros.count - result.macros.count
        if droppedMacros > 0 {
            skipped.append(String(localized: "\(droppedMacros) macro(s) hors des emplacements de ce modèle"))
        }

        return (result, skipped)
    }
}
