import BibimbapLocalization
import Foundation
import PulsarCatalog
import PulsarProtocol

/// Différence entre deux profils, exprimée avec les valeurs que l'utilisateur voit.
public struct ProfileDifference: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var before: String
    public var after: String

    public init(id: String, label: String, before: String, after: String) {
        self.id = id
        self.label = label
        self.before = before
        self.after = after
    }
}

/// Résultat d'une comparaison explicite de deux emplacements matériels.
public struct ProfileComparison: Equatable, Sendable {
    public var left: ProfileArchive
    public var right: ProfileArchive
    public var differences: [ProfileDifference]

    public init(
        left: ProfileArchive,
        right: ProfileArchive,
        differences: [ProfileDifference]
    ) {
        self.left = left
        self.right = right
        self.differences = differences
    }

    public var isIdentical: Bool { differences.isEmpty }
}

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
    /// Emplacement matériel sélectionné au moment de l'export, lorsqu'il est connu.
    /// Optionnel pour conserver la lisibilité des archives v1 déjà créées.
    public var profileSlot: Int?
    /// Localisation de la collection HID au moment de l'export, par exemple `0x00000000`.
    public var hardwareLocation: String?
    public var hardwareTransport: String?

    public init(
        snapshot: DeviceSnapshot,
        profileSlot: Int? = nil,
        hardwareLocation: String? = nil,
        hardwareTransport: String? = nil
    ) {
        version = Self.currentVersion
        createdAt = Date()
        deviceName = snapshot.productName
        cid = snapshot.identity.cid
        mid = snapshot.identity.mid
        sensorType = snapshot.family.sensor.type
        settings = snapshot.settings
        self.profileSlot = profileSlot ?? snapshot.activeProfile
        self.hardwareLocation = hardwareLocation
        self.hardwareTransport = hardwareTransport
    }

    public var profileLabel: String {
        guard let profileSlot else { return L10n.string("Profil non indiqué") }
        return L10n.format("Profil %d", profileSlot + 1)
    }

    public var hardwareLocationLabel: String {
        var parts = [deviceName]
        if let hardwareTransport, !hardwareTransport.isEmpty {
            parts.append(hardwareTransport)
        }
        if let hardwareLocation, !hardwareLocation.isEmpty {
            parts.append(L10n.format("emplacement %@", hardwareLocation))
        }
        return parts.joined(separator: " · ")
    }

    public enum ArchiveError: Error, LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case invalidProfileSlot(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                L10n.format("This backup uses version %d, which this app cannot read.", version)
            case .invalidProfileSlot(let slot):
                L10n.format("This backup refers to unsupported hardware profile %d.", slot + 1)
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
        if let profileSlot = archive.profileSlot,
           !(0..<DeviceController.profileCount).contains(profileSlot) {
            throw ArchiveError.invalidProfileSlot(profileSlot)
        }
        return archive
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Compare uniquement les réglages, jamais les métadonnées d'export. Deux archives
    /// provenant de ports différents peuvent donc être comparées sans faire croire que
    /// leur emplacement HID constitue une modification de configuration.
    public func differences(to other: ProfileArchive) -> [ProfileDifference] {
        Self.differences(between: self, and: other)
    }

    public static func differences(
        between left: ProfileArchive,
        and right: ProfileArchive
    ) -> [ProfileDifference] {
        var differences: [ProfileDifference] = []

        func append(
            _ id: String,
            _ label: String,
            _ before: String,
            _ after: String
        ) {
            guard before != after else { return }
            differences.append(ProfileDifference(
                id: id, label: label, before: before, after: after
            ))
        }

        let lhs = left.settings
        let rhs = right.settings
        append(
            "perf.rate", L10n.string("Polling"),
            DeviceSettingValueFormatter.reportRate(lhs.reportRateHertz),
            DeviceSettingValueFormatter.reportRate(rhs.reportRateHertz)
        )
        append(
            "dpi.count", L10n.string("Nombre de paliers"),
            DeviceSettingValueFormatter.stageCount(lhs.enabledStageCount),
            DeviceSettingValueFormatter.stageCount(rhs.enabledStageCount)
        )
        append(
            "dpi.active", L10n.string("Palier actif"),
            DeviceSettingValueFormatter.activeStage(lhs.activeStage),
            DeviceSettingValueFormatter.activeStage(rhs.activeStage)
        )
        append(
            "perf.lod", L10n.string("Distance de décrochage"),
            DeviceSettingValueFormatter.value(for: "perf.lod", in: lhs),
            DeviceSettingValueFormatter.value(for: "perf.lod", in: rhs)
        )
        append(
            "perf.debounce", L10n.string("Temps de rebond"),
            DeviceSettingValueFormatter.value(for: "perf.debounce", in: lhs),
            DeviceSettingValueFormatter.value(for: "perf.debounce", in: rhs)
        )
        append(
            "perf.motionSync", L10n.string("Motion Sync"),
            DeviceSettingValueFormatter.value(for: "perf.motionSync", in: lhs),
            DeviceSettingValueFormatter.value(for: "perf.motionSync", in: rhs)
        )
        append(
            "perf.angleSnap", L10n.string("Angle Snap"),
            DeviceSettingValueFormatter.value(for: "perf.angleSnap", in: lhs),
            DeviceSettingValueFormatter.value(for: "perf.angleSnap", in: rhs)
        )
        append(
            "perf.ripple", L10n.string("Ripple Control"),
            DeviceSettingValueFormatter.value(for: "perf.ripple", in: lhs),
            DeviceSettingValueFormatter.value(for: "perf.ripple", in: rhs)
        )
        append(
            "perf.performanceState", L10n.string("Mode performance"),
            DeviceSettingValueFormatter.value(for: "perf.performanceState", in: lhs),
            DeviceSettingValueFormatter.value(for: "perf.performanceState", in: rhs)
        )
        append(
            "perf.sensorMode", L10n.string("Mode capteur"),
            DeviceSettingValueFormatter.value(for: "perf.sensorMode", in: lhs),
            DeviceSettingValueFormatter.value(for: "perf.sensorMode", in: rhs)
        )
        append(
            "perf.rotation", L10n.string("Rotation"),
            DeviceSettingValueFormatter.value(for: "perf.rotation", in: lhs),
            DeviceSettingValueFormatter.value(for: "perf.rotation", in: rhs)
        )
        append(
            "light.mode", L10n.string("Effet DPI"),
            DeviceSettingValueFormatter.value(for: "light.mode", in: lhs),
            DeviceSettingValueFormatter.value(for: "light.mode", in: rhs)
        )
        append(
            "light.brightness", L10n.string("Luminosité"),
            DeviceSettingValueFormatter.value(for: "light.brightness", in: lhs),
            DeviceSettingValueFormatter.value(for: "light.brightness", in: rhs)
        )
        append(
            "light.speed", L10n.string("Vitesse de l'effet DPI"),
            DeviceSettingValueFormatter.value(for: "light.speed", in: lhs),
            DeviceSettingValueFormatter.value(for: "light.speed", in: rhs)
        )
        append(
            "light.state", L10n.string("Indicateur DPI"),
            DeviceSettingValueFormatter.value(for: "light.state", in: lhs),
            DeviceSettingValueFormatter.value(for: "light.state", in: rhs)
        )
        append(
            "power.sleep", L10n.string("Mise en veille"),
            DeviceSettingValueFormatter.value(for: "power.sleep", in: lhs),
            DeviceSettingValueFormatter.value(for: "power.sleep", in: rhs)
        )
        append(
            "power.saveBattery", L10n.string("Seuil d'économie"),
            DeviceSettingValueFormatter.value(for: "power.saveBattery", in: lhs),
            DeviceSettingValueFormatter.value(for: "power.saveBattery", in: rhs)
        )
        append(
            "power.longDistance", L10n.string("Mode longue portée"),
            DeviceSettingValueFormatter.value(for: "power.longDistance", in: lhs),
            DeviceSettingValueFormatter.value(for: "power.longDistance", in: rhs)
        )

        for index in sortedIndices(lhs.dpiStages, rhs.dpiStages) {
            guard let leftStage = lhs.dpiStages.first(where: { $0.index == index }),
                  let rightStage = rhs.dpiStages.first(where: { $0.index == index }) else {
                continue
            }
            append(
                "dpi.value.\(index)", L10n.format("Stage %d", index + 1),
                DeviceSettingValueFormatter.dpi(leftStage),
                DeviceSettingValueFormatter.dpi(rightStage)
            )
            append(
                "dpi.color.\(index)", L10n.format("Stage %d color", index + 1),
                DeviceSettingValueFormatter.color(leftStage.color),
                DeviceSettingValueFormatter.color(rightStage.color)
            )
        }

        for index in sortedIndices(lhs.buttons, rhs.buttons) {
            guard let leftButton = lhs.buttons.first(where: { $0.index == index }),
                  let rightButton = rhs.buttons.first(where: { $0.index == index }) else {
                continue
            }
            append(
                "button.\(index)", L10n.format("Button %d", index + 1),
                DeviceSettingValueFormatter.button(leftButton),
                DeviceSettingValueFormatter.button(rightButton)
            )
        }

        for slot in sortedIndices(lhs.macros, rhs.macros) {
            let leftMacro = lhs.macros.first(where: { $0.slot == slot })
            let rightMacro = rhs.macros.first(where: { $0.slot == slot })
            let leftValue = leftMacro.map(DeviceSettingValueFormatter.macro)
                ?? L10n.string("Aucune macro")
            let rightValue = rightMacro.map(DeviceSettingValueFormatter.macro)
                ?? L10n.string("Aucune macro")
            append(
                "macro.\(slot)", L10n.format("Macro slot %d", slot + 1),
                leftValue, rightValue
            )
        }

        return differences
    }

    public func comparison(with other: ProfileArchive) -> ProfileComparison {
        ProfileComparison(
            left: self,
            right: other,
            differences: differences(to: other)
        )
    }

    private static func sortedIndices<T>(
        _ left: [T],
        _ right: [T]
    ) -> [Int] where T: Identifiable, T.ID == Int {
        Set(left.map(\.id) + right.map(\.id)).sorted()
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
