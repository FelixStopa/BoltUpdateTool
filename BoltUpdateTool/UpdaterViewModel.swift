import Combine
import Foundation

/// A dedicated worker thread owns the CFRunLoop on which IOHID callbacks are
/// delivered. All operations for a transport stay on this thread.
final class HidWorker {
    private var thread: Thread?
    private let workLock = NSLock()
    private var queuedWork: [() -> Void] = []

    init() {
        let thread = Thread { [weak self] in
            while true {
                if let work = self?.takeWork() {
                    work()
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        thread.name = "BoltDFU-HIDWorker"
        thread.start()
        self.thread = thread
    }

    private func takeWork() -> (() -> Void)? {
        workLock.lock()
        defer { workLock.unlock() }
        guard !queuedWork.isEmpty else { return nil }
        return queuedWork.removeFirst()
    }

    func run(_ block: @escaping () -> Void) {
        workLock.lock()
        queuedWork.append(block)
        workLock.unlock()
    }
}

enum UpdateStage: Equatable {
    case idle
    case preparing
    case switchingToBootloader
    case waitingForReplug
    case flashing
    case restarting
    case completed
    case failed

    var message: String? {
        switch self {
        case .idle: return nil
        case .preparing: return "Preparing the Bolt receiver…"
        case .switchingToBootloader:
            return "Switching the receiver from C548 runtime to the AB07 bootloader. No action is needed yet…"
        case .waitingForReplug:
            return "Unplug the Bolt receiver now, then plug it back in. Waiting for bootloader AB07…"
        case .flashing: return "Writing both firmware images. Do not unplug the receiver."
        case .restarting: return "Restarting the receiver and verifying the result…"
        case .completed: return "Update completed and the C548 receiver is back online."
        case .failed: return "The update stopped because of an error."
        }
    }

    var requiresUserAction: Bool { self == .waitingForReplug }
}

final class UpdaterViewModel: ObservableObject {
    @Published var logLines: [String] = []
    @Published var isBusy = false
    @Published var entities: [FirmwareEntity] = []
    @Published var isInBootloaderMode = false
    @Published var deviceFound = false
    @Published var deviceProductString = ""
    @Published var progress: FlashProgress?
    @Published var lastErrorMessage: String?
    @Published var stage: UpdateStage = .idle
    @Published private(set) var selectedFirmwarePackage: SelectedFirmwarePackage?
    @Published private(set) var firmwareSelectionError: String?

    private let worker = HidWorker()

    func log(_ line: String) {
        DispatchQueue.main.async {
            self.logLines.append(line)
            if self.logLines.count > 500 {
                self.logLines.removeFirst(self.logLines.count - 500)
            }
        }
    }

    func refreshInfo() {
        guard !isBusy else { return }
        isBusy = true
        lastErrorMessage = nil
        stage = .preparing
        log("Looking for Bolt receiver (runtime C548 or bootloader AB07) …")

        worker.run { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try self.readDeviceSnapshot()
                DispatchQueue.main.async {
                    self.apply(snapshot)
                    self.isBusy = false
                    self.stage = .idle
                }
            } catch {
                self.finishWithError(error, prefix: "Refresh failed")
            }
        }
    }

    func selectFirmwareFiles(_ urls: [URL]) {
        guard !isBusy else { return }
        do {
            let package = try SelectedFirmwarePackage.load(from: urls)
            selectedFirmwarePackage = package
            firmwareSelectionError = nil
            lastErrorMessage = nil
            log(
                "Selected Bolt DFU package: \(package.application.fileName) + "
                    + "\(package.secondary.fileName) (\(package.totalByteCount) bytes total)."
            )
        } catch {
            selectedFirmwarePackage = nil
            firmwareSelectionError = "\(error)"
            log("Firmware selection failed: \(error)")
        }
    }

    func clearFirmwareSelection() {
        guard !isBusy else { return }
        selectedFirmwarePackage = nil
        firmwareSelectionError = nil
    }

    func reportFirmwareSelectionError(_ error: Error) {
        guard !isBusy else { return }
        firmwareSelectionError = "\(error)"
        log("Firmware selection failed: \(error)")
    }

    func flashSelectedPackage() {
        guard !isBusy, let selectedFirmwarePackage else {
            firmwareSelectionError = "Select both Bolt .dfu files before starting the update."
            return
        }
        isBusy = true
        lastErrorMessage = nil
        firmwareSelectionError = nil
        progress = nil
        stage = .preparing

        worker.run { [weak self] in
            guard let self else { return }
            do {
                // Validate and load both files before changing device state.
                let images = selectedFirmwarePackage.images
                _ = try DfuFlasher.validatePackage(images)
                self.log(
                    "Validated selected application + radio DFU package format "
                        + "(\(images[0].count + images[1].count) bytes total)."
                )

                let bootloaderTransport: HidppTransport
                if BoltReceiverLocator.isPresent(productID: BoltReceiverLocator.bootloaderProductID) {
                    self.log("Receiver is already in AB07 bootloader mode; resuming update.")
                    bootloaderTransport = try BoltReceiverLocator.openBootloader(log: self.log).transport
                } else {
                    self.publishStage(.switchingToBootloader)
                    do {
                        let runtime = try BoltReceiverLocator.openRuntime(log: self.log)
                        defer { runtime.transport.close() }
                        let runtimeSession = Hidpp10BoltSession(transport: runtime.transport)
                        Thread.sleep(forTimeInterval: 0.2)
                        try runtimeSession.prepare()
                        self.log("Arming signed Bolt DFU through HID++ 1.0 register F5 with PRE magic.")
                        do {
                            try runtimeSession.armBootloader()
                        } catch let error as HidppError where error.mayIndicateBootloaderTransition {
                            self.log(
                                "C548 stopped responding during the DFU command; "
                                    + "checking whether it reappeared as AB07."
                            )
                        }
                    }

                    if let automaticallyOpened = try self.openBootloaderWhenAvailable(timeout: 5) {
                        self.log("Bootloader transition confirmed: AB07 is online. Continuing automatically.")
                        bootloaderTransport = automaticallyOpened
                    } else {
                        self.publishStage(.waitingForReplug)
                        self.log("AB07 is not online yet; unplug and reconnect the receiver now.")
                        bootloaderTransport = try self.waitForBootloader(timeout: 180)
                    }
                }

                defer { bootloaderTransport.close() }
                self.publishStage(.flashing)
                let bootloaderSession = Hidpp20Session(transport: bootloaderTransport)
                let version = try bootloaderSession.ping()
                guard version >= 2 else {
                    throw HidppError.notSupported("AB07 bootloader did not negotiate HID++ 2.0")
                }
                try DfuFlasher.flashPackage(
                    bootloaderSession,
                    images: images,
                    log: self.log,
                    onProgress: { progress in
                        DispatchQueue.main.async { self.progress = progress }
                    }
                )
                self.publishStage(.restarting)
                let snapshot = try self.waitForRuntimeAndReadInfo(timeout: 45)
                DispatchQueue.main.async {
                    self.apply(snapshot)
                    self.isBusy = false
                    self.progress = nil
                    self.stage = .completed
                    self.log("Update verified: runtime receiver C548 is available again.")
                }
            } catch {
                self.finishWithError(error, prefix: "FLASH FAILED")
            }
        }
    }

    private struct DeviceSnapshot {
        let product: String
        let entities: [FirmwareEntity]
        let isBootloader: Bool
    }

    private func readDeviceSnapshot() throws -> DeviceSnapshot {
        if BoltReceiverLocator.isPresent(productID: BoltReceiverLocator.bootloaderProductID) {
            let opened = try BoltReceiverLocator.openBootloader(log: log)
            defer { opened.transport.close() }
            let entities = try Hidpp20Session(transport: opened.transport).getFirmwareEntities()
            return DeviceSnapshot(product: opened.info.product, entities: entities, isBootloader: true)
        }

        let opened = try BoltReceiverLocator.openRuntime(log: log)
        defer { opened.transport.close() }
        let session = Hidpp10BoltSession(transport: opened.transport)
        var lastError: Error?
        for _ in 0..<5 {
            do {
                Thread.sleep(forTimeInterval: 0.2)
                try session.prepare()
                let entities = try session.getFirmwareEntities()
                return DeviceSnapshot(product: opened.info.product, entities: entities, isBootloader: false)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? HidppError.timeout("C548 did not answer firmware-information queries")
    }

    private func waitForBootloader(timeout: TimeInterval) throws -> HidppTransport {
        if let transport = try openBootloaderWhenAvailable(timeout: timeout) {
            return transport
        }
        throw HidppError.timeout("AB07 was not detected within \(Int(timeout)) seconds")
    }

    private func openBootloaderWhenAvailable(timeout: TimeInterval) throws -> HidppTransport? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastOpenError: Error?
        while Date() < deadline {
            if BoltReceiverLocator.isPresent(productID: BoltReceiverLocator.bootloaderProductID) {
                do {
                    let opened = try BoltReceiverLocator.openBootloader(log: log)
                    log("AB07 bootloader detected.")
                    return opened.transport
                } catch {
                    lastOpenError = error
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if BoltReceiverLocator.isPresent(productID: BoltReceiverLocator.bootloaderProductID),
           let lastOpenError {
            throw lastOpenError
        }
        return nil
    }

    private func waitForRuntimeAndReadInfo(timeout: TimeInterval) throws -> DeviceSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            if BoltReceiverLocator.isPresent(productID: BoltReceiverLocator.runtimeProductID) {
                do {
                    return try readDeviceSnapshot()
                } catch {
                    lastError = error
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw lastError ?? HidppError.timeout("C548 did not return after the bootloader restart")
    }

    private func publishStage(_ stage: UpdateStage) {
        DispatchQueue.main.async { self.stage = stage }
    }

    private func apply(_ snapshot: DeviceSnapshot) {
        deviceFound = true
        deviceProductString = snapshot.product
        entities = snapshot.entities
        isInBootloaderMode = snapshot.isBootloader
        log("Found '\(snapshot.product)' with \(snapshot.entities.count) firmware entities; bootloader=\(snapshot.isBootloader).")
    }

    private func finishWithError(_ error: Error, prefix: String) {
        DispatchQueue.main.async {
            self.isBusy = false
            self.progress = nil
            self.lastErrorMessage = "\(error)"
            self.stage = .failed
            self.log("\(prefix): \(error)")
        }
    }
}
