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
    public var vendorIDs: [UInt16]
    public var mouseProductIDs: ProductIDs
    public var sensors: [String: SensorRanges]
    public var families: [DeviceFamily]

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

public struct ButtonProfile: Sendable, Codable, Identifiable {
    public var index: Int
    public var position: Position
    public var defaultType: Int
    public var defaultParameter: Int

    public var id: Int { index }

    public struct Position: Sendable, Codable {
        public var x: Int
        public var y: Int
    }
}

public struct DebounceProfile: Sendable, Codable {
    public var `default`: Int
    public var maximum: Int
    /// Au-delà de ce seuil, le configurateur officiel avertit d'une latence perceptible.
    public var warnAbove: Int
}

public struct PowerProfile: Sendable, Codable {
    public var defaultSleepMinutes: Int
    public var defaultPowerSaveBattery: Int
    public var supportsLongDistance: Bool
    public var defaultLongDistance: Bool
}

public struct FirmwareProfile: Sendable, Codable {
    public var deviceVersion: String?
    public var dongleVersion: String?
}
