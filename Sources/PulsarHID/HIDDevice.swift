import BibimbapLocalization
import Foundation

/// Identité d'une collection HID candidate, telle qu'énumérée par le système.
///
/// Une souris Pulsar expose plusieurs collections ; seule celle qui porte l'interface
/// vendor sert à la configuration. `matchesConfigurationInterface` applique le critère
/// retenu : un rapport d'entrée, un rapport de sortie, et l'identifiant de rapport attendu.
public struct HIDDeviceIdentifier: Hashable, Sendable, Codable {
    public var vendorID: UInt16
    public var productID: UInt16
    public var locationID: UInt32
    public var usagePage: UInt32
    public var usage: UInt32
    public var productName: String
    public var manufacturer: String
    public var transport: HIDTransportKind
    public var maxInputReportSize: Int
    public var maxOutputReportSize: Int

    public init(
        vendorID: UInt16,
        productID: UInt16,
        locationID: UInt32,
        usagePage: UInt32,
        usage: UInt32,
        productName: String,
        manufacturer: String,
        transport: HIDTransportKind,
        maxInputReportSize: Int,
        maxOutputReportSize: Int
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.usagePage = usagePage
        self.usage = usage
        self.productName = productName
        self.manufacturer = manufacturer
        self.transport = transport
        self.maxInputReportSize = maxInputReportSize
        self.maxOutputReportSize = maxOutputReportSize
    }

    /// Page d'usage vendor portant le canal de configuration Pulsar.
    public static let configurationUsagePage: UInt32 = 0xFF05

    /// Vrai si la collection peut porter le canal de configuration.
    ///
    /// Le report ID n'est pas lisible depuis les seules propriétés IOKit d'une collection,
    /// et la taille annoncée est le maximum de tous les rapports de la collection, pas
    /// celle du rapport de configuration. Une souris filaire annonce 17 octets, le dongle
    /// 8K en annonce 49 parce qu'il porte en plus un rapport de données rapide — les deux
    /// dialoguent pourtant en trames de 16 octets sur le report ID 8.
    ///
    /// Le critère est donc la page d'usage vendor et une capacité suffisante, jamais une
    /// égalité stricte.
    public func matchesConfigurationInterface(frameLength: Int) -> Bool {
        usagePage == Self.configurationUsagePage
            && maxInputReportSize >= frameLength + 1
            && maxOutputReportSize >= frameLength + 1
    }
}

public enum HIDTransportKind: String, Hashable, Sendable, Codable {
    case usb = "USB"
    case bluetooth = "Bluetooth"
    case other = "Other"

    public init(ioKitTransport: String?) {
        switch ioKitTransport?.lowercased() {
        case "usb": self = .usb
        case "bluetooth", "bluetoothlowenergy": self = .bluetooth
        default: self = .other
        }
    }
}

/// Un rapport d'entrée brut, tel que remonté par le périphérique.
public struct HIDInputReport: Hashable, Sendable {
    public var reportID: UInt8
    public var bytes: [UInt8]
    public var timestamp: Date

    public init(reportID: UInt8, bytes: [UInt8], timestamp: Date = Date()) {
        self.reportID = reportID
        self.bytes = bytes
        self.timestamp = timestamp
    }
}

public enum HIDTransportError: Error, Equatable, Sendable {
    case notOpen
    case deviceNotFound
    case openFailed(Int32)
    case writeFailed(Int32)
    case disconnected
    case reportTooLarge(Int)
}

extension HIDTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notOpen:
            L10n.string( "Aucun périphérique ouvert.")
        case .deviceNotFound:
            L10n.string( "Périphérique introuvable.")
        case .openFailed(let code):
            L10n.format("Device opening denied (code %d).", code)
        case .writeFailed(let code):
            L10n.format("HID report write failed (code %d).", code)
        case .disconnected:
            L10n.string( "Le périphérique s'est déconnecté.")
        case .reportTooLarge(let size):
            L10n.format("A %d-byte report is too long for this device.", size)
        }
    }
}

/// Couche de transport HID.
///
/// Le matériel réel (`IOKitHIDTransport`) et le simulateur (`SimulatedHIDTransport`)
/// implémentent strictement la même interface, afin que rien au-dessus n'ait à savoir
/// lequel des deux est branché.
public protocol HIDTransport: Sendable {
    /// Collections actuellement présentes sur la machine.
    func discover() async throws -> [HIDDeviceIdentifier]

    /// Ouvre une collection et démarre la remontée des rapports d'entrée.
    func open(_ identifier: HIDDeviceIdentifier) async throws

    /// Ferme la collection ouverte. Sans effet s'il n'y en a pas.
    func close() async

    /// Identité de la collection ouverte, `nil` si aucune.
    func currentDevice() async -> HIDDeviceIdentifier?

    /// Émet un rapport de sortie.
    func send(reportID: UInt8, payload: [UInt8]) async throws

    /// Flux des rapports d'entrée. Se termine à la fermeture ou à la déconnexion.
    func inputReports() async -> AsyncStream<HIDInputReport>

    /// Flux des évènements de branchement/débranchement, pour la découverte à chaud.
    func deviceEvents() async -> AsyncStream<HIDDeviceEvent>
}

public enum HIDDeviceEvent: Hashable, Sendable {
    case attached(HIDDeviceIdentifier)
    case detached(HIDDeviceIdentifier)
}
