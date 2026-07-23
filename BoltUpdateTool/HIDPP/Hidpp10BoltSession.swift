import Foundation

/// HID++ 1.0 register protocol used by a Bolt receiver while PID C548 is
/// running its normal application firmware.
final class Hidpp10BoltSession {
    private enum SubID {
        static let setLongRegister: UInt8 = 0x82
        static let getLongRegister: UInt8 = 0x83
    }

    private enum Register {
        static let pairingInformation: UInt8 = 0xB5
        static let receiverFirmwareInformation: UInt8 = 0xF4
        static let dfuControl: UInt8 = 0xF5
    }

    let transport: HidppTransport

    init(transport: HidppTransport) {
        self.transport = transport
    }

    /// Mirrors the setup query used by Logitech/fwupd. The response also
    /// carries the pairing-slot count, which is not needed by this updater.
    func prepare() throws {
        let request = HidppMsg(
            reportID: .short,
            deviceID: DeviceIdx.receiver,
            subID: SubID.getLongRegister,
            functionID: Register.pairingInformation,
            data: [0x02]
        )
        _ = try transport.transfer(request, hidppVersion: 1)
    }

    func getFirmwareEntities() throws -> [FirmwareEntity] {
        var entities: [FirmwareEntity] = []
        for index in 0..<3 {
            let request = HidppMsg(
                reportID: .short,
                deviceID: DeviceIdx.receiver,
                subID: SubID.getLongRegister,
                functionID: Register.receiverFirmwareInformation,
                data: [UInt8(index)]
            )
            let response = try transport.transfer(request, hidppVersion: 1)
            let data = response.data
            guard data.count >= 5 else {
                throw HidppError.malformed("short C548 firmware-information response")
            }

            let kind = data[0]
            guard kind <= 2 else { continue }
            let name: String
            switch kind {
            case 0: name = "MPR"
            case 1: name = "BOT"
            default: name = "HW"
            }
            entities.append(
                FirmwareEntity(
                    index: index,
                    kind: kind,
                    name: name,
                    major: data[1],
                    minor: data[2],
                    build: (UInt16(data[3]) << 8) | UInt16(data[4]),
                    active: true
                )
            )
        }
        return entities
    }

    /// Arms signed DFU for a Bolt receiver. The receiver intentionally does
    /// not reboot immediately; Logitech requires a physical remove/replug.
    func armBootloader() throws {
        let request = HidppMsg(
            reportID: .long,
            deviceID: DeviceIdx.receiver,
            subID: SubID.setLongRegister,
            functionID: Register.dfuControl,
            data: [0x01, 0x00, 0x00, 0x00] + Array("PRE".utf8)
        )
        var mutableRequest = request
        try transport.send(&mutableRequest, hidppVersion: 1)
    }
}
