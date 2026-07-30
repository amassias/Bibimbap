import BibimbapLocalization
import Foundation

/// Une macro enregistrée dans la souris.
///
/// Un emplacement par bouton : la macro affectée au bouton *n* vit à `Macro + 384 × n`.
/// Le nombre de répétitions n'est pas stocké avec la macro mais dans l'octet de poids
/// faible du paramètre du bouton, ce qui explique qu'il voyage séparément.
public struct PulsarMacro: Equatable, Sendable, Codable {
    /// Longueur maximale du nom, en octets UTF-8.
    public static let nameCapacity = 30
    /// Nombre maximal d'étapes accepté par le firmware.
    public static let stepCapacity = 70

    public var name: String
    public var steps: [Step]

    public init(name: String, steps: [Step]) {
        self.name = name
        self.steps = steps
    }

    public struct Step: Equatable, Sendable, Codable, Identifiable {
        public var id = UUID()
        /// Nature brute, sur quatre bits. Conservée telle quelle pour qu'une valeur
        /// inconnue traverse un aller-retour sans être perdue.
        public var kindCode: Int
        public var action: Action
        /// Valeur associée : code de touche, masque de bouton, ou déplacement empaqueté.
        public var value: Int
        /// Délai avant l'étape suivante, en millisecondes.
        public var delayMilliseconds: Int

        public var kind: Kind? { Kind(rawValue: kindCode) }

        public init(kind: Kind, action: Action, value: Int, delayMilliseconds: Int) {
            self.init(kindCode: kind.rawValue, action: action, value: value,
                      delayMilliseconds: delayMilliseconds)
        }

        public init(kindCode: Int, action: Action, value: Int, delayMilliseconds: Int) {
            self.kindCode = kindCode
            self.action = action
            self.value = value
            self.delayMilliseconds = delayMilliseconds
        }

        private enum CodingKeys: String, CodingKey {
            case kindCode, action, value, delayMilliseconds
        }

        /// Nature de l'étape, codée sur les quatre bits de poids faible.
        public enum Kind: Int, Sendable, Codable, CaseIterable {
            case modifier = 0
            case key = 1
            case media = 2
            case mouseButton = 4
            case movement = 5
            case wheel = 6
            case menuKey = 7

            /// Les étapes de souris portent leur propre timing et n'ont pas d'état.
            public var isPointerEvent: Bool { rawValue >= 4 && rawValue <= 6 }

            public var label: String {
                switch self {
                case .modifier: L10n.string( "Modificateur")
                case .key: L10n.string( "Touche")
                case .media: L10n.string( "Touche multimédia")
                case .mouseButton: L10n.string( "Bouton souris")
                case .movement: L10n.string( "Déplacement")
                case .wheel: L10n.string( "Molette")
                case .menuKey: L10n.string( "Touche menu")
                }
            }
        }

        /// État de l'étape, codé sur les deux bits de poids fort.
        ///
        /// L'encodage matériel est inversé par rapport à l'intuition : un appui s'écrit
        /// `2` et un relâchement `1`. Se tromper produit une macro qui relâche avant
        /// d'appuyer, sans qu'aucun checksum ne s'en aperçoive.
        public enum Action: Int, Sendable, Codable, CaseIterable {
            case press = 0
            case release = 1
            case none = 2

            var encoded: UInt8 {
                switch self {
                case .press: 2
                case .release: 1
                case .none: 0
                }
            }

            static func decode(_ raw: UInt8) -> Action {
                switch raw {
                case 2: .press
                case 1: .release
                default: .none
                }
            }

            public var label: String {
                switch self {
                case .press: L10n.string( "Appui")
                case .release: L10n.string( "Relâchement")
                case .none: L10n.string( "—")
                }
            }
        }
    }

    /// Masques de boutons utilisés par les étapes de type « bouton souris ».
    public enum MouseButtonMask: Int, Sendable, CaseIterable {
        case left = 1
        case right = 2
        case middle = 4
        case back = 8
        case forward = 16

        public var label: String {
            switch self {
            case .left: L10n.string( "Clic gauche")
            case .right: L10n.string( "Clic droit")
            case .middle: L10n.string( "Clic molette")
            case .back: L10n.string( "Précédent")
            case .forward: L10n.string( "Suivant")
            }
        }
    }
}

/// Encodage et décodage des blocs macro.
///
/// Disposition d'un bloc de 384 octets :
///
/// ```
/// [0]              longueur du nom, en octets UTF-8
/// [1..30]          nom
/// [31]             nombre d'étapes
/// [32 + 5n]        (action << 6) | nature
/// [32 + 5n + 1]    valeur, octet de poids faible
/// [32 + 5n + 2]    valeur, octet de poids fort
/// [32 + 5n + 3]    délai, octet de poids fort
/// [32 + 5n + 4]    délai, octet de poids faible
/// [32 + 5c]        checksum
/// ```
///
/// La valeur est petit-boutiste et le délai gros-boutiste, dans le même bloc.
/// Le checksum couvre le compteur d'étapes et les étapes, sans le nom.
public enum MacroCodec {
    public static let blockLength = 384
    public static let nameOffset = 1
    public static let stepCountOffset = 31
    public static let stepsOffset = 32
    public static let stepLength = 5

    public enum CodecError: Error, Equatable, Sendable {
        case nameTooLong(bytes: Int)
        case tooManySteps(Int)
        case malformedBlock
    }

    /// Étendue à lire pour récupérer le nom d'une macro : d'abord dix octets, puis le
    /// reste si le nom est plus long.
    public static func nameRange(slot: Int) -> Range<UInt16> {
        let start = FlashMap.macro(slot: slot)
        return start..<(start + UInt16(stepsOffset))
    }

    /// Étendue couvrant le compteur d'étapes, les étapes et leur checksum.
    public static func stepsRange(slot: Int, stepCount: Int) -> Range<UInt16> {
        let start = FlashMap.macro(slot: slot) + UInt16(stepCountOffset)
        return start..<(start + UInt16(stepLength * stepCount + 2))
    }

    // MARK: Décodage

    /// Relit la macro d'un emplacement, ou `nil` si le bloc est vide ou incohérent.
    ///
    /// Un bloc jamais écrit est rempli de `0xFF`, ce qui donne une longueur de nom et un
    /// nombre d'étapes hors bornes : on renvoie `nil` plutôt que d'inventer une macro.
    public static func decode(from image: FlashImage, slot: Int) -> PulsarMacro? {
        let base = FlashMap.macro(slot: slot)
        guard let nameLength = image[base], let stepCount = image[base + UInt16(stepCountOffset)],
              nameLength > 0, nameLength <= UInt8(PulsarMacro.nameCapacity),
              stepCount <= UInt8(PulsarMacro.stepCapacity)
        else {
            return nil
        }

        let nameBytes = image.slice(at: base + UInt16(nameOffset), count: Int(nameLength))
        guard let name = String(bytes: nameBytes, encoding: .utf8) else { return nil }

        var steps: [PulsarMacro.Step] = []
        for index in 0..<Int(stepCount) {
            let offset = base + UInt16(stepsOffset + stepLength * index)
            let raw = image.slice(at: offset, count: stepLength)
            guard raw.count == stepLength else { return nil }
            steps.append(PulsarMacro.Step(
                kindCode: Int(raw[0] & 0x0F),
                action: PulsarMacro.Step.Action.decode(raw[0] >> 6),
                value: Int(raw[2]) << 8 | Int(raw[1]),
                delayMilliseconds: Int(raw[3]) << 8 | Int(raw[4])
            ))
        }
        return PulsarMacro(name: name, steps: steps)
    }

    // MARK: Encodage

    /// Sérialise une macro en bloc complet, prêt à écrire.
    ///
    /// Les octets non utilisés valent `0xFF`, comme le fait le firmware, pour qu'une
    /// macro plus courte n'y laisse pas les restes de la précédente.
    public static func encode(_ macro: PulsarMacro) throws -> [UInt8] {
        let nameBytes = Array(macro.name.utf8)
        guard nameBytes.count <= PulsarMacro.nameCapacity else {
            throw CodecError.nameTooLong(bytes: nameBytes.count)
        }
        guard macro.steps.count <= PulsarMacro.stepCapacity else {
            throw CodecError.tooManySteps(macro.steps.count)
        }

        var block = [UInt8](repeating: 0xFF, count: stepsOffset + stepLength * macro.steps.count + 1)
        block[0] = UInt8(nameBytes.count)
        for (offset, byte) in nameBytes.enumerated() {
            block[nameOffset + offset] = byte
        }
        // Les octets du nom au-delà de sa longueur restent à 0xFF, comme en flash.
        block[stepCountOffset] = UInt8(macro.steps.count)

        for (index, step) in macro.steps.enumerated() {
            let offset = stepsOffset + stepLength * index
            block[offset] = (step.action.encoded << 6) | UInt8(step.kindCode & 0x0F)
            block[offset + 1] = UInt8(truncatingIfNeeded: step.value)
            block[offset + 2] = UInt8(truncatingIfNeeded: step.value >> 8)
            block[offset + 3] = UInt8(truncatingIfNeeded: step.delayMilliseconds >> 8)
            block[offset + 4] = UInt8(truncatingIfNeeded: step.delayMilliseconds)
        }

        // Le checksum couvre le compteur d'étapes et les étapes, pas le nom.
        let covered = block[stepCountOffset..<(block.count - 1)]
        block[block.count - 1] = PulsarFrame.blockChecksum(over: covered)
        return block
    }

    /// Décompose la valeur d'une étape de déplacement en offsets signés.
    ///
    /// Les deux axes tiennent dans un mot de 16 bits, chacun sur un octet en complément
    /// à deux borné à ±127 : `value = (y << 8) | x`.
    public static func movement(from value: Int) -> (x: Int, y: Int) {
        (x: Int(Int8(bitPattern: UInt8(truncatingIfNeeded: value))),
         y: Int(Int8(bitPattern: UInt8(truncatingIfNeeded: value >> 8))))
    }

    public static func movementValue(x: Int, y: Int) -> Int {
        let clampedX = UInt8(bitPattern: Int8(clamping: max(-127, min(127, x))))
        let clampedY = UInt8(bitPattern: Int8(clamping: max(-127, min(127, y))))
        return Int(clampedY) << 8 | Int(clampedX)
    }

    /// Vrai si le checksum du bloc concorde.
    public static func verify(_ block: [UInt8]) -> Bool {
        guard block.count > stepsOffset else { return false }
        let covered = block[stepCountOffset..<(block.count - 1)]
        return PulsarFrame.blockChecksum(over: covered) == block[block.count - 1]
    }
}

extension PulsarSession {
    /// Lit la macro d'un emplacement.
    ///
    /// Deux lectures enchaînées : l'en-tête donne la longueur du nom et le nombre
    /// d'étapes, ce qui détermine combien lire ensuite. Relire les 384 octets serait
    /// trente-neuf trames au lieu de six.
    public func readMacro(slot: Int) async throws -> PulsarMacro? {
        let base = FlashMap.macro(slot: slot)
        var image = try await readFlash(base..<(base + UInt16(MacroCodec.stepsOffset + 2)))

        guard let stepCount = image[base + UInt16(MacroCodec.stepCountOffset)],
              stepCount > 0, stepCount <= UInt8(PulsarMacro.stepCapacity)
        else {
            return MacroCodec.decode(from: image, slot: slot)
        }

        image = try await readFlash(
            MacroCodec.stepsRange(slot: slot, stepCount: Int(stepCount)),
            into: image
        )
        return MacroCodec.decode(from: image, slot: slot)
    }

    /// Écrit une macro puis relit le bloc pour confirmer.
    public func writeMacro(_ macro: PulsarMacro, slot: Int) async throws {
        let block = try MacroCodec.encode(macro)
        let base = FlashMap.macro(slot: slot)
        try await writeFlash(block, at: base)

        let image = try await readFlash(base..<(base + UInt16(block.count)))
        guard image.slice(at: base, count: block.count) == block else {
            throw SessionError.readbackMismatch(address: base)
        }
    }
}
