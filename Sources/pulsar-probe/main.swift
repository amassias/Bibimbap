import Foundation
import PulsarCatalog
import PulsarHID
import PulsarProtocol

/// Sonde de diagnostic **en lecture seule**.
///
/// Énumère les périphériques Pulsar, ouvre l'interface de configuration, effectue le
/// handshake et vide la zone de réglages. Aucune écriture n'est émise : c'est l'outil
/// à utiliser pour confronter l'implémentation du protocole au matériel sans risquer
/// de modifier la configuration de la souris.
///
///     swift run pulsar-probe

setvbuf(stdout, nil, _IOLBF, 0)

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

let catalog = DeviceCatalog.embedded
print("Catalogue v\(catalog.sourceVersion) — \(catalog.families.count) familles, "
      + "\(catalog.families.reduce(0) { $0 + $1.mids.count }) MID\n")

let transport = IOKitHIDTransport(vendorIDs: Set(catalog.vendorIDs))
let devices = try await transport.discover()

guard !devices.isEmpty else {
    print("Aucun périphérique Pulsar détecté.")
    exit(1)
}

print("Collections Pulsar présentes :")
for device in devices {
    let mark = device.matchesConfigurationInterface(frameLength: PulsarFrame.length) ? "→" : " "
    print(String(
        format: "  %@ %04X:%04X  usage %04X:%02X  in=%2d out=%2d  %@",
        mark, device.vendorID, device.productID, device.usagePage, device.usage,
        device.maxInputReportSize, device.maxOutputReportSize, device.productName
    ))
}

guard let target = devices.first(where: {
    $0.matchesConfigurationInterface(frameLength: PulsarFrame.length)
}) else {
    print("\nAucune interface de configuration trouvée.")
    exit(1)
}

print("\nOuverture de \(target.productName) (\(target.transport.rawValue))…")
try await transport.open(target)

let session = PulsarSession(transport: transport)
await session.start()

let identity = try await session.identify()
print("  CID \(identity.cid)  MID \(identity.mid)  "
      + "connexion \(identity.connectionType) (max \(identity.connectionType.maximumReportRate) Hz)")

guard let family = catalog.family(cid: identity.cid, mid: identity.mid) else {
    print("  Modèle absent du catalogue embarqué — arrêt.")
    exit(1)
}
print("  Capteur \(family.sensor.type), DPI max \(family.dpi.maximum), "
      + "\(family.buttons.count) boutons, thème \(family.theme)")

let online = try await session.waitUntilOnline()
print("  Souris en ligne : \(online ? "oui" : "non — réveillez-la et relancez")")
guard online else { exit(1) }

if let version = try? await session.readFirmwareVersion() {
    print("  Firmware \(version)")
}
if let battery = try? await session.readBattery() {
    print("  Batterie \(battery.percentage) % (\(battery.millivolts) mV)"
          + (battery.isCharging ? ", en charge" : ""))
}
if let profile = try await session.readActiveProfile() {
    print("  Profil actif \(profile)")
} else {
    print("  Profils non supportés par ce modèle")
}
if let longDistance = try await session.readLongDistanceMode() {
    print("  Mode longue portée : \(longDistance ? "activé" : "désactivé")")
} else {
    print("  Mode longue portée non supporté")
}

print("\nLecture de la zone de réglages…")
let image = try await session.readFlash(FlashMap.coreRegion)

func scalar(_ address: UInt16, _ label: String) {
    if let value = ScalarSetting.decode(from: image, at: address) {
        print("  \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(value)")
    } else {
        print("  \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) — (checksum invalide)")
    }
}

if let code = ScalarSetting.decode(from: image, at: FlashMap.reportRate) {
    let hertz = ReportRateCodec.hertz(from: code).map(String.init) ?? "inconnu"
    print("  polling                \(hertz) Hz (code \(code))")
}
scalar(FlashMap.maxDPIStage, "paliers DPI")
scalar(FlashMap.currentDPI, "palier actif")
scalar(FlashMap.liftOffDistance, "lift-off")
scalar(FlashMap.debounceTime, "debounce")
scalar(FlashMap.motionSync, "motion sync")
scalar(FlashMap.angleSnap, "angle snap")
scalar(FlashMap.rippleControl, "ripple control")
scalar(FlashMap.sleepTime, "veille")
scalar(FlashMap.performanceState, "performance active")
scalar(FlashMap.performance, "performance")
scalar(FlashMap.angleTune, "rotation")
scalar(FlashMap.powerSaveBattery, "seuil éco")

print("\nPaliers DPI :")
if let codec = DPICodec(family: family, catalog: catalog) {
    let stageCount = Int(ScalarSetting.decode(from: image, at: FlashMap.maxDPIStage) ?? 6)
    for stage in 0..<max(stageCount, 1) {
        let address = FlashMap.dpiValue(stage: stage, extended: codec.usesExtendedBlock)
        let width = codec.usesExtendedBlock
            ? FlashMap.extendedDPIStageStride
            : FlashMap.dpiStageStride
        let block = image.slice(at: address, count: width)
        let colour = image.slice(at: FlashMap.dpiColor(stage: stage), count: 3)
        let decoded = (try? codec.decodeStage(block)).map { "\($0.x) × \($0.y) DPI" } ?? "indécodable"
        print("  \(stage + 1)  \(hex(block))   \(decoded.padding(toLength: 20, withPad: " ", startingAt: 0))"
              + "  RGB \(colour.map(String.init).joined(separator: ","))")
    }
} else {
    print("  Capteur \(family.sensor.type) absent de la table de plages.")
}

print("\nBoutons :")
for button in family.buttons {
    let block = image.slice(at: FlashMap.keyFunction(button: button.index), count: 4)
    let function = PulsarKeyFunction(rawValue: block.first ?? 0).map(String.init(describing:)) ?? "?"
    let parameter = (Int(block.count > 1 ? block[1] : 0) << 8) | Int(block.count > 2 ? block[2] : 0)
    print(String(format: "  %d  %@   %@  0x%04X", button.index, hex(block), function, parameter))
}

print("\nVidage brut 0x00–0x100 :")
for row in stride(from: 0, to: 256, by: 16) {
    print(String(format: "  %04X  %@", row, hex(image.slice(at: UInt16(row), count: 16))))
}

await session.stop()
await transport.close()
print("\nTerminé. Aucune écriture n'a été émise.")
