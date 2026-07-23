import Foundation
import IOKit.hid

enum BoltReceiverLocator {
    static let runtimeProductID = 0xC548
    static let bootloaderProductID = 0xAB07
    static let runtimeUsagePage = 0xFF00
    static let runtimeUsage = 0x0001

    /// The C548 runtime receiver deliberately uses the HID++ 1.0 register
    /// protocol. Its vendor collection is unambiguous on macOS; probing the
    /// keyboard/mouse collections only produces USB pipe stalls.
    static func openRuntime(
        log: (String) -> Void = { _ in }
    ) throws -> (transport: HidppTransport, info: HidDeviceInfo) {
        let candidates = HidEnumeration.listLogitechDevices().filter {
            $0.productID == runtimeProductID
                && $0.usagePage == runtimeUsagePage
                && $0.usage == runtimeUsage
        }
        guard let info = candidates.first else {
            throw HidppError.deviceError(
                "No Bolt runtime interface 046D:C548 FF00:0001 found"
            )
        }

        let transport = HidppTransport(device: info.device)
        try transport.open()
        log("opened Bolt runtime interface FF00:0001 using HID++ 1.0")
        return (transport, info)
    }

    /// The Bolt bootloader re-enumerates as PID AB07 and speaks HID++ 2.0.
    /// Firmware revisions can expose different primary usages, so validate
    /// candidates with a real HID++ 2.0 ping.
    static func openBootloader(
        log: (String) -> Void = { _ in }
    ) throws -> (transport: HidppTransport, info: HidDeviceInfo) {
        let candidates = HidEnumeration.listLogitechDevices().filter {
            $0.productID == bootloaderProductID
        }
        guard !candidates.isEmpty else {
            throw HidppError.deviceError(
                "No Bolt bootloader interface 046D:AB07 found"
            )
        }

        log("found \(candidates.count) interface(s) for bootloader PID AB07: "
            + candidates.map { "usagePage=0x\(String(format: "%04x", $0.usagePage)) usage=0x\(String(format: "%02x", $0.usage))" }.joined(separator: ", "))

        var attempts: [String] = []
        for info in candidates {
            let tag = "usagePage=0x\(String(format: "%04x", info.usagePage)) usage=0x\(String(format: "%02x", info.usage))"
            let transport = HidppTransport(device: info.device)
            do {
                try transport.open()
                let version = try Hidpp20Session(transport: transport).ping()
                guard version >= 2 else {
                    throw HidppError.notSupported("only speaks HID++\(version).0, not HID++2.0")
                }
                log("\(tag): OK, using this interface")
                return (transport, info)
            } catch {
                transport.close()
                log("\(tag): failed -- \(error)")
                attempts.append("[\(tag)] \(error)")
                continue
            }
        }
        throw HidppError.deviceError(
            "none of \(candidates.count) AB07 interface(s) responded to a HID++2.0 ping:\n"
            + attempts.joined(separator: "\n")
        )
    }

    static func isPresent(productID: Int) -> Bool {
        HidEnumeration.listLogitechDevices().contains { $0.productID == productID }
    }
}
