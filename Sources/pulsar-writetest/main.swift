import Foundation
import PulsarCatalog
import PulsarHID
import PulsarProtocol

/// Essais d'écriture minimaux et réversibles sur matériel réel.
///
/// Chaque essai lit la valeur d'origine, écrit une valeur d'essai, relit
/// indépendamment, puis restaure et vérifie la restauration. Rien n'est laissé modifié
/// en sortie normale.
///
/// La restauration réécrit les octets d'origine **tels qu'ils ont été lus**, jamais une
/// valeur recalculée : si l'encodeur avait un défaut, le recalcul le reproduirait.
///
///     swift run pulsar-writetest              # les trois essais
///     swift run pulsar-writetest scalar       # réglage scalaire, 2 octets
///     swift run pulsar-writetest dpi          # bloc DPI, 4 octets checksummés
///     swift run pulsar-writetest macro        # bloc macro, écriture multi-trames

setvbuf(stdout, nil, _IOLBF, 0)

let requested = Set(CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") })

/// Essais lancés par défaut. `polling` en est exclu volontairement : changer la cadence
/// de rapport peut faire renégocier la liaison sans fil, et une coupure à cet instant
/// laisserait la valeur d'essai en place sans possibilité de restaurer. Il faut le
/// demander explicitement, de préférence en USB.
let defaultTests: Set<String> = ["scalar", "dpi", "macro", "button"]
func shouldRun(_ name: String) -> Bool {
    requested.isEmpty ? defaultTests.contains(name) : requested.contains(name)
}

// MARK: - Connexion

let catalog = DeviceCatalog.embedded
let transport = IOKitHIDTransport(vendorIDs: Set(catalog.vendorIDs))

guard let target = try await transport.discover().first(where: {
    $0.matchesConfigurationInterface(frameLength: PulsarFrame.length)
}) else {
    print("Aucune interface de configuration Pulsar trouvée.")
    exit(1)
}

print("Périphérique : \(target.productName) (\(target.transport.rawValue))")
try await transport.open(target)

let session = PulsarSession(transport: transport)
await session.start()

let identity = try await session.identify()
guard let family = catalog.family(cid: identity.cid, mid: identity.mid) else {
    print("Modèle absent du catalogue — essai annulé.")
    exit(1)
}
print("CID \(identity.cid) · MID \(identity.mid) · capteur \(family.sensor.type) · \(identity.connectionType)")

guard try await session.waitUntilOnline() else {
    print("\nLa souris ne répond pas derrière son récepteur.")
    print("Réveillez-la — un clic ou un mouvement suffit — puis relancez.")
    exit(1)
}
print("Souris en ligne.")

// MARK: - Utilitaires

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

var failures: [String] = []
var uncertain: [String] = []

/// Empreinte de toute la zone de réglages, prise avant et après les essais.
///
/// Elle répond à une question que la vérification par zone ne peut pas trancher : est-ce
/// que quelque chose a bougé **ailleurs** que là où l'on écrivait ? Sans elle, un défaut
/// d'adressage ou un effet de bord du firmware passerait inaperçu.
let regionBefore = try await session.readFlash(FlashMap.coreRegion)
    .slice(at: 0, count: Int(FlashMap.coreRegion.upperBound))

/// Déroule un essai complet sur une zone de flash.
@MainActor
func runTest(
    name: String,
    address: UInt16,
    length: Int,
    describe: ([UInt8]) -> String,
    makeTestBlock: ([UInt8]) -> [UInt8]?
) async {
    print("\n── \(name) ──")
    print("Adresse 0x\(String(format: "%04X", address)), \(length) octets")

    do {
        let originalImage = try await session.readFlash(address..<(address + UInt16(length)))
        let original = originalImage.slice(at: address, count: length)
        print("1. Origine   : \(hex(original))")
        print("             \(describe(original))")

        guard let testBlock = makeTestBlock(original), testBlock != original else {
            print("   Pas de valeur d'essai exploitable — essai ignoré.")
            return
        }

        try await session.hold(true)
        try await session.writeFlash(testBlock, at: address)

        let afterImage = try await session.readFlash(address..<(address + UInt16(length)))
        let after = afterImage.slice(at: address, count: length)
        print("2. Écrit     : \(hex(testBlock))")
        print("3. Relu      : \(hex(after))")
        print("             \(describe(after))")

        if after == testBlock {
            print("   Concordance ✓")
        } else {
            print("   DIVERGENCE ✗")
            failures.append(name)
        }

        // Restauration tentée même si l'écriture a divergé.
        try await session.writeFlash(original, at: address)
        let restoredImage = try await session.readFlash(address..<(address + UInt16(length)))
        let restored = restoredImage.slice(at: address, count: length)
        if restored == original {
            print("4. Restauré  : \(hex(restored))   ✓")
        } else {
            print("4. Restauré  : \(hex(restored))   ✗ attendu \(hex(original))")
            uncertain.append(name)
        }
        try? await session.hold(false)
    } catch {
        print("   Échec : \(error)")
        failures.append(name)
        uncertain.append(name)
        try? await session.hold(false)
    }
}

// MARK: - Essai 1 : réglage scalaire

if shouldRun("scalar") {
    await runTest(
        name: "Réglage scalaire — temps de rebond",
        address: FlashMap.debounceTime,
        length: 2,
        describe: { bytes in
            let sum = bytes.reduce(UInt8(0)) { $0 &+ $1 }
            return "\(bytes[0]) ms · somme 0x\(String(format: "%02X", sum))"
        },
        makeTestBlock: { original in
            let value: UInt8 = original[0] == 5 ? 4 : 5
            return ScalarSetting(address: FlashMap.debounceTime, value: value).encoded
        }
    )
}

// MARK: - Essai 2 : bloc composé

if shouldRun("dpi"), let codec = DPICodec(family: family, catalog: catalog) {
    // Le dernier palier, pour ne pas toucher celui qui est actif sous la main.
    let stage = max(family.dpi.stages.count - 1, 0)
    await runTest(
        name: "Bloc composé — palier DPI \(stage + 1)",
        address: FlashMap.dpiValue(stage: stage, extended: codec.usesExtendedBlock),
        length: codec.usesExtendedBlock ? FlashMap.extendedDPIStageStride : FlashMap.dpiStageStride,
        describe: { bytes in
            let sum = bytes.reduce(UInt8(0)) { $0 &+ $1 }
            guard let decoded = try? codec.decodeStage(bytes) else {
                return "indécodable · somme 0x\(String(format: "%02X", sum))"
            }
            return "\(decoded.x) × \(decoded.y) DPI · somme 0x\(String(format: "%02X", sum))"
        },
        makeTestBlock: { original in
            guard let current = try? codec.decodeStage(original) else { return nil }
            let candidate = current.x == 16_000 ? 12_800 : 16_000
            return try? codec.encodeStage(x: candidate, y: candidate)
        }
    )
}

// MARK: - Essai 3 : écriture multi-trames

if shouldRun("macro") {
    // Un emplacement au-delà des index firmware du modèle : aucun bouton ne peut le
    // référencer. Compter les boutons ne suffirait pas, les index pouvant être discontinus.
    let slot = (family.buttons.map(\.index).max() ?? -1) + 1
    let macro = PulsarMacro(name: "Essai Bibimbap", steps: [
        .init(kind: .key, action: .press, value: 4, delayMilliseconds: 15),
        .init(kind: .key, action: .release, value: 4, delayMilliseconds: 15),
        .init(kind: .mouseButton, action: .press, value: 1, delayMilliseconds: 0),
        .init(kind: .mouseButton, action: .release, value: 1, delayMilliseconds: 0),
    ])

    if let block = try? MacroCodec.encode(macro) {
        // 53 octets, soit six trames : c'est le découpage qui est éprouvé ici.
        await runTest(
            name: "Écriture multi-trames — bloc macro, emplacement \(slot)",
            address: FlashMap.macro(slot: slot),
            length: block.count,
            describe: { bytes in
                var image = FlashImage()
                image.write(bytes, at: FlashMap.macro(slot: slot))
                guard let decoded = MacroCodec.decode(from: image, slot: slot) else {
                    return "aucune macro lisible (\(bytes.count) octets)"
                }
                return "« \(decoded.name) » · \(decoded.steps.count) étapes · "
                    + "checksum \(MacroCodec.verify(bytes) ? "valide" : "invalide")"
            },
            makeTestBlock: { _ in block }
        )
    }
}

// MARK: - Essai 4 : sémantique d'une fonction de bouton

if shouldRun("button"), let target = family.orderedButtons.last {
    // La dernière commande de la carte : jamais le clic principal ni le secondaire, dont
    // la perte pendant l'essai rendrait la machine pénible à récupérer.
    let last = target.index
    func describeFunction(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 4 else { return "bloc trop court" }
        let function = PulsarKeyFunction(rawValue: bytes[0]).map(String.init(describing:)) ?? "inconnue (\(bytes[0]))"
        let parameter = Int(bytes[1]) << 8 | Int(bytes[2])
        let sum = bytes.reduce(UInt8(0)) { $0 &+ $1 }
        return "\(function) · paramètre 0x\(String(format: "%04X", parameter))"
            + " · somme 0x\(String(format: "%02X", sum))"
    }

    await runTest(
        name: "Sémantique — fonction du bouton \(target.order + 1) (index firmware \(last))",
        address: FlashMap.keyFunction(button: last),
        length: FlashMap.keyFunctionStride,
        describe: describeFunction,
        makeTestBlock: { original in
            // « Désactivé » est la fonction la moins ambiguë à vérifier : si le firmware
            // la refuse, la relecture rendra autre chose que des zéros.
            let target: PulsarKeyFunction = original.first == PulsarKeyFunction.disabled.rawValue
                ? .reportRateSwitch
                : .disabled
            let head: [UInt8] = [target.rawValue, 0, 0]
            return head + [PulsarFrame.blockChecksum(over: head)]
        }
    )
}

// MARK: - Essai 5 : polling au-delà de 1 kHz (sur demande)

if shouldRun("polling") {
    let ceiling = min(family.maximumReportRate, identity.connectionType.maximumReportRate)
    let candidates = ReportRateCodec.available(upTo: ceiling).filter { $0 > 1000 }

    if candidates.isEmpty {
        print("\n── Polling ──")
        print("Cette connexion plafonne à \(ceiling) Hz : la branche haute du codec n'est")
        print("pas atteignable ici. Rebranchez en USB sur un modèle 8 kHz filaire.")
    } else {
        let candidate = candidates.first!
        await runTest(
            name: "Branche haute du codec de polling — \(candidate) Hz",
            address: FlashMap.reportRate,
            length: 2,
            describe: { bytes in
                let hertz = ReportRateCodec.hertz(from: bytes[0]).map { "\($0) Hz" } ?? "code inconnu"
                let sum = bytes.reduce(UInt8(0)) { $0 &+ $1 }
                return "\(hertz) · code \(bytes[0]) · somme 0x\(String(format: "%02X", sum))"
            },
            makeTestBlock: { _ in
                guard let code = ReportRateCodec.code(from: candidate) else { return nil }
                return ScalarSetting(address: FlashMap.reportRate, value: code).encoded
            }
        )
    }
}

// MARK: - Bilan

print("\n── Zone de réglages, avant / après ──")
let regionAfter = try await session.readFlash(FlashMap.coreRegion)
    .slice(at: 0, count: Int(FlashMap.coreRegion.upperBound))

var drifted: [(UInt16, UInt8, UInt8)] = []
for (offset, pair) in zip(regionBefore, regionAfter).enumerated() where pair.0 != pair.1 {
    drifted.append((UInt16(offset), pair.0, pair.1))
}

if drifted.isEmpty {
    print("Les 256 octets de la zone sont identiques à l'état de départ ✓")
} else {
    print("\(drifted.count) octet(s) diffèrent de l'état de départ :")
    for (address, before, after) in drifted {
        print(String(format: "  0x%04X : %02X → %02X   (%d → %d)", address, before, after, before, after))
    }
    print("Aucun essai n'écrit hors de sa propre zone : une dérive ici vient d'ailleurs")
    print("— configurateur tiers, action sur la souris, ou effet de bord du firmware.")
    uncertain.append("dérive hors zone d'essai")
}

await session.stop()
await transport.close()

print("\n────────────────────────")
if failures.isEmpty && uncertain.isEmpty {
    print("Tous les essais sont concluants. La souris est revenue à son état initial.")
} else {
    if !failures.isEmpty {
        print("Écritures divergentes : \(failures.joined(separator: ", "))")
    }
    if !uncertain.isEmpty {
        print("Restaurations non confirmées : \(uncertain.joined(separator: ", "))")
        print("L'état matériel de ces zones est incertain — vérifiez avec pulsar-probe.")
    }
    exit(1)
}
