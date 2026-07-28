import Foundation

/// Codes de commande de l'interface vendor.
public enum PulsarCommand: UInt8, Sendable, CaseIterable, Codable {
    case encryptionData = 1
    case pcDriverStatus = 2
    case deviceOnline = 3
    case batteryLevel = 4
    case dongleEnterPair = 5
    case getPairState = 6
    case writeFlashData = 7
    case readFlashData = 8
    case clearSetting = 9
    case statusChanged = 10
    case setDeviceVidPid = 11
    case setDeviceDescriptorString = 12
    case enterUsbUpdateMode = 13
    case getCurrentConfig = 14
    case setCurrentConfig = 15
    case readCIDMID = 16
    case enterMTKMode = 17
    case readVersionID = 18
    case set4KDongleRGB = 20
    case get4KDongleRGBValue = 21
    case setLongRangeMode = 22
    case getLongRangeMode = 23
    case setPulsarDongleLightParam = 24
    case getPulsarDongleLightParam = 25
    case getDongleVersion = 29
    case setPulsarDongleKeyFunction = 35
    case getPulsarDongleKeyFunction = 36
    case setPulsarDongleDPILightParam = 37
    case getPulsarDongleDPILightParam = 38
    case setPulsarDongleOButtonCurrentMode = 39
    case getPulsarDongleOButtonCurrentMode = 40
    case setPulsarDongleOButtonFunction = 41
    case getPulsarDongleOButtonFunction = 42
    case getRSSIValue = 43
    case musicColorful = 176
    case musicSingleColor = 177
    case writeKBCIdMID = 240
    case readKBCIdMID = 241

    /// Nombre d'octets comparés entre requête et réponse pour valider un acquittement.
    ///
    /// Les lectures flash renvoient l'adresse et la longueur, qu'il faut vérifier ;
    /// les autres commandes ne garantissent que le code et le statut.
    public var acknowledgementPrefixLength: Int {
        self == .readFlashData ? 5 : 3
    }

    /// Commandes réservées à la phase 2 et refusées par `PulsarSession`.
    public var isFirmwareOperation: Bool {
        switch self {
        case .enterUsbUpdateMode, .enterMTKMode, .setDeviceVidPid, .setDeviceDescriptorString,
             .writeKBCIdMID:
            true
        default:
            false
        }
    }
}

/// Mode de connexion déduit du handshake, avec le polling maximal qu'il autorise.
public enum PulsarConnectionType: UInt8, Sendable, CaseIterable {
    case wireless1k = 0
    case wireless4k = 1
    case wired1k = 2
    case wired8k = 3
    case wireless2k = 4
    case wireless8k = 5

    public var isWired: Bool {
        self == .wired1k || self == .wired8k
    }

    public var maximumReportRate: Int {
        switch self {
        case .wireless1k, .wired1k: 1000
        case .wireless2k: 2000
        case .wireless4k: 4000
        case .wired8k, .wireless8k: 8000
        }
    }
}

/// État d'appairage d'un récepteur.
public enum PulsarPairState: UInt8, Sendable {
    case pairing = 1
    case failed = 2
    case succeeded = 3
}

/// Fonctions assignables à un bouton.
public enum PulsarKeyFunction: UInt8, Sendable, CaseIterable, Codable {
    case disabled = 0
    case mouseButton = 1
    case dpiSwitch = 2
    case horizontalScroll = 3
    case rapidFire = 4
    case keyboardShortcut = 5
    case macro = 6
    case reportRateSwitch = 7
    case lighting = 8
    case profileSwitch = 9
    case dpiLock = 10
    case verticalScroll = 11
}

/// Groupes de réglages à relire après une notification `statusChanged`.
public struct PulsarChangeNotification: Hashable, Sendable {
    public var battery: Bool
    public var generalSettings: Bool
    public var reconnected: Bool
    public var lighting: Bool
    public var profile: Bool
    public var version: Bool
    public var dpi: Bool
    public var buttons: Bool
    public var dpiEffect: Bool
    public var dongle: Bool
    public var sleep: Bool
    public var fan: Bool

    public init(primary: UInt8, secondary: UInt8) {
        battery = primary & 0x01 != 0
        generalSettings = primary & 0x02 != 0
        reconnected = primary & 0x04 != 0
        lighting = primary & 0x08 != 0
        profile = primary & 0x20 != 0
        version = primary & 0x40 != 0
        dpi = secondary & 0x01 != 0
        buttons = secondary & 0x02 != 0
        dpiEffect = secondary & 0x04 != 0
        dongle = secondary & 0x08 != 0
        sleep = secondary & 0x10 != 0
        fan = secondary & 0x20 != 0
    }

    public var isEmpty: Bool {
        !(battery || generalSettings || reconnected || lighting || profile || version
          || dpi || buttons || dpiEffect || dongle || sleep || fan)
    }
}
