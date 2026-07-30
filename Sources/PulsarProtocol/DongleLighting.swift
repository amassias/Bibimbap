import Foundation

/// État du bandeau lumineux du récepteur.
///
/// Les neuf octets de couleur sont conservés même lorsque le mode vaut zéro afin de
/// pouvoir rallumer le récepteur sans remplacer les couleurs choisies auparavant.
public struct DongleLightingState: Hashable, Sendable {
    public var mode: UInt8
    public var colors: [UInt8]

    public var isEnabled: Bool { mode != 0 }

    public init(mode: UInt8, colors: [UInt8]) {
        self.mode = mode
        self.colors = Array((colors + [UInt8](repeating: 255, count: 9)).prefix(9))
    }

    public func setting(enabled: Bool) -> DongleLightingState {
        DongleLightingState(
            mode: enabled ? max(mode, 1) : 0,
            colors: colors
        )
    }
}

extension PulsarSession {
    /// Lit le mode et les trois couleurs du récepteur 4K/8K.
    public func readDongleLighting() async throws -> DongleLightingState? {
        guard let response = await probe(PulsarFrame(command: .get4KDongleRGBValue)) else {
            return nil
        }
        return DongleLightingState(
            mode: response[byte: 5],
            colors: (6...14).map { response[byte: $0] }
        )
    }

    /// Applique le mode en préservant les couleurs lues sur le récepteur.
    public func setDongleLighting(_ state: DongleLightingState) async throws {
        try await request(
            PulsarFrame(
                command: .set4KDongleRGB,
                payload: [state.mode] + state.colors
            )
        )
    }
}
