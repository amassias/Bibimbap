import BibimbapFeatures
import PulsarCatalog
import PulsarProtocol
import Testing
@testable import BibimbapUI

private let receiverTestFamily = DeviceCatalog.embedded.family(cid: 87, mid: 10)!

private func receiverTestCapabilities(_ receiver: ReceiverCapabilities) -> DeviceCapabilities {
    DeviceCapabilities(
        family: receiverTestFamily,
        catalog: .embedded,
        connection: .wireless1k,
        supportsProfiles: true,
        supportsLongDistance: true,
        supportsSignalStrength: true,
        flashCapabilities: DeviceFlashCapabilities(
            supportsFanMode: false,
            supportsSensorMode: true,
            supportsPerformanceLevel: true
        ),
        receiver: receiver
    )
}

@Suite("Capacités affichées du récepteur")
struct ReceiverControlsTests {
    @Test("Aucune réponse de commande ne produit un contrôle")
    func unsupportedCommandsAreHidden() {
        #expect(receiverControls(for: receiverTestCapabilities(.none)).isEmpty)
    }

    @Test("L'interface ne montre que les commandes sondées")
    func controlsFollowProbedCapabilities() {
        let receiver = ReceiverCapabilities(
            supportsRGBLighting: true,
            supportsEffect: false,
            supportsDPILighting: true,
            buttonModeKind: .oButton,
            buttonModeOptions: [0, 5],
            buttonFunctionSlots: []
        )
        let controls = receiverControls(for: receiverTestCapabilities(receiver))

        #expect(controls.contains(.rgbLighting))
        #expect(controls.contains(.dpiLighting))
        #expect(controls.contains(.buttonMode))
        #expect(!controls.contains(.effect))
        #expect(!controls.contains(.buttonFunctions))
    }

    @Test("Une fonction ventilateur n'est pas ajoutée à un modèle sans fan mode")
    func unsupportedFanFunctionIsRemoved() {
        let receiver = ReceiverCapabilities(
            buttonModeKind: .keyFunction,
            buttonModeOptions: [0, 1, 8]
        )
        let capabilities = receiverTestCapabilities(receiver)
        #expect(capabilities.receiver.buttonModeOptions == [0, 1])
    }
}
