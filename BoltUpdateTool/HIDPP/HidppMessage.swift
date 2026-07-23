import Foundation

/// HID++ 2.0 message framing for Logitech Bolt receivers.
///
/// Reverse-engineered from strings embedded in the official macOS
/// "Logitech Firmware Update Tool" (com.logitech.FirmwareUpdateTool) and
/// cross-checked byte-for-byte against fwupd's open-source (LGPL-2.1+)
/// `logitech-hidpp` plugin, which implements and ships this exact protocol
/// in production (github.com/fwupd/fwupd/tree/main/plugins/logitech-hidpp).
///
/// Report layout:
///   SHORT report (7 bytes on the wire):
///     [0] report_id   = 0x10
///     [1] device_id   (0xFF = the receiver itself)
///     [2] sub_id      (a.k.a. feature index)
///     [3] function_id (upper nibble = function number, lower nibble = software id)
///     [4..7) data (3 bytes)
///
///   LONG report (20 bytes on the wire):
///     [0] report_id   = 0x11
///     [1] device_id
///     [2] sub_id
///     [3] function_id
///     [4..20) data (16 bytes)

enum HidppReportID: UInt8 {
    case short = 0x10
    case long = 0x11

    var totalLength: Int {
        switch self {
        case .short: return 7
        case .long: return 20
        }
    }

    var dataLength: Int {
        totalLength - 4
    }
}

enum DeviceIdx {
    static let wired: UInt8 = 0x00
    /// The receiver dongle itself (as opposed to a paired peripheral).
    static let receiver: UInt8 = 0xFF
}

/// Lower nibble of function_id must carry this "software id" for HID++ 2.0
/// so replies can be told apart from other software talking to the device.
let hidppMsgSoftwareID: UInt8 = 0x0A

let subIdErrorMsg: UInt8 = 0x8F
let subIdErrorMsg20: UInt8 = 0xFF

struct HidppMsg {
    var reportID: HidppReportID
    var deviceID: UInt8
    var subID: UInt8
    var functionID: UInt8
    var data: [UInt8]

    init(reportID: HidppReportID, deviceID: UInt8, subID: UInt8, functionID: UInt8, data: [UInt8] = []) {
        self.reportID = reportID
        self.deviceID = deviceID
        self.subID = subID
        self.functionID = functionID
        self.data = data
    }

    /// Full wire bytes, including the leading report-id byte.
    func pack() -> [UInt8] {
        var d = data
        if d.count < reportID.dataLength {
            d.append(contentsOf: repeatElement(0, count: reportID.dataLength - d.count))
        } else if d.count > reportID.dataLength {
            d = Array(d.prefix(reportID.dataLength))
        }
        return [reportID.rawValue, deviceID, subID, functionID] + d
    }

    static func unpack(_ buf: [UInt8]) throws -> HidppMsg {
        guard buf.count >= 4, let rid = HidppReportID(rawValue: buf[0]) else {
            throw HidppError.malformed("short or unrecognized report (\(buf.count) bytes, id \(buf.first.map { String(format: "0x%02x", $0) } ?? "nil"))")
        }
        let data = Array(buf.dropFirst(4))
        return HidppMsg(reportID: rid, deviceID: buf[1], subID: buf[2], functionID: buf[3], data: data)
    }

    var function: UInt8 { (functionID >> 4) & 0x0F }
    var swid: UInt8 { functionID & 0x0F }
}

enum HidppError: Error, CustomStringConvertible {
    case malformed(String)
    case timeout(String)
    case deviceError(String)
    case setReportFailed(code: Int32)
    case notSupported(String)
    /// A well-formed HID++ error reply (sub_id 0x8F for HID++1.0, 0xFF for
    /// HID++2.0). Kept structured (rather than folded into `deviceError`)
    /// because callers like `ping()` need to pattern-match specific codes --
    /// e.g. HID++1.0's ERR_INVALID_SUBID (0x01) in reply to a HID++2.0-style
    /// ping is a normal, documented "this endpoint only speaks HID++1.0"
    /// signal (see Linux's hid-logitech-hidpp.c `hidpp_root_get_protocol_version`),
    /// not a fatal error.
    case remoteError(isHidpp1: Bool, code: UInt8, requestSubID: UInt8, requestFunction: UInt8)

    var description: String {
        switch self {
        case .malformed(let s): return "malformed HID++ message: \(s)"
        case .timeout(let s): return "timeout: \(s)"
        case .deviceError(let s): return "device error: \(s)"
        case .setReportFailed(let code):
            let hex = String(format: "0x%08x", UInt32(bitPattern: code))
            return "device error: IOHIDDeviceSetReport(Output) failed: \(code) (\(hex))"
        case .notSupported(let s): return "not supported: \(s)"
        case .remoteError(let isHidpp1, let code, let subID, let function):
            let kind = isHidpp1 ? "HID++1.0" : "HID++2.0"
            return "device error: \(kind) error 0x\(String(format: "%02x", code)) "
                + "replying to subID 0x\(String(format: "%02x", subID)) "
                + "function 0x\(String(format: "%02x", function))"
        }
    }

    /// A Bolt receiver may leave the C548 HID endpoint while macOS is still
    /// completing the F5 SetReport call. These errors are only non-fatal when
    /// the caller subsequently confirms that PID AB07 actually appeared.
    var mayIndicateBootloaderTransition: Bool {
        guard case .setReportFailed(let code) = self else { return false }
        return code == Int32(bitPattern: 0xE000_02C0) // kIOReturnNoDevice
            || code == Int32(bitPattern: 0xE000_02ED) // kIOReturnNotResponding
    }
}

func hidppIsReply(_ req: HidppMsg, _ rsp: HidppMsg, ignoreSubID: Bool = false, ignoreFunctionID: Bool = false) -> Bool {
    if req.deviceID != rsp.deviceID && req.deviceID != DeviceIdx.wired && rsp.deviceID != DeviceIdx.wired {
        return false
    }
    if !ignoreSubID && req.subID != rsp.subID {
        return false
    }
    if !ignoreFunctionID && req.functionID != rsp.functionID {
        return false
    }
    return true
}
