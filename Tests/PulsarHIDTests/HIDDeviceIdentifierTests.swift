import Foundation
import Testing
@testable import PulsarHID

@Suite("Identité HID — clé stable et filtrage des collections")
struct HIDDeviceIdentifierTests {
    private func identifier(
        vendorID: UInt16 = 0x3710,
        productID: UInt16 = 0x5406,
        locationID: UInt32 = 0x0100_0000,
        usagePage: UInt32 = 0xFF05,
        usage: UInt32 = 0x0001,
        productName: String = "Pulsar X2 CrazyLight",
        transport: HIDTransportKind = .usb,
        maxInput: Int = 17,
        maxOutput: Int = 17
    ) -> HIDDeviceIdentifier {
        HIDDeviceIdentifier(
            vendorID: vendorID,
            productID: productID,
            locationID: locationID,
            usagePage: usagePage,
            usage: usage,
            productName: productName,
            manufacturer: "Pulsar",
            transport: transport,
            maxInputReportSize: maxInput,
            maxOutputReportSize: maxOutput
        )
    }

    @Test("La clé stable survit à un changement de port")
    func stableKeyIgnoresLocation() {
        // Rebrancher sur un autre port change `locationID` et peut changer les tailles
        // annoncées ; ce n'est pas un autre périphérique pour autant.
        let left = identifier(locationID: 0x0100_0000, maxInput: 17, maxOutput: 17)
        let right = identifier(locationID: 0x0230_0000, maxInput: 49, maxOutput: 49)

        #expect(left.stableKey == right.stableKey)
        #expect(left != right)
    }

    @Test("Deux modèles ou deux transports ne partagent pas la même clé")
    func stableKeyDistinguishesModelsAndTransports() {
        let reference = identifier()
        #expect(identifier(productID: 0x3414).stableKey != reference.stableKey)
        #expect(identifier(vendorID: 0x0001).stableKey != reference.stableKey)
        #expect(identifier(transport: .bluetooth).stableKey != reference.stableKey)
        #expect(identifier(usage: 0x0002).stableKey != reference.stableKey)
        #expect(identifier(usagePage: 0x0001).stableKey != reference.stableKey)
    }

    @Test("Seule la page vendor 0xFF05 porte le canal de configuration")
    func onlyVendorPageMatches() {
        #expect(identifier().matchesConfigurationInterface(frameLength: 16))
        // La collection souris standard répond aux mêmes VID/PID : la retenir reviendrait
        // à écrire des trames de configuration dans le flux de pointage.
        #expect(!identifier(usagePage: 0x0001).matchesConfigurationInterface(frameLength: 16))
    }

    @Test("Une collection trop étroite pour la trame est écartée")
    func undersizedCollectionIsRejected() {
        // 16 octets de trame plus le report ID : une collection qui annonce moins ne peut
        // pas porter le dialogue, même sur la bonne page d'usage.
        #expect(!identifier(maxInput: 16, maxOutput: 17).matchesConfigurationInterface(frameLength: 16))
        #expect(!identifier(maxInput: 17, maxOutput: 16).matchesConfigurationInterface(frameLength: 16))
        #expect(!identifier(maxInput: 0, maxOutput: 0).matchesConfigurationInterface(frameLength: 16))
        // Le dongle 8K annonce davantage parce qu'il porte aussi un rapport rapide.
        #expect(identifier(maxInput: 49, maxOutput: 49).matchesConfigurationInterface(frameLength: 16))
    }

    @Test("Un périphérique sans nom reste présentable")
    func displayNameFallsBack() {
        #expect(identifier().displayName == "Pulsar X2 CrazyLight")
        #expect(identifier(productName: "  ").displayName == "Pulsar")
        #expect(identifier().vendorProductLabel == "VID 3710 · PID 5406")
        #expect(identifier(locationID: 0x0230_0000).locationLabel == "0x02300000")
    }

    @Test("Chaque cause d'échec de transport porte son propre message")
    func transportErrorsAreDistinct() {
        // La permission refusée ne doit surtout pas se confondre avec un code d'ouverture :
        // l'une se règle dans les Réglages Système, l'autre non.
        #expect(HIDTransportError.permissionDenied != HIDTransportError.openFailed(-536_870_174))
        #expect(HIDTransportError.permissionDenied.errorDescription?.isEmpty == false)
        #expect(HIDTransportError.managerOpenFailed(-1).errorDescription?.isEmpty == false)
    }
}
