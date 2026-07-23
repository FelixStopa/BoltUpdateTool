import Foundation

/// Feature IDs, matching both the C++ class names embedded in the official
/// FirmwareUpdateTool binary (Feature0000Root, Feature0001FeatureSet,
/// Feature0003FirmwareInfo, Feature00c1/c2/c3DFUControl, Feature00d0DFU)
/// and fwupd's `FuLogitechHidppFeature` enum
/// (plugins/logitech-hidpp/fu-logitech-hidpp.rs).
enum Feature {
    static let root: UInt16 = 0x0000
    static let featureSet: UInt16 = 0x0001
    static let firmwareInfo: UInt16 = 0x0003
    static let dfuControl: UInt16 = 0x00C1
    static let dfuControlSigned: UInt16 = 0x00C2
    static let dfuControlBolt: UInt16 = 0x00C3
    static let dfu: UInt16 = 0x00D0
    static let rdfu: UInt16 = 0x00D1
}

struct FirmwareEntity: Identifiable {
    var id: Int { index }
    let index: Int
    let kind: UInt8 // 0 = application, 1 = bootloader, 2 = hardware
    let name: String // 3-char prefix, e.g. "MPR"
    let major: UInt8
    let minor: UInt8
    let build: UInt16
    let active: Bool

    var versionString: String {
        String(format: "%@%02x.%02x_B%04x", name, major, minor, build)
    }

    var kindDescription: String {
        switch kind {
        case 0: return "application"
        case 1: return "bootloader"
        case 2: return "hardware"
        default: return "kind \(kind)"
        }
    }
}

final class Hidpp20Session {
    let transport: HidppTransport
    let deviceID: UInt8
    private var featureCache: [UInt16: UInt8] = [:]

    init(transport: HidppTransport, deviceID: UInt8 = DeviceIdx.receiver) {
        self.transport = transport
        self.deviceID = deviceID
    }

    private func shortMsg(subID: UInt8, function: UInt8, data: [UInt8] = []) -> HidppMsg {
        HidppMsg(reportID: .short, deviceID: deviceID, subID: subID, functionID: function << 4, data: data)
    }

    /// HID++ ping; returns the protocol major version (2 for HID++2.0
    /// devices, 1 for legacy/register-protocol-only endpoints).
    ///
    /// A HID++1.0 ERR_INVALID_SUBID (code 0x01) reply to this HID++2.0-style
    /// ping is *not* a failure -- it's the documented way a HID++1.0-only
    /// endpoint says "I don't understand feature-index addressing". Linux's
    /// kernel driver (`hidpp_root_get_protocol_version` in
    /// hid-logitech-hidpp.c) special-cases exactly this and reports protocol
    /// 1.0 rather than erroring out; this mirrors that.
    @discardableResult
    func ping() throws -> UInt8 {
        let req = shortMsg(subID: 0x00, function: 0x01, data: [0x00, 0x00, 0xAA])
        do {
            let rsp = try transport.transfer(req, ignoreFunctionID: true)
            return rsp.data.first ?? 0
        } catch HidppError.remoteError(let isHidpp1, let code, _, _) where isHidpp1 && code == 0x01 {
            return 1
        }
    }

    /// Root.GetFeature(featureID) -> feature index used as sub_id for later calls.
    func featureIndex(_ featureID: UInt16) throws -> UInt8 {
        if let cached = featureCache[featureID] { return cached }
        let data: [UInt8] = [UInt8(featureID >> 8), UInt8(featureID & 0xFF), 0x00]
        let req = shortMsg(subID: 0x00, function: 0x00, data: data) // feature 0 (Root), function 0 = getFeature
        let rsp = try transport.transfer(req)
        let idx = rsp.data.first ?? 0
        featureCache[featureID] = idx
        return idx
    }

    func getFirmwareEntities() throws -> [FirmwareEntity] {
        let idx = try featureIndex(Feature.firmwareInfo)
        guard idx != 0 else {
            throw HidppError.notSupported("device does not expose feature 0x0003 (FirmwareInfo)")
        }

        let countReq = shortMsg(subID: idx, function: 0x00) // getCount
        let countRsp = try transport.transfer(countReq)
        let count = Int(countRsp.data.first ?? 0)

        var entities: [FirmwareEntity] = []
        for i in 0..<count {
            let req = shortMsg(subID: idx, function: 0x01, data: [UInt8(i)]) // getInfo(entityIdx)
            let rsp = try transport.transfer(req, ignoreFunctionID: true)
            let d = rsp.data
            guard d.count >= 8 else { continue }
            let kind = d[0]
            let name = String(bytes: d[1..<4].filter { $0 >= 32 && $0 < 127 }, encoding: .ascii) ?? ""
            let major = d[4], minor = d[5]
            let build = (UInt16(d[6]) << 8) | UInt16(d[7])
            let active = d.count > 8 ? (d[8] & 0x01) != 0 : true
            entities.append(FirmwareEntity(index: i, kind: kind, name: name, major: major, minor: minor, build: build, active: active))
        }
        return entities
    }
}
