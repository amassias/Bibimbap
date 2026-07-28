import Foundation

/// Trame de 16 octets échangée sur l'interface vendor, dans les deux sens.
///
/// ```
///  0    1       2      3      4      5 .. 14     15
/// +----+-------+------+------+------+-----------+------+
/// |cmd |status |addrHi|addrLo| len  |  data[10] | csum |
/// +----+-------+------+------+------+-----------+------+
/// ```
///
/// Voir `docs/protocol.md` pour l'origine de ce format.
public struct PulsarFrame: Hashable, Sendable {
    /// Identifiant du rapport HID portant la configuration.
    public static let reportID: UInt8 = 8
    /// Longueur de la trame, report ID exclu.
    public static let length = 16
    /// Nombre d'octets utiles par trame.
    public static let payloadCapacity = 10
    /// Somme de contrôle attendue sur le report ID et la trame complète.
    public static let checksumTarget: UInt8 = 0x55

    public var command: PulsarCommand
    /// `0` réponse valide, `1` commande non supportée par ce modèle.
    public var status: UInt8
    public var address: UInt16
    public var payload: [UInt8]
    /// Valeur explicite du champ longueur, quand elle ne décrit pas la charge utile.
    ///
    /// Une lecture flash n'envoie aucune donnée : elle porte dans ce champ le nombre
    /// d'octets demandés. Confondre les deux fait ne lire qu'un octet par trame.
    public var declaredLength: UInt8?

    public init(
        command: PulsarCommand,
        status: UInt8 = 0,
        address: UInt16 = 0,
        payload: [UInt8] = [],
        declaredLength: UInt8? = nil
    ) {
        precondition(payload.count <= Self.payloadCapacity, "charge utile limitée à 10 octets")
        self.command = command
        self.status = status
        self.address = address
        self.payload = payload
        self.declaredLength = declaredLength
    }

    /// Valeur effectivement écrite dans le champ longueur.
    public var effectiveLength: UInt8 { declaredLength ?? UInt8(payload.count) }

    /// Vrai si le périphérique a signalé que la commande n'existe pas sur ce modèle.
    ///
    /// C'est le seul mécanisme de détection de capacité offert par le protocole :
    /// on émet la commande et on lit le statut.
    public var isUnsupported: Bool { status == 1 }

    /// Octet de la charge utile à l'index absolu de la trame, ou `0` hors limites.
    ///
    /// Les décodeurs raisonnent en index de trame (`data[5]`, `data[9]`…) comme le
    /// fait la documentation du protocole, d'où cet accès.
    public subscript(byte index: Int) -> UInt8 {
        let offset = index - 5
        guard offset >= 0, offset < payload.count else { return 0 }
        return payload[offset]
    }

    // MARK: Encodage

    /// Sérialise la trame, checksum compris. Le report ID n'est pas inclus dans le résultat :
    /// `IOHIDDeviceSetReport` le prend en paramètre séparé.
    public func encoded() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.length)
        bytes[0] = command.rawValue
        bytes[1] = status
        bytes[2] = UInt8(truncatingIfNeeded: address >> 8)
        bytes[3] = UInt8(truncatingIfNeeded: address)
        bytes[4] = effectiveLength
        for (offset, byte) in payload.enumerated() {
            bytes[5 + offset] = byte
        }
        bytes[Self.length - 1] = Self.checksum(over: bytes.dropLast())
        return bytes
    }

    /// Checksum de trame : la somme du report ID et des 16 octets vaut `0x55`.
    public static func checksum(over bytes: some Sequence<UInt8>) -> UInt8 {
        let sum = bytes.reduce(UInt8(0)) { $0 &+ $1 }
        return checksumTarget &- sum &- reportID
    }

    /// Checksum interne d'un bloc de réglages écrit en flash.
    ///
    /// Même invariant, sans report ID : le dernier octet complète la somme à `0x55`.
    public static func blockChecksum(over bytes: some Sequence<UInt8>) -> UInt8 {
        checksumTarget &- bytes.reduce(UInt8(0)) { $0 &+ $1 }
    }

    // MARK: Décodage

    public enum DecodingError: Error, Equatable, Sendable {
        case wrongLength(Int)
        case badChecksum(expected: UInt8, found: UInt8)
        case unknownCommand(UInt8)
        case payloadLengthOutOfRange(UInt8)
    }

    public init(decoding bytes: [UInt8]) throws {
        guard bytes.count == Self.length else {
            throw DecodingError.wrongLength(bytes.count)
        }
        let expected = Self.checksum(over: bytes.dropLast())
        guard expected == bytes[Self.length - 1] else {
            throw DecodingError.badChecksum(expected: expected, found: bytes[Self.length - 1])
        }
        guard let command = PulsarCommand(rawValue: bytes[0]) else {
            throw DecodingError.unknownCommand(bytes[0])
        }
        let declared = bytes[4]
        guard declared <= UInt8(Self.payloadCapacity) else {
            throw DecodingError.payloadLengthOutOfRange(declared)
        }
        self.command = command
        self.status = bytes[1]
        self.address = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        self.declaredLength = declared
        // Les réponses non-flash ne renseignent pas toujours `len` ; on conserve alors
        // la totalité de la zone de données pour que les décodeurs y accèdent.
        let count = declared == 0 ? Self.payloadCapacity : Int(declared)
        self.payload = Array(bytes[5..<(5 + count)])
    }
}
