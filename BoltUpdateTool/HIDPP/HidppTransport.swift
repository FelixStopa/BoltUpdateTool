import Foundation
import IOKit
import IOKit.hid

let logitechVendorID: Int = 0x046D
let boltReceiverProductID: Int = 0xC548

struct HidDeviceInfo {
    let device: IOHIDDevice
    let vendorID: Int
    let productID: Int
    let usagePage: Int
    let usage: Int
    let product: String
}

enum HidEnumeration {
    /// Enumerate every Logitech HID device/interface currently visible.
    static func listLogitechDevices() -> [HidDeviceInfo] {
        guard let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone)) as IOHIDManager? else {
            return []
        }
        let matching: [String: Any] = [kIOHIDVendorIDKey as String: logitechVendorID]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }

        return deviceSet.map { dev in
            let vid = (IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
            let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            let up = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
            let us = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
            let product = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? ""
            return HidDeviceInfo(device: dev, vendorID: vid, productID: pid, usagePage: up, usage: us, product: product)
        }
    }

    static func boltReceivers() -> [HidDeviceInfo] {
        listLogitechDevices().filter { $0.productID == boltReceiverProductID }
    }
}

/// Sends/receives HID++ reports over a single opened IOHIDDevice, using the
/// exact convention hidapi's macOS backend uses (buffer passed to
/// IOHIDDeviceSetReport / delivered by the input-report callback includes
/// the leading report-id byte).
final class HidppTransport {
    private let device: IOHIDDevice
    private var pendingReports: [[UInt8]] = []
    private let lock = NSLock()
    private var opened = false

    init(device: IOHIDDevice) {
        self.device = device
    }

    func open() throws {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw HidppError.deviceError("IOHIDDeviceOpen failed: \(result)")
        }
        opened = true

        let bufferSize = 64
        reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        reportBuffer?.initialize(repeating: 0, count: bufferSize)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, reportBuffer!, bufferSize,
            { context, result, sender, type, reportID, report, reportLength in
                guard let context = context else { return }
                let me = Unmanaged<HidppTransport>.fromOpaque(context).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
                me.appendReport(bytes)
            },
            context
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    private var reportBuffer: UnsafeMutablePointer<UInt8>?

    func close() {
        guard opened else { return }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        reportBuffer?.deallocate()
        reportBuffer = nil
        opened = false
    }

    deinit { close() }

    private func appendReport(_ bytes: [UInt8]) {
        lock.lock()
        pendingReports.append(bytes)
        lock.unlock()
    }

    private func popReport() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        if pendingReports.isEmpty { return nil }
        return pendingReports.removeFirst()
    }

    func send(_ msg: inout HidppMsg, hidppVersion: Int = 2) throws {
        if hidppVersion >= 2 {
            msg.functionID |= hidppMsgSoftwareID
        }
        let payload = msg.pack()
        let reportID = CFIndex(payload[0])
        // Matches hidapi's macOS `set_report()` exactly: for *numbered*
        // reports (report_id != 0, which is always true for us -- 0x10/0x11)
        // hidapi passes the report-id byte both as the separate `reportID`
        // parameter AND still as the first byte of the buffer. Only when
        // report_id == 0 (unnumbered reports) does it strip that byte.
        // (A prior attempt to always strip it was wrong and reproduced the
        // same pipe-stall error -- reverted.)
        let outputResult = payload.withUnsafeBufferPointer { buf -> IOReturn in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, buf.baseAddress!, buf.count)
        }
        if outputResult == kIOReturnSuccess {
            return
        }
        throw HidppError.setReportFailed(code: outputResult)
    }

    /// Pumps the current run loop until a report arrives or the timeout elapses.
    func receive(timeoutMs: Int) throws -> HidppMsg {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if let bytes = popReport() {
                return try HidppMsg.unpack(bytes)
            }
            // Run the loop briefly so the input-report callback can fire.
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
        }
        throw HidppError.timeout("no reply within \(timeoutMs)ms")
    }

    /// Send `msg` and wait for a matching reply, retrying against unrelated
    /// traffic (notifications, replies to other software) up to `retries` times.
    @discardableResult
    func transfer(
        _ msg: HidppMsg,
        ignoreSubID: Bool = false,
        ignoreFunctionID: Bool = false,
        retries: Int = 10,
        timeoutMs: Int = 4000,
        hidppVersion: Int = 2
    ) throws -> HidppMsg {
        var req = msg
        try send(&req, hidppVersion: hidppVersion)
        for _ in 0..<retries {
            let rsp = try receive(timeoutMs: timeoutMs)
            if rsp.subID == subIdErrorMsg || rsp.subID == subIdErrorMsg20 {
                let code = rsp.data.count > 1 ? rsp.data[1] : 0xFF
                throw HidppError.remoteError(
                    isHidpp1: rsp.subID == subIdErrorMsg,
                    code: code,
                    requestSubID: req.subID,
                    requestFunction: req.function
                )
            }
            if hidppIsReply(req, rsp, ignoreSubID: ignoreSubID, ignoreFunctionID: ignoreFunctionID) {
                return rsp
            }
            // not our reply -- keep waiting for the real one
        }
        throw HidppError.timeout("too many unrelated messages, giving up")
    }
}
