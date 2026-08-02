import Foundation

/// État du bandeau lumineux du récepteur.
///
/// Les neuf octets de couleur sont conservés même lorsque le mode vaut zéro afin de
/// pouvoir rallumer le récepteur sans remplacer les couleurs choisies auparavant.
public struct DongleLightingState: Hashable, Sendable, Codable {
    public static let colorChannelCount = 9
    public static let commandPayloadLength = 1 + colorChannelCount

    public var mode: UInt8
    public var colors: [UInt8]

    public var isEnabled: Bool { mode != 0 }

    public init(mode: UInt8, colors: [UInt8]) {
        self.mode = mode
        self.colors = Array((colors + [UInt8](repeating: 255, count: Self.colorChannelCount))
            .prefix(Self.colorChannelCount))
    }

    /// Décode exactement la charge utile des commandes RGB du récepteur.
    public init?(payload: [UInt8]) {
        guard payload.count == Self.commandPayloadLength else { return nil }
        self.init(mode: payload[0], colors: Array(payload.dropFirst()))
    }

    public func setting(enabled: Bool) -> DongleLightingState {
        DongleLightingState(
            mode: enabled ? max(mode, 1) : 0,
            colors: colors
        )
    }

    /// Charge utile commune aux getters/setters : mode puis trois groupes RGB.
    public var payload: [UInt8] {
        [mode] + colors
    }
}

extension PulsarSession {
    /// Lit le mode et les trois couleurs du récepteur 4K/8K.
    public func readDongleLighting() async throws -> DongleLightingState? {
        guard let response = await probe(PulsarFrame(command: .get4KDongleRGBValue)) else {
            return nil
        }
        return DongleLightingState(payload: response.payload)
    }

    /// Applique le mode et les neuf canaux couleur avec une charge utile complète.
    public func setDongleLighting(_ state: DongleLightingState) async throws {
        guard state.payload.count == DongleLightingState.commandPayloadLength else {
            throw PulsarSession.SessionError.malformedResponse(.set4KDongleRGB)
        }
        try await request(
            PulsarFrame(
                command: .set4KDongleRGB,
                payload: state.payload
            )
        )
    }
}
