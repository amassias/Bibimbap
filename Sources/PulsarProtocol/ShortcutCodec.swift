import Foundation

/// Une combinaison de touches/média affectée à un bouton.
public struct PulsarShortcut: Equatable, Sendable, Codable {
    public var keys: [Key]

    public init(keys: [Key]) {
        self.keys = keys
    }

    public struct Key: Equatable, Sendable, Codable, Identifiable {
        public var id = UUID()
        public var kind: PulsarMacro.Step.Kind
        public var value: Int

        public init(kind: PulsarMacro.Step.Kind, value: Int) {
            self.kind = kind
            self.value = value
        }

        private enum CodingKeys: String, CodingKey {
            case kind, value
        }

        public static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.kind == rhs.kind && lhs.value == rhs.value
        }
    }

    public var summary: String {
        guard !keys.isEmpty else { return "Aucune touche" }
        return keys.map { PulsarInputCatalog.label(for: $0) }.joined(separator: " + ")
    }
}

/// Élément lisible proposé par les sélecteurs de touches et de médias.
public struct PulsarInputOption: Equatable, Hashable, Sendable, Identifiable {
    public let kind: PulsarMacro.Step.Kind
    public let value: Int
    public let label: String

    public var id: String { "\(kind.rawValue):\(value)" }

    public init(kind: PulsarMacro.Step.Kind, value: Int, label: String) {
        self.kind = kind
        self.value = value
        self.label = label
    }
}

/// Catalogue fermé des usages HID exposés dans l'interface.
///
/// Les codes restent dans ce catalogue et dans le codec ; l'utilisateur ne voit que
/// des libellés. Un usage relu mais absent du catalogue est présenté comme indisponible
/// et ne peut pas être remplacé silencieusement par une autre touche.
public enum PulsarInputCatalog {
    public static let modifierOptions: [PulsarInputOption] = [
        option(.modifier, 1, "Control gauche"),
        option(.modifier, 2, "Majuscule gauche"),
        option(.modifier, 4, "Option gauche"),
        option(.modifier, 8, "Commande gauche"),
        option(.modifier, 16, "Control droit"),
        option(.modifier, 32, "Majuscule droite"),
        option(.modifier, 64, "Option droite"),
        option(.modifier, 128, "Commande droite"),
    ]

    public static let keyboardOptions: [PulsarInputOption] = modifierOptions
        + keyOptions
        + [option(.menuKey, 101, "Menu contextuel")]

    public static let mediaOptions: [PulsarInputOption] = [
        option(.media, 0x00B5, "Piste suivante"),
        option(.media, 0x00B6, "Piste précédente"),
        option(.media, 0x00B7, "Arrêt"),
        option(.media, 0x00CD, "Lecture / pause"),
        option(.media, 0x00E2, "Silence"),
        option(.media, 0x00E9, "Volume +"),
        option(.media, 0x00EA, "Volume −"),
        option(.media, 0x0183, "Lecteur multimédia"),
        option(.media, 0x0192, "Calculatrice"),
    ]

    public static let allOptions = keyboardOptions + mediaOptions

    public static func option(for key: PulsarShortcut.Key) -> PulsarInputOption? {
        allOptions.first { $0.kind == key.kind && $0.value == key.value }
    }

    public static func label(for key: PulsarShortcut.Key) -> String {
        option(for: key)?.label ?? "Touche indisponible"
    }

    private static let keyOptions: [PulsarInputOption] = [
        option(.key, 40, "Entrée"),
        option(.key, 41, "Échap"),
        option(.key, 42, "Retour arrière"),
        option(.key, 43, "Tabulation"),
        option(.key, 44, "Espace"),
        option(.key, 57, "Verrouillage majuscule"),
        option(.key, 70, "Impression écran"),
        option(.key, 71, "Arrêt défilement"),
        option(.key, 72, "Pause"),
        option(.key, 73, "Insertion"),
        option(.key, 74, "Début"),
        option(.key, 75, "Page précédente"),
        option(.key, 76, "Suppr"),
        option(.key, 77, "Fin"),
        option(.key, 78, "Page suivante"),
        option(.key, 79, "Flèche droite"),
        option(.key, 80, "Flèche gauche"),
        option(.key, 81, "Flèche bas"),
        option(.key, 82, "Flèche haut"),
        option(.key, 83, "Verrouillage numérique"),
        option(.key, 45, "Tiret"),
        option(.key, 46, "Égal"),
        option(.key, 47, "Crochet ouvrant"),
        option(.key, 48, "Crochet fermant"),
        option(.key, 49, "Antislash"),
        option(.key, 51, "Point-virgule"),
        option(.key, 52, "Apostrophe"),
        option(.key, 53, "Accent grave"),
        option(.key, 54, "Virgule"),
        option(.key, 55, "Point"),
        option(.key, 56, "Barre oblique"),
        option(.key, 87, "F13"),
        option(.key, 88, "F14"),
        option(.key, 89, "F15"),
        option(.key, 90, "F16"),
        option(.key, 91, "F17"),
        option(.key, 92, "F18"),
        option(.key, 93, "F19"),
        option(.key, 94, "F20"),
    ] + letterOptions + digitOptions + functionOptions

    private static let letterOptions: [PulsarInputOption] = Array(0..<26).map { offset in
        option(.key, 4 + offset, String(UnicodeScalar(65 + offset)!))
    }

    private static let digitOptions: [PulsarInputOption] = [
        option(.key, 30, "1"), option(.key, 31, "2"), option(.key, 32, "3"),
        option(.key, 33, "4"), option(.key, 34, "5"), option(.key, 35, "6"),
        option(.key, 36, "7"), option(.key, 37, "8"), option(.key, 38, "9"),
        option(.key, 39, "0"),
    ]

    private static let functionOptions: [PulsarInputOption] = Array(1...12).map { number in
        option(.key, 57 + number, "F\(number)")
    }

    private static func option(
        _ kind: PulsarMacro.Step.Kind,
        _ value: Int,
        _ label: String
    ) -> PulsarInputOption {
        PulsarInputOption(kind: kind, value: value, label: label)
    }
}

/// Codec du bloc de 32 octets réservé à un raccourci.
public enum ShortcutCodec {
    public static let blockLength = FlashMap.shortcutStride
    public static let maxKeys = 5
    private static let entryLength = 3

    public enum CodecError: Error, Equatable, Sendable {
        case tooManyKeys(Int)
        case invalidKind(Int)
        case invalidValue(Int)
        case malformedBlock
        case checksumMismatch
    }

    public static func encode(_ shortcut: PulsarShortcut) throws -> [UInt8] {
        guard shortcut.keys.count <= maxKeys else {
            throw CodecError.tooManyKeys(shortcut.keys.count)
        }
        guard shortcut.keys.allSatisfy({ supportedKinds.contains($0.kind) }) else {
            throw CodecError.invalidKind(
                shortcut.keys.first(where: { !supportedKinds.contains($0.kind) })?.kind.rawValue ?? -1
            )
        }
        guard shortcut.keys.allSatisfy({ (0...0xFFFF).contains($0.value) }) else {
            throw CodecError.invalidValue(
                shortcut.keys.first(where: { !(0...0xFFFF).contains($0.value) })?.value ?? -1
            )
        }

        // Une combinaison vide représente un bloc jamais affecté et conserve la valeur
        // d'effacement de la flash dans toute la zone.
        guard !shortcut.keys.isEmpty else {
            return [UInt8](repeating: FlashImage.unwritten, count: blockLength)
        }

        let count = shortcut.keys.count
        var block = [UInt8](repeating: FlashImage.unwritten, count: blockLength)
        block[0] = UInt8(count * 2)

        for (index, key) in shortcut.keys.enumerated() {
            write(key, flags: 0x80, at: 1 + entryLength * index, into: &block)
            // Le firmware relâche les touches dans l'ordre inverse de l'appui.
            let releaseIndex = count - 1 - index
            write(key, flags: 0x40, at: 1 + entryLength * (count + releaseIndex), into: &block)
        }

        let checksumIndex = 1 + entryLength * count * 2
        block[checksumIndex] = PulsarFrame.blockChecksum(over: block[0..<checksumIndex])
        return block
    }

    public static func decode(_ block: [UInt8]) -> PulsarShortcut? {
        guard block.count >= blockLength else { return nil }
        if block.prefix(blockLength).allSatisfy({ $0 == FlashImage.unwritten }) {
            return PulsarShortcut(keys: [])
        }

        let encodedCount = Int(block[0])
        guard encodedCount == 0 || encodedCount.isMultiple(of: 2),
              encodedCount <= maxKeys * 2
        else { return nil }
        if encodedCount == 0 {
            return block[1] == PulsarFrame.blockChecksum(over: [0])
                ? PulsarShortcut(keys: [])
                : nil
        }

        let count = encodedCount / 2
        let checksumIndex = 1 + entryLength * count * 2
        guard checksumIndex < blockLength,
              PulsarFrame.blockChecksum(over: block[0..<checksumIndex]) == block[checksumIndex]
        else { return nil }

        var keys: [PulsarShortcut.Key] = []
        for index in 0..<count {
            let pressOffset = 1 + entryLength * index
            let releaseOffset = 1 + entryLength * (count + count - 1 - index)
            guard let press = read(block, at: pressOffset, flags: 0x80),
                  let release = read(block, at: releaseOffset, flags: 0x40),
                  press == release,
                  supportedKinds.contains(press.kind)
            else { return nil }
            keys.append(press)
        }
        return PulsarShortcut(keys: keys)
    }

    public static func decode(from image: FlashImage, slot: Int) -> PulsarShortcut? {
        decode(image.slice(at: FlashMap.shortcut(slot: slot), count: blockLength))
    }

    private static let supportedKinds: Set<PulsarMacro.Step.Kind> = [
        .modifier, .key, .media, .menuKey,
    ]

    private static func write(
        _ key: PulsarShortcut.Key,
        flags: UInt8,
        at offset: Int,
        into block: inout [UInt8]
    ) {
        block[offset] = flags | UInt8(key.kind.rawValue)
        block[offset + 1] = UInt8(truncatingIfNeeded: key.value)
        block[offset + 2] = UInt8(truncatingIfNeeded: key.value >> 8)
    }

    private static func read(
        _ block: [UInt8],
        at offset: Int,
        flags: UInt8
    ) -> PulsarShortcut.Key? {
        guard offset + 2 < block.count,
              block[offset] & 0xF0 == flags,
              let kind = PulsarMacro.Step.Kind(rawValue: Int(block[offset] & 0x0F))
        else { return nil }
        let value = Int(block[offset + 1]) | Int(block[offset + 2]) << 8
        return PulsarShortcut.Key(kind: kind, value: value)
    }
}

extension PulsarSession {
    /// Lit un bloc de raccourci complet.
    public func readShortcut(slot: Int) async throws -> PulsarShortcut? {
        let base = FlashMap.shortcut(slot: slot)
        let image = try await readFlash(base..<(base + UInt16(ShortcutCodec.blockLength)))
        return ShortcutCodec.decode(image.slice(at: base, count: ShortcutCodec.blockLength))
    }

    /// Écrit puis relit les 32 octets du raccourci.
    public func writeShortcut(_ shortcut: PulsarShortcut, slot: Int) async throws {
        let block = try ShortcutCodec.encode(shortcut)
        let base = FlashMap.shortcut(slot: slot)
        try await writeFlash(block, at: base)
        let image = try await readFlash(base..<(base + UInt16(block.count)))
        guard image.slice(at: base, count: block.count) == block else {
            throw SessionError.readbackMismatch(address: base)
        }
    }
}
