import Foundation

/// Instantané versionné des capacités déclarées par le configurateur officiel.
///
/// Le fichier `catalog.json` est produit par `Tools/generate_catalog.py`. Il n'est jamais
/// rechargé depuis le réseau à l'exécution : une évolution du site déclenche une
/// régénération contrôlée du fichier, jamais l'exécution de code distant.
public struct DeviceCatalog: Sendable, Codable {
    public var schemaVersion: Int
    public var sourceVersion: String
    public var sourceURL: String
    public var deviceNameSourceURL: String
    public var vendorIDs: [UInt16]
    public var mouseProductIDs: ProductIDs
    public var sensors: [String: SensorRanges]
    public var families: [DeviceFamily]
    public var models: [DeviceModel]

    public struct ProductIDs: Sendable, Codable {
        public var wired: [UInt16]
        public var wireless: [UInt16]

        public var all: Set<UInt16> { Set(wired).union(wireless) }
    }

    /// Le catalogue embarqué dans l'application.
    public static let embedded: DeviceCatalog = {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json") else {
            preconditionFailure("catalog.json absent du bundle PulsarCatalog")
        }
        do {
            return try JSONDecoder().decode(DeviceCatalog.self, from: Data(contentsOf: url))
        } catch {
            preconditionFailure("catalog.json illisible : \(error)")
        }
    }()

    /// Capacités correspondant à un couple CID/MID lu sur le périphérique.
    ///
    /// Renvoie `nil` pour un périphérique reconnu comme Pulsar mais absent de l'instantané :
    /// l'interface doit alors afficher l'état « périphérique non reconnu » plutôt que
    /// d'appliquer des réglages devinés.
    public func family(cid: Int, mid: Int) -> DeviceFamily? {
        families.first { $0.cid == cid && $0.mids.contains(mid) }
    }

    /// Nom et visuel officiels associés à l'identité lue dans le handshake.
    public func model(cid: Int, mid: Int) -> DeviceModel? {
        models.first { $0.cid == cid && $0.mid == mid }
    }

    public func recognizes(vendorID: UInt16, productID: UInt16) -> Bool {
        vendorIDs.contains(vendorID) && mouseProductIDs.all.contains(productID)
    }

    public func sensorRanges(for family: DeviceFamily) -> SensorRanges? {
        sensors[family.sensor.type]
    }

    public func connection(forProductID productID: UInt16) -> CatalogConnection? {
        if mouseProductIDs.wired.contains(productID) { return .wired }
        if mouseProductIDs.wireless.contains(productID) { return .wireless }
        return nil
    }
}

/// Présentation d'un MID publiée par Bibimbap Web.
///
/// Les variantes et éditions limitées partagent parfois une même famille de réglages,
/// mais gardent ici leur nom et leur photographie propres.
public struct DeviceModel: Sendable, Codable, Identifiable {
    public var cid: Int
    public var mid: Int
    public var name: String
    public var imageName: String

    public var id: String { "\(cid)-\(mid)" }
}

public enum CatalogConnection: String, Sendable, Codable {
    case wired
    case wireless
}

/// Plages DPI d'un capteur, telles que déclarées par `sensor.json`.
///
/// Chaque plage a son propre pas et un code d'exposant sur deux bits, stocké dans
/// l'octet d'attributs du palier. Le codec (`DPICodec`) s'en sert pour convertir
/// entre DPI affiché et valeur brute.
public struct SensorRanges: Sendable, Codable {
    public var ranges: [Range]
    /// Vrai pour les capteurs dont les valeurs brutes passent par une table de
    /// correspondance. Aucun modèle du catalogue souris actuel n'est dans ce cas ;
    /// `DPICodec` refuse de convertir plutôt que d'approximer.
    public var hasLookupTable: Bool

    public struct Range: Sendable, Codable {
        public var minimum: Int
        public var maximum: Int
        public var step: Int
        public var exponentCode: UInt8
    }

    /// Plage contenant une valeur DPI donnée, ou la dernière si la valeur la dépasse.
    public func range(containing dpi: Int) -> Range? {
        ranges.last { dpi >= $0.minimum } ?? ranges.first
    }

    public func range(forExponentCode code: UInt8) -> Range? {
        ranges.first { $0.exponentCode == code }
    }

    public var minimumDPI: Int { ranges.first?.minimum ?? 0 }
    public var maximumDPI: Int { ranges.last?.maximum ?? 0 }
}

/// Un groupe de modèles partageant exactement les mêmes capacités.
public struct DeviceFamily: Sendable, Codable, Identifiable {
    public var cid: Int
    public var mids: [Int]
    public var theme: String
    public var microcontroller: String?
    public var sensor: SensorProfile
    public var dpi: DPIProfile
    public var buttons: [ButtonProfile]
    public var debounce: DebounceProfile
    public var power: PowerProfile
    public var supportsAngleTune: Bool
    public var supportsFanMode: Bool
    public var maximumReportRate: Int
    public var dongleFirmware: [String: String]
    public var firmware: FirmwareProfile

    public var id: String { "\(cid)-\(mids.first ?? 0)" }

    /// Les commandes du modèle dans l'ordre officiel cMouse.
    ///
    /// C'est cette liste, et elle seule, qui détermine le nombre de lignes et de repères
    /// affichés. Rien n'est complété jusqu'à six ni jusqu'au plus grand index.
    public var orderedButtons: [ButtonProfile] {
        buttons.sorted { $0.order < $1.order }
    }

    /// Les index firmware réellement déclarés par le modèle.
    ///
    /// Ils peuvent être discontinus : `slot < buttons.count` n'est donc jamais un test
    /// d'appartenance valable.
    public var firmwareButtonIndices: Set<Int> {
        Set(buttons.map(\.index))
    }

    public func button(firmwareIndex: Int) -> ButtonProfile? {
        buttons.first { $0.index == firmwareIndex }
    }

    /// Numéro montré à l'utilisateur pour un index firmware, de 1 à N.
    ///
    /// Renvoie `nil` pour un index que ce modèle ne déclare pas, plutôt qu'un numéro
    /// calculé à partir de l'index.
    public func displayNumber(firmwareIndex: Int) -> Int? {
        button(firmwareIndex: firmwareIndex).map { $0.order + 1 }
    }
}

public struct SensorProfile: Sendable, Codable {
    public var type: String
    public var defaultLiftOff: Int
    public var supportsMotionSync: Bool
    public var supportsAngleSnap: Bool
    public var supportsRippleControl: Bool
    public var supportsPerformanceMode: Bool
    public var defaultPerformance: Int
    public var defaultSensorMode: Int

    /// Le 3955 stocke ses paliers DPI dans une zone dédiée, sur 6 octets au lieu de 4.
    public var usesExtendedDPIBlock: Bool { type == "3955" }
}

public struct DPIProfile: Sendable, Codable {
    public var maximum: Int
    public var middle: Int
    public var defaultStage: Int
    public var stages: [DPIStageProfile]

    /// Pas d'incrément du capteur. Les valeurs intermédiaires sont arrondies à ce pas.
    public var step: Int { maximum > 32000 ? 50 : 10 }
    public var minimum: Int { 10 }
}

public struct DPIStageProfile: Sendable, Codable {
    public var value: Int
    public var color: CatalogColor
}

public struct CatalogColor: Sendable, Codable, Hashable {
    public var red: Int
    public var green: Int
    public var blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Une commande configurable déclarée par le catalogue officiel.
///
/// Deux numérotations coexistent et ne doivent jamais être confondues :
/// `index` adresse le firmware (blocs de fonction en flash, emplacements de macro) et
/// peut être discontinu ; `order` est le rang officiel dans `cfg.json`, qui fixe seul
/// l'ordre d'affichage et le numéro montré à l'utilisateur.
public struct ButtonProfile: Sendable, Codable, Equatable, Identifiable {
    /// Index firmware. Sert aux adresses flash ; jamais à l'affichage.
    public var index: Int
    /// Rang officiel dans la liste `keys` du modèle, à partir de 0.
    public var order: Int
    /// Géométrie du repère sur la photographie, absente si le catalogue n'en publie pas.
    public var geometry: Geometry?
    public var defaultType: Int
    public var defaultParameter: Int

    public var id: Int { index }

    public init(
        index: Int,
        order: Int,
        geometry: Geometry?,
        defaultType: Int,
        defaultParameter: Int
    ) {
        self.index = index
        self.order = order
        self.geometry = geometry
        self.defaultType = defaultType
        self.defaultParameter = defaultParameter
    }

    /// Position officielle de l'étiquette et de sa ligne de rappel.
    ///
    /// Le configurateur pose un bloc d'étiquette de 150 × 30 points à (`top`, `left`)
    /// dans un canevas fixe, puis trace `line` depuis ce bloc. L'extrémité de la ligne
    /// est le seul point qui désigne réellement le bouton sur la photographie ;
    /// `top`/`left` ne le donnent pas.
    public struct Geometry: Sendable, Codable, Equatable {
        public var top: Int
        public var left: Int
        public var line: Line

        public init(top: Int, left: Int, line: Line) {
            self.top = top
            self.left = left
            self.line = line
        }

        public struct Line: Sendable, Codable, Equatable {
            public var x1: Int
            public var y1: Int
            public var x2: Int
            public var y2: Int

            public init(x1: Int, y1: Int, x2: Int, y2: Int) {
                self.x1 = x1
                self.y1 = y1
                self.x2 = x2
                self.y2 = y2
            }
        }

        /// Extrémité de la ligne de rappel, en points du canevas officiel.
        public var markerPoint: (x: Double, y: Double) {
            (Double(left + line.x2), Double(top + line.y2))
        }

        /// Le même point, ramené à la photographie : 0 en haut à gauche, 1 en bas à droite.
        ///
        /// Les valeurs sortent parfois légèrement de `0...1` — le catalogue place quelques
        /// repères sur le pourtour de la silhouette — et ne sont donc pas bornées ici.
        public var normalizedMarker: (x: Double, y: Double) {
            let point = markerPoint
            return (
                (point.x - Canvas.artworkOrigin.x) / Canvas.artworkSide,
                (point.y - Canvas.artworkOrigin.y) / Canvas.artworkSide
            )
        }

        /// Le canevas dans lequel le configurateur officiel pose étiquettes et repères.
        ///
        /// La photographie y occupe un carré centré ; les étiquettes vivent dans les
        /// marges latérales. Les valeurs sont relevées sur la maquette cMouse puis
        /// vérifiées contre les photographies elles-mêmes : les repères des clics
        /// principal et secondaire tombent symétriquement de part et d'autre de l'axe de
        /// la souris, et ceux des boutons latéraux sur le bord gauche de la silhouette.
        public enum Canvas {
            public static let width: Double = 620
            public static let height: Double = 490
            public static let artworkSide: Double = 421

            public static var artworkOrigin: (x: Double, y: Double) {
                ((width - artworkSide) / 2, (height - artworkSide) / 2)
            }
        }
    }

    /// Rôle déduit de l'affectation d'usine publiée par le catalogue.
    ///
    /// Il vient des valeurs du profil, jamais de l'index : sur un modèle dont les index
    /// firmware sont discontinus, l'index ne dit rien du bouton physique.
    public var role: ButtonRole {
        switch defaultType {
        case 1:
            switch defaultParameter {
            case 0x0100: .primaryClick
            case 0x0200: .secondaryClick
            case 0x0400: .wheelClick
            case 0x0800: .back
            case 0x1000: .forward
            default: .unknown
            }
        case 2: .dpiCycle
        case 10: .dpiLock
        default: .unknown
        }
    }
}

/// Rôle physique d'une commande, tel que le catalogue le laisse déduire.
///
/// `unknown` est une réponse valable : l'interface affiche alors « Button N » plutôt
/// que d'inventer un rôle.
public enum ButtonRole: String, Sendable, Codable, CaseIterable {
    case primaryClick
    case secondaryClick
    case wheelClick
    case back
    case forward
    case dpiCycle
    case dpiLock
    case unknown
}

public struct DebounceProfile: Sendable, Codable {
    public var `default`: Int
    public var maximum: Int
    /// Au-delà de ce seuil, le configurateur officiel avertit d'une latence perceptible.
    public var warnAbove: Int
}

public struct PowerProfile: Sendable, Codable {
    /// Code firmware exprimé en unités de dix secondes malgré le nom historique JSON.
    public var defaultSleepMinutes: Int
    public var defaultPowerSaveBattery: Int
    public var supportsLongDistance: Bool
    public var defaultLongDistance: Bool

    public var defaultSleepTimeCode: Int { defaultSleepMinutes }
}

public struct FirmwareProfile: Sendable, Codable {
    public var deviceVersion: String?
    public var dongleVersion: String?
}
