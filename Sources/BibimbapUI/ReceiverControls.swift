import BibimbapFeatures
import PulsarProtocol

/// Contrôles récepteur que l'interface peut afficher pour une connexion donnée.
///
/// Cette projection reste pure pour que la règle « pas de commande sondée, pas de
/// contrôle » soit testable sans démarrer SwiftUI ni ouvrir un transport HID.
enum ReceiverControl: Hashable {
    case rgbLighting
    case effect
    case dpiLighting
    case buttonMode
    case buttonFunctions
}

func receiverControls(for capabilities: DeviceCapabilities) -> Set<ReceiverControl> {
    var controls = Set<ReceiverControl>()
    if capabilities.receiver.supportsRGBLighting { controls.insert(.rgbLighting) }
    if capabilities.receiver.supportsEffect { controls.insert(.effect) }
    if capabilities.receiver.supportsDPILighting { controls.insert(.dpiLighting) }
    if capabilities.receiver.supportsButtonMode { controls.insert(.buttonMode) }
    if capabilities.receiver.supportsButtonFunctions { controls.insert(.buttonFunctions) }
    return controls
}
