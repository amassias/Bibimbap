import Foundation
import BibimbapLocalization
import PulsarHID

/// Dialogue requête/réponse avec un périphérique Pulsar.
///
/// Le protocole n'a pas d'identifiant de transaction : la corrélation repose sur le fait
/// que le périphérique ré-émet le code de commande, et pour les lectures flash l'adresse
/// et la longueur. Une seule requête peut donc être en vol à la fois, ce que garantit
/// l'isolation de cet acteur.
public actor PulsarSession {
    public struct Timing: Sendable {
        /// Délai d'attente d'une réponse avant de réémettre.
        public var responseTimeout: Duration = .milliseconds(200)
        /// Nombre total de tentatives par requête.
        public var attempts: Int = 5
        /// Pause entre deux tentatives.
        public var retryDelay: Duration = .milliseconds(10)

        public init() {}
    }

    public enum SessionError: Error, Equatable, Sendable {
        case notStarted
        case timedOut(PulsarCommand)
        case unsupported(PulsarCommand)
        case mismatchedResponse(expected: PulsarCommand, received: PulsarCommand)
        case firmwareOperationBlocked(PulsarCommand)
        case readbackMismatch(address: UInt16)
        case malformedResponse(PulsarCommand)
        case commandReadbackMismatch(PulsarCommand)
    }

    private let transport: any HIDTransport
    private let timing: Timing

    private var pumpTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var waiter: Waiter?
    private var notificationContinuations: [UUID: AsyncStream<PulsarChangeNotification>.Continuation] = [:]
    private var frameLog: [LoggedFrame] = []

    private struct Waiter {
        var id: UUID
        var command: PulsarCommand
        var address: UInt16?
        var continuation: CheckedContinuation<PulsarFrame?, Never>
    }

    /// Trace circulaire des dernières trames, pour le diagnostic exportable.
    public struct LoggedFrame: Sendable, Hashable {
        public var outgoing: Bool
        public var frame: PulsarFrame
        public var timestamp: Date
    }

    public init(transport: any HIDTransport, timing: Timing = Timing()) {
        self.transport = transport
        self.timing = timing
    }

    // MARK: Cycle de vie

    /// Démarre la consommation des rapports d'entrée. Idempotent.
    public func start() async {
        guard pumpTask == nil else { return }
        let stream = await transport.inputReports()
        pumpTask = Task { [weak self] in
            for await report in stream {
                await self?.handle(report)
            }
            await self?.finishWaiter()
        }
    }

    public func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        finishWaiter()
        notificationContinuations.values.forEach { $0.finish() }
        notificationContinuations.removeAll()
    }

    /// Libère l'attente en cours. Toute continuation installée doit être reprise
    /// exactement une fois, y compris quand le flux se termine sous elle.
    private func finishWaiter() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let pending = waiter {
            waiter = nil
            pending.continuation.resume(returning: nil)
        }
    }

    // MARK: Réception

    private func handle(_ report: HIDInputReport) {
        guard report.reportID == PulsarFrame.reportID else { return }
        // Le rapport peut porter le report ID en tête selon le chemin IOKit emprunté.
        var bytes = report.bytes
        if bytes.count == PulsarFrame.length + 1, bytes[0] == PulsarFrame.reportID {
            bytes.removeFirst()
        }
        guard let frame = try? PulsarFrame(decoding: bytes) else { return }
        record(frame, outgoing: false)

        if frame.command == .statusChanged {
            let notification = PulsarChangeNotification(primary: frame[byte: 5], secondary: frame[byte: 6])
            if !notification.isEmpty {
                notificationContinuations.values.forEach { $0.yield(notification) }
            }
            return
        }

        guard let pending = waiter, pending.command == frame.command else { return }
        if let address = pending.address, address != frame.address { return }
        waiter = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        pending.continuation.resume(returning: frame)
    }

    private func record(_ frame: PulsarFrame, outgoing: Bool) {
        frameLog.append(LoggedFrame(outgoing: outgoing, frame: frame, timestamp: Date()))
        if frameLog.count > 512 {
            frameLog.removeFirst(frameLog.count - 512)
        }
    }

    public func diagnosticLog() -> [LoggedFrame] { frameLog }

    public func changeNotifications() -> AsyncStream<PulsarChangeNotification> {
        let id = UUID()
        return AsyncStream { continuation in
            notificationContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeNotificationContinuation(id) }
            }
        }
    }

    private func removeNotificationContinuation(_ id: UUID) {
        notificationContinuations.removeValue(forKey: id)
    }

    // MARK: Émission

    /// Émet une trame et attend l'acquittement du périphérique.
    ///
    /// Un statut `1` n'est **pas** une erreur ici : il signifie « acquitté, sans données ».
    /// C'est la réponse normale d'une commande d'action comme la prise de verrou. Seules
    /// les commandes de lecture doivent le traiter comme un refus, ce que fait
    /// `requestData(_:)`.
    ///
    /// Les commandes de mise à jour firmware sont refusées : elles relèvent de la phase 2
    /// et de son propre chemin protégé.
    @discardableResult
    public func request(_ frame: PulsarFrame, matchingAddress: Bool = false) async throws -> PulsarFrame {
        guard pumpTask != nil else { throw SessionError.notStarted }
        guard !frame.command.isFirmwareOperation else {
            throw SessionError.firmwareOperationBlocked(frame.command)
        }

        let encoded = frame.encoded()
        for attempt in 0..<timing.attempts {
            try Task.checkCancellation()
            record(frame, outgoing: true)
            try await transport.send(reportID: PulsarFrame.reportID, payload: encoded)

            if let response = await awaitResponse(
                command: frame.command,
                address: matchingAddress ? frame.address : nil
            ) {
                return response
            }
            if attempt < timing.attempts - 1 {
                try await Task.sleep(for: timing.retryDelay)
            }
        }
        throw SessionError.timedOut(frame.command)
    }

    /// Émet une commande de lecture et exige des données en retour.
    ///
    /// Un statut `1` signifie que le périphérique n'a rien à donner : pour une lecture,
    /// c'est un refus, et la commande n'existe pas sur ce modèle.
    @discardableResult
    public func requestData(_ frame: PulsarFrame, matchingAddress: Bool = false) async throws -> PulsarFrame {
        let response = try await request(frame, matchingAddress: matchingAddress)
        guard !response.isUnsupported else {
            throw SessionError.unsupported(frame.command)
        }
        return response
    }

    /// Sonde une capacité : `nil` si le modèle ne la gère pas ou ne répond pas.
    public func probe(_ frame: PulsarFrame) async -> PulsarFrame? {
        try? await requestData(frame)
    }

    /// Attend la réponse à une commande, ou `nil` au bout du délai imparti.
    ///
    /// Une seule continuation est en jeu : soit la réception d'une trame la reprend,
    /// soit la tâche de délai le fait. `finishWaiter` couvre le cas où le
    /// transport se termine entre-temps.
    private func awaitResponse(command: PulsarCommand, address: UInt16?) async -> PulsarFrame? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiter = Waiter(id: id, command: command, address: address, continuation: continuation)
            timeoutTask = Task { [timing] in
                try? await Task.sleep(for: timing.responseTimeout)
                await self.expire(id)
            }
        }
    }

    private func expire(_ id: UUID) {
        guard let pending = waiter, pending.id == id else { return }
        waiter = nil
        timeoutTask = nil
        pending.continuation.resume(returning: nil)
    }
}

extension PulsarSession.SessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notStarted:
            L10n.string("La session matérielle n'est pas démarrée.")
        case .timedOut:
            L10n.string("Le périphérique n'a pas répondu à temps.")
        case .unsupported:
            L10n.string("Cette capacité n'est pas prise en charge par ce périphérique.")
        case .mismatchedResponse:
            L10n.string("Le périphérique a répondu avec une opération inattendue.")
        case .firmwareOperationBlocked:
            L10n.string("Cette opération firmware est bloquée par le modèle de sécurité.")
        case .readbackMismatch:
            L10n.string("La relecture indépendante n'a pas confirmé la valeur écrite.")
        }
    }
}

// MARK: - Opérations de haut niveau

extension PulsarSession {
    /// Handshake : identifie le modèle et le mode de connexion.
    ///
    /// La commande porte un défi de quatre octets aléatoires suivis de quatre zéros ;
    /// une trame sans charge utile est rejetée par le périphérique.
    public func identify() async throws -> DeviceIdentity {
        let challenge = (0..<4).map { _ in UInt8.random(in: 0...255) } + [0, 0, 0, 0]
        let response = try await requestData(PulsarFrame(command: .encryptionData, payload: challenge))
        let type = PulsarConnectionType(rawValue: response[byte: 11]) ?? .wired1k
        return DeviceIdentity(
            cid: Int(response[byte: 9]),
            mid: Int(response[byte: 10]),
            connectionType: type,
            dongleType: Int(response[byte: 12])
        )
    }

    /// Signale au périphérique qu'un logiciel de configuration est actif.
    ///
    /// Sans cela, certains modèles continuent d'appliquer leurs raccourcis internes
    /// pendant qu'on écrit.
    public func setDriverOnline(_ online: Bool) async throws {
        try await request(PulsarFrame(command: .pcDriverStatus, payload: [online ? 1 : 0]))
    }

    public func readBattery() async throws -> BatteryState {
        let response = try await requestData(PulsarFrame(command: .batteryLevel))
        return BatteryState(
            percentage: Int(response[byte: 5]),
            isCharging: response[byte: 6] == 1,
            millivolts: Int(response[byte: 7]) << 8 | Int(response[byte: 8])
        )
    }

    public func readFirmwareVersion() async throws -> String {
        let response = try await requestData(PulsarFrame(command: .readVersionID))
        return Self.formatVersion(major: response[byte: 5], minor: response[byte: 6])
    }

    public func readDongleVersion() async throws -> String? {
        guard let response = await probe(PulsarFrame(command: .getDongleVersion)) else { return nil }
        return Self.formatVersion(major: response[byte: 5], minor: response[byte: 6])
    }

    static func formatVersion(major: UInt8, minor: UInt8) -> String {
        "v\(major).\(String(format: "%02x", minor))"
    }

    public func readSignalStrength() async throws -> Int? {
        guard let response = await probe(PulsarFrame(command: .getRSSIValue)) else { return nil }
        return Int(response[byte: 5])
    }

    public func readActiveProfile() async throws -> Int? {
        guard let response = await probe(PulsarFrame(command: .getCurrentConfig)) else { return nil }
        return Int(response[byte: 5])
    }

    public func setActiveProfile(_ profile: Int) async throws {
        try await request(PulsarFrame(command: .setCurrentConfig, payload: [UInt8(profile)]))
    }

    public func readLongDistanceMode() async throws -> Bool? {
        guard let response = await probe(PulsarFrame(command: .getLongRangeMode)) else { return nil }
        return response[byte: 5] == 1
    }

    public func setLongDistanceMode(_ enabled: Bool) async throws {
        try await request(PulsarFrame(command: .setLongRangeMode, payload: [enabled ? 1 : 0]))
    }

    public func isOnline() async throws -> Bool {
        let response = try await request(PulsarFrame(command: .deviceOnline))
        return response[byte: 5] != 0
    }

    /// Attend que la souris se signale en ligne derrière son récepteur.
    ///
    /// En filaire, la première interrogation répond déjà « en ligne ». Sans fil, le
    /// dongle répond pour lui-même dès qu'il est branché, alors que la souris peut être
    /// endormie ou hors de portée : lire la flash à ce moment-là expire sans explication.
    /// L'octet 9 indique que le récepteur est encore en train d'interroger la souris.
    @discardableResult
    public func waitUntilOnline(timeout: Duration = .seconds(3)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let response = try await request(PulsarFrame(command: .deviceOnline))
            if response[byte: 9] != 1 {
                return response[byte: 5] == 1
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Prend ou rend le verrou d'écriture du périphérique.
    ///
    /// Un lot de réglages doit être encadré par `hold(true)` / `hold(false)` : le
    /// périphérique signale son occupation dans l'octet 9 et il faut attendre qu'il
    /// se libère avant d'enchaîner, sans quoi les écritures suivantes sont perdues.
    @discardableResult
    public func hold(_ acquire: Bool) async throws -> Bool {
        let frame = PulsarFrame(command: .deviceOnline, payload: [acquire ? 1 : 0])
        var response = try await request(frame)
        var spins = 0
        while response[byte: 9] == 1 {
            guard spins < 40 else { throw SessionError.timedOut(.deviceOnline) }
            spins += 1
            try await Task.sleep(for: .milliseconds(10))
            response = try await request(frame)
        }
        return response[byte: 5] == 1
    }

    /// Réinitialisation complète. Le périphérique répond lorsqu'il a fini.
    public func clearSettings() async throws {
        try await request(PulsarFrame(command: .clearSetting))
    }

    public func enterPairing() async throws {
        try await request(PulsarFrame(command: .dongleEnterPair))
    }

    public func pairState() async throws -> (state: PulsarPairState, secondsRemaining: Int) {
        let response = try await requestData(PulsarFrame(command: .getPairState))
        let state = PulsarPairState(rawValue: response[byte: 5]) ?? .pairing
        return (state, Int(response[byte: 6]))
    }

    // MARK: Flash

    /// Lit une plage de la flash de configuration, dix octets par trame.
    ///
    /// L'image de départ est reprise telle quelle, ce qui permet d'enchaîner plusieurs
    /// plages disjointes — zone principale puis paliers DPI étendus, par exemple.
    @discardableResult
    public func readFlash(
        _ range: Range<UInt16>,
        into image: FlashImage = FlashImage()
    ) async throws -> FlashImage {
        var image = image
        var address = range.lowerBound
        while address < range.upperBound {
            let count = min(PulsarFrame.payloadCapacity, Int(range.upperBound - address))
            let response = try await requestData(
                PulsarFrame(command: .readFlashData, address: address, declaredLength: UInt8(count)),
                matchingAddress: true
            )
            image.write(Array(response.payload.prefix(count)), at: address)
            address += UInt16(count)
        }
        return image
    }

    /// Écrit un bloc en flash, dix octets par trame.
    public func writeFlash(_ data: [UInt8], at address: UInt16) async throws {
        var offset = 0
        while offset < data.count {
            let count = min(PulsarFrame.payloadCapacity, data.count - offset)
            let chunk = Array(data[offset..<(offset + count)])
            try await request(
                PulsarFrame(
                    command: .writeFlashData,
                    address: address + UInt16(offset),
                    payload: chunk
                ),
                matchingAddress: true
            )
            offset += count
        }
    }

    /// Écrit un réglage scalaire puis le relit pour confirmer.
    public func writeScalar(_ value: UInt8, at address: UInt16) async throws {
        let setting = ScalarSetting(address: address, value: value)
        try await writeFlash(setting.encoded, at: address)

        let image = try await readFlash(address..<(address + 2))
        guard ScalarSetting.decode(from: image, at: address) == value else {
            throw SessionError.readbackMismatch(address: address)
        }
    }
}

/// Identité rapportée par le périphérique lui-même, distincte du VID/PID USB.
public struct DeviceIdentity: Hashable, Sendable {
    public var cid: Int
    public var mid: Int
    public var connectionType: PulsarConnectionType
    public var dongleType: Int

    public init(cid: Int, mid: Int, connectionType: PulsarConnectionType, dongleType: Int) {
        self.cid = cid
        self.mid = mid
        self.connectionType = connectionType
        self.dongleType = dongleType
    }
}

public struct BatteryState: Hashable, Sendable {
    public var percentage: Int
    public var isCharging: Bool
    public var millivolts: Int

    public init(percentage: Int, isCharging: Bool, millivolts: Int) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.millivolts = millivolts
    }
}
