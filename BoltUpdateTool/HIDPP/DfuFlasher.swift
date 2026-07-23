import Foundation

/// DFU control + firmware transfer for Logitech receivers, reimplemented from
/// fwupd's LGPL-2.1+ logitech-hidpp plugin (fu-logitech-hidpp-device.c):
///
/// The C548 runtime is armed separately through its HID++ 1.0 registers. Once
/// replugged as the AB07 bootloader, the device exposes feature 0x00D0 ("DFU").
/// Both Bolt firmware entities are then transferred as one package.
///
/// 1. The whole firmware image is split into 16-byte chunks and streamed
///    through that feature using a 4-command sliding window:
///
///        first chunk : cmd = 4          (dfuStart)
///        then        : cmd cycles 1,2,3,0,1,2,3,0, ...
///
///    Each LONG report reply carries a 4-byte packet counter followed by a
///    status byte. The device itself validates/erases/programs flash as it
///    receives data -- the host is a dumb relay, it does not need to
///    understand Logitech's internal firmware container format.
/// 2. After both images, function 5 activates the application entity and
///    restarts the receiver.
///
/// THIS CAN BRICK YOUR RECEIVER IF INTERRUPTED OR IF THE WRONG FILE IS SENT.
/// Read the app's in-UI warnings before pressing Flash.

/// Status byte -> (isSuccess, isRetryable, description).
/// Numeric values taken verbatim from fwupd's `FuLogitechHidppStatus` enum
/// (plugins/logitech-hidpp/fu-logitech-hidpp.rs) -- an earlier draft of the
/// Python prototype this was ported from had *invented* values here and was
/// corrected against that source; this table already reflects the fix.
struct DfuStatus {
    let isSuccess: Bool
    let isRetryable: Bool
    let description: String
}

let dfuStatusTable: [UInt8: DfuStatus] = [
    0x00: .init(isSuccess: false, isRetryable: false, description: "invalid"),
    0x01: .init(isSuccess: true, isRetryable: false, description: "packet success"),
    0x02: .init(isSuccess: true, isRetryable: false, description: "DFU success"),
    0x03: .init(isSuccess: false, isRetryable: true, description: "wait for event"),
    0x04: .init(isSuccess: false, isRetryable: false, description: "generic error 04"),
    0x05: .init(isSuccess: true, isRetryable: false, description: "DFU success, entity restart required"),
    0x06: .init(isSuccess: true, isRetryable: false, description: "DFU success, system restart required"),
    0x10: .init(isSuccess: false, isRetryable: false, description: "generic error 10"),
    0x11: .init(isSuccess: false, isRetryable: false, description: "bad voltage"),
    0x12: .init(isSuccess: false, isRetryable: false, description: "unknown status 0x12"),
    0x13: .init(isSuccess: false, isRetryable: false, description: "unsupported encryption mode"),
    0x14: .init(isSuccess: false, isRetryable: false, description: "bad magic string"),
    0x15: .init(isSuccess: false, isRetryable: false, description: "erase failure"),
    0x16: .init(isSuccess: false, isRetryable: false, description: "DFU not started"),
    0x17: .init(isSuccess: false, isRetryable: false, description: "bad sequence number"),
    0x18: .init(isSuccess: false, isRetryable: false, description: "unsupported command"),
    0x19: .init(isSuccess: false, isRetryable: true, description: "command in progress"),
    0x1A: .init(isSuccess: false, isRetryable: false, description: "address out of range"),
    0x1B: .init(isSuccess: false, isRetryable: false, description: "unaligned address"),
    0x1C: .init(isSuccess: false, isRetryable: false, description: "bad size"),
    0x1D: .init(isSuccess: false, isRetryable: false, description: "missing program data"),
    0x1E: .init(isSuccess: false, isRetryable: false, description: "missing check data"),
    0x1F: .init(isSuccess: false, isRetryable: false, description: "program failed to write"),
    0x20: .init(isSuccess: false, isRetryable: false, description: "program failed to verify"),
    0x21: .init(isSuccess: false, isRetryable: false, description: "bad firmware"),
    0x22: .init(isSuccess: false, isRetryable: false, description: "firmware check failure"),
    0x23: .init(isSuccess: false, isRetryable: true, description: "blocked command"),
]

func describeDfuStatus(_ code: UInt8) -> DfuStatus {
    let masked = code & 0x7F
    return dfuStatusTable[masked] ?? DfuStatus(isSuccess: false, isRetryable: false, description: "unhandled status 0x\(String(masked, radix: 16))")
}

struct FlashProgress {
    let packetIndex: Int
    let packetCount: Int
}

enum DfuFlasher {
    static func validatePackage(_ images: [[UInt8]]) throws -> UInt8 {
        guard images.count == 2, images.allSatisfy({ !$0.isEmpty }) else {
            throw HidppError.malformed("a Bolt update requires exactly two non-empty DFU images")
        }
        let entityIDs = Set(images.compactMap(\.first))
        guard entityIDs == Set([0x01, 0x02]) else {
            throw HidppError.malformed(
                "expected Bolt DFU entity IDs 0x01 and 0x02, got "
                    + entityIDs.sorted().map { String(format: "0x%02x", $0) }.joined(separator: ", ")
            )
        }
        return 0x02 // application entity to activate after both images are written
    }

    static func flashPackage(
        _ session: Hidpp20Session,
        images: [[UInt8]],
        chunkSize: Int = 16,
        log: (String) -> Void,
        onProgress: (FlashProgress) -> Void
    ) throws {
        let applicationEntity = try validatePackage(images)
        let idx = try session.featureIndex(Feature.dfu)
        guard idx != 0 else {
            throw HidppError.notSupported("device is not in bootloader mode (no feature 0x00D0)")
        }

        let total = images.reduce(0) { $0 + Int(ceil(Double($1.count) / Double(chunkSize))) }
        var completed = 0

        for image in images {
            let entity = image[0]
            log("flashing DFU entity 0x\(String(format: "%02x", entity)) (\(image.count) bytes)")
            var cmd: UInt8 = 0x04
            var offset = 0
            while offset < image.count {
                let end = min(offset + chunkSize, image.count)
                let chunk = Array(image[offset..<end])
                let req = HidppMsg(reportID: .long, deviceID: session.deviceID, subID: idx, functionID: cmd << 4, data: chunk)
                let response = try session.transport.transfer(req, timeoutMs: 8000)
                try acceptStatus(response, request: req, transport: session.transport, log: log)
                cmd = (cmd + 1) % 4
                offset = end
                completed += 1
                onProgress(FlashProgress(packetIndex: completed, packetCount: total))
            }
        }

        log("both DFU entities transferred; requesting application restart")
        var restart = HidppMsg(
            reportID: .long,
            deviceID: session.deviceID,
            subID: idx,
            functionID: 0x05 << 4,
            data: [applicationEntity]
        )
        do {
            try session.transport.send(&restart)
        } catch {
            // A fast reset can remove the HID endpoint before macOS completes
            // SetReport. The caller verifies that C548 returns, which is the
            // authoritative result of this command.
            log("restart command ended while the USB device was resetting: \(error)")
        }
    }

    private static func acceptStatus(
        _ initialResponse: HidppMsg,
        request: HidppMsg,
        transport: HidppTransport,
        log: (String) -> Void
    ) throws {
        var response = initialResponse
        for eventAttempt in 0...10 {
            let data = response.data
            let packetCount = data.count >= 4
                ? (UInt32(data[0]) << 24) | (UInt32(data[1]) << 16) | (UInt32(data[2]) << 8) | UInt32(data[3])
                : 0
            let statusByte = data.count > 4 ? data[4] : 0
            let status = describeDfuStatus(statusByte)
            if status.isSuccess { return }
            guard status.isRetryable, eventAttempt < 10 else {
                throw HidppError.deviceError(
                    "DFU packet \(packetCount) failed: \(status.description) (0x\(String(format: "%02x", statusByte)))"
                )
            }

            log("DFU packet \(packetCount): \(status.description); waiting for completion event")
            while true {
                let event = try transport.receive(timeoutMs: 15_000)
                if hidppIsReply(request, event, ignoreFunctionID: true) {
                    response = event
                    break
                }
            }
        }
    }
}
