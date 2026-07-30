import Foundation
import IOKit
import IOKit.hid

/// Transport HID réel, adossé à `IOHIDManager`.
///
/// WebKit n'implémente pas WebHID, donc rien de ce que fait le configurateur web n'est
/// accessible depuis une WKWebView : tout passe ici.
///
/// Toutes les interactions IOKit sont confinées à un fil dédié portant sa propre boucle
/// d'exécution, car `IOHIDDeviceScheduleWithRunLoop` exige une boucle vivante pour livrer
/// les rapports d'entrée. L'acteur ne fait que sérialiser les demandes vers ce fil.
public actor IOKitHIDTransport: HIDTransport {
    private let backend: IOKitHIDBackend
    private let frameLength: Int

    /// - Parameters:
    ///   - frameLength: longueur de trame attendue, hors report ID. 16 pour les souris Pulsar.
    ///   - matching: filtre VID appliqué à l'énumération. Vide = aucun filtre.
    public init(frameLength: Int = 16, vendorIDs: Set<UInt16> = []) {
        self.frameLength = frameLength
        self.backend = IOKitHIDBackend(vendorIDs: vendorIDs)
    }

    public func discover() async throws -> [HIDDeviceIdentifier] {
        backend.enumerateDevices()
    }

    public func open(_ identifier: HIDDeviceIdentifier) async throws {
        try backend.open(identifier)
    }

    public func close() async {
        backend.close()
    }

    public func currentDevice() async -> HIDDeviceIdentifier? {
        backend.currentIdentifier()
    }

    public func send(reportID: UInt8, payload: [UInt8]) async throws {
        guard payload.count <= frameLength else {
            throw HIDTransportError.reportTooLarge(payload.count)
        }
        try backend.send(reportID: reportID, payload: payload)
    }

    public func inputReports() async -> AsyncStream<HIDInputReport> {
        backend.inputReportStream()
    }

    public func deviceEvents() async -> AsyncStream<HIDDeviceEvent> {
        backend.deviceEventStream()
    }
}

// MARK: - Fil IOKit

/// Propriétaire exclusif des références IOKit. Non-`Sendable` par nature : l'accès est
/// sérialisé par l'acteur au-dessus et par la boucle d'exécution en dessous.
final class IOKitHIDBackend: @unchecked Sendable {
    private let manager: IOHIDManager
    private let vendorIDs: Set<UInt16>
    private let lock = NSLock()

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var openedDevice: IOHIDDevice?
    private var openedIdentifier: HIDDeviceIdentifier?
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private var inputBufferSize: Int = 0

    private var inputContinuations: [UUID: AsyncStream<HIDInputReport>.Continuation] = [:]
    private var eventContinuations: [UUID: AsyncStream<HIDDeviceEvent>.Continuation] = [:]

    init(vendorIDs: Set<UInt16>) {
        self.vendorIDs = vendorIDs
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        startThread()
    }

    deinit {
        if let buffer = inputBuffer { buffer.deallocate() }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    // MARK: Boucle d'exécution dédiée

    private func startThread() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { return }
            guard let current = CFRunLoopGetCurrent() else { return }
            self.lock.withLock { self.runLoop = current }

            IOHIDManagerScheduleWithRunLoop(self.manager, current, CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerOpen(self.manager, IOOptionBits(kIOHIDOptionsTypeNone))

            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(self.manager, deviceMatchedCallback, context)
            IOHIDManagerRegisterDeviceRemovalCallback(self.manager, deviceRemovedCallback, context)

            // Une source factice empêche la boucle de rendre la main faute de travail.
            var sourceContext = CFRunLoopSourceContext()
            let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceContext)
            CFRunLoopAddSource(current, source, .defaultMode)

            ready.signal()
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 10, false)
            }
        }
        thread.name = "gg.pulsar.bibimbap.hid"
        thread.qualityOfService = QualityOfService.userInitiated
        thread.start()
        self.thread = thread
        ready.wait()
    }

    /// Exécute un bloc sur le fil IOKit et attend son résultat.
    private func onHIDThread<T>(_ body: @escaping () -> T) -> T {
        guard let runLoop, CFRunLoopGetCurrent() != runLoop else {
            return body()
        }
        let semaphore = DispatchSemaphore(value: 0)
        // `box` traverse la frontière du fil ; l'attente en aval garantit l'exclusivité.
        nonisolated(unsafe) var result: T?
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            result = body()
            semaphore.signal()
        }
        CFRunLoopWakeUp(runLoop)
        semaphore.wait()
        return result!
    }

    // MARK: Énumération

    func enumerateDevices() -> [HIDDeviceIdentifier] {
        onHIDThread { [self] in
            guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
            return set
                .compactMap(Self.identifier(for:))
                .filter { vendorIDs.isEmpty || vendorIDs.contains($0.vendorID) }
                .sorted { ($0.vendorID, $0.productID, $0.usagePage) < ($1.vendorID, $1.productID, $1.usagePage) }
        }
    }

    static func identifier(for device: IOHIDDevice) -> HIDDeviceIdentifier? {
        func number(_ key: String) -> Int? {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
        }
        func string(_ key: String) -> String? {
            IOHIDDeviceGetProperty(device, key as CFString) as? String
        }
        guard let vendor = number(kIOHIDVendorIDKey), let product = number(kIOHIDProductIDKey) else {
            return nil
        }
        return HIDDeviceIdentifier(
            vendorID: UInt16(truncatingIfNeeded: vendor),
            productID: UInt16(truncatingIfNeeded: product),
            locationID: UInt32(truncatingIfNeeded: number(kIOHIDLocationIDKey) ?? 0),
            usagePage: UInt32(truncatingIfNeeded: number(kIOHIDPrimaryUsagePageKey) ?? 0),
            usage: UInt32(truncatingIfNeeded: number(kIOHIDPrimaryUsageKey) ?? 0),
            productName: string(kIOHIDProductKey) ?? "",
            manufacturer: string(kIOHIDManufacturerKey) ?? "",
            transport: HIDTransportKind(ioKitTransport: string(kIOHIDTransportKey)),
            maxInputReportSize: number(kIOHIDMaxInputReportSizeKey) ?? 0,
            maxOutputReportSize: number(kIOHIDMaxOutputReportSizeKey) ?? 0
        )
    }

    private func device(matching identifier: HIDDeviceIdentifier) -> IOHIDDevice? {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        return set.first { Self.identifier(for: $0) == identifier }
    }

    // MARK: Ouverture / fermeture

    func open(_ identifier: HIDDeviceIdentifier) throws {
        let result: Result<Void, HIDTransportError> = onHIDThread { [self] in
            closeLocked()
            guard let device = device(matching: identifier) else {
                return .failure(.deviceNotFound)
            }

            // macOS protège l'écoute des rapports HID derrière l'autorisation
            // « Surveillance de l'entrée ». IOHIDDeviceOpen est censé demander cet
            // accès implicitement, mais cette demande ne se présente pas toujours pour
            // une application sandboxée. La déclencher explicitement évite alors un
            // kIOReturnNotPermitted opaque malgré un dongle correctement énuméré.
            let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            if access != kIOHIDAccessTypeGranted,
               !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
                return .failure(.openFailed(kIOReturnNotPermitted))
            }

            let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard status == kIOReturnSuccess else {
                return .failure(.openFailed(status))
            }

            let size = max(identifier.maxInputReportSize, 1)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            buffer.initialize(repeating: 0, count: size)

            lock.withLock {
                openedDevice = device
                openedIdentifier = identifier
                inputBuffer = buffer
                inputBufferSize = size
            }

            IOHIDDeviceRegisterInputReportCallback(
                device, buffer, size, inputReportCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            return .success(())
        }
        try result.get()
    }

    func close() {
        onHIDThread { [self] in closeLocked() }
    }

    private func closeLocked() {
        let (device, buffer) = lock.withLock { (openedDevice, inputBuffer) }
        guard let device else { return }

        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer?.deallocate()

        let continuations = lock.withLock {
            openedDevice = nil
            openedIdentifier = nil
            inputBuffer = nil
            inputBufferSize = 0
            let values = Array(inputContinuations.values)
            inputContinuations.removeAll()
            return values
        }
        continuations.forEach { $0.finish() }
    }

    func currentIdentifier() -> HIDDeviceIdentifier? {
        lock.withLock { openedIdentifier }
    }

    // MARK: Émission

    func send(reportID: UInt8, payload: [UInt8]) throws {
        let result: Result<Void, HIDTransportError> = onHIDThread { [self] in
            guard let device = lock.withLock({ openedDevice }) else {
                return .failure(.notOpen)
            }
            // Pour un rapport numéroté, IOKit attend l'identifiant à la fois en paramètre
            // et comme premier octet du tampon : la taille de sortie annoncée par le
            // périphérique (17) vaut bien 1 + 16.
            let buffer = [reportID] + payload
            let status = buffer.withUnsafeBufferPointer { pointer in
                IOHIDDeviceSetReport(
                    device, kIOHIDReportTypeOutput, CFIndex(reportID),
                    pointer.baseAddress!, pointer.count
                )
            }
            guard status == kIOReturnSuccess else {
                return .failure(status == kIOReturnNotOpen ? .disconnected : .writeFailed(status))
            }
            return .success(())
        }
        try result.get()
    }

    // MARK: Flux

    func inputReportStream() -> AsyncStream<HIDInputReport> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock { inputContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.inputContinuations.removeValue(forKey: id) }
            }
        }
    }

    func deviceEventStream() -> AsyncStream<HIDDeviceEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock { eventContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.eventContinuations.removeValue(forKey: id) }
            }
        }
    }

    fileprivate func emit(_ report: HIDInputReport) {
        lock.withLock { Array(inputContinuations.values) }.forEach { $0.yield(report) }
    }

    fileprivate func emit(_ event: HIDDeviceEvent) {
        if case .detached(let identifier) = event, identifier == currentIdentifier() {
            closeLocked()
        }
        lock.withLock { Array(eventContinuations.values) }.forEach { $0.yield(event) }
    }
}

// MARK: - Rappels C

private let inputReportCallback: IOHIDReportCallback = { context, _, _, _, reportID, report, length in
    guard let context, length > 0 else { return }
    let backend = Unmanaged<IOKitHIDBackend>.fromOpaque(context).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
    backend.emit(HIDInputReport(reportID: UInt8(truncatingIfNeeded: reportID), bytes: bytes))
}

private let deviceMatchedCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context, let identifier = IOKitHIDBackend.identifier(for: device) else { return }
    let backend = Unmanaged<IOKitHIDBackend>.fromOpaque(context).takeUnretainedValue()
    backend.emit(HIDDeviceEvent.attached(identifier))
}

private let deviceRemovedCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context, let identifier = IOKitHIDBackend.identifier(for: device) else { return }
    let backend = Unmanaged<IOKitHIDBackend>.fromOpaque(context).takeUnretainedValue()
    backend.emit(HIDDeviceEvent.detached(identifier))
}
