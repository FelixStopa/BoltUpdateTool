//
//  BoltUpdateToolTests.swift
//  BoltUpdateToolTests
//
//  Created by Felix Stopa on 22.07.26.
//

import Testing
import Foundation
@testable import BoltUpdateTool

struct BoltUpdateToolTests {

    @Test func hidpp10DfuCommandHasNoSoftwareID() {
        let message = HidppMsg(
            reportID: .long,
            deviceID: DeviceIdx.receiver,
            subID: 0x82,
            functionID: 0xF5,
            data: [0x01, 0, 0, 0] + Array("PRE".utf8)
        )
        #expect(
            Array(message.pack().prefix(11))
                == [0x11, 0xFF, 0x82, 0xF5, 0x01, 0, 0, 0, 0x50, 0x52, 0x45]
        )
    }

    @Test func boltPackageRequiresBothEntities() throws {
        #expect(try DfuFlasher.validatePackage([[0x02, 0xAA], [0x01, 0xBB]]) == 0x02)
        #expect(throws: HidppError.self) {
            try DfuFlasher.validatePackage([[0x02, 0xAA]])
        }
    }

    @Test func disappearingRuntimeCanBeVerifiedAsBootloaderTransition() {
        let notResponding = HidppError.setReportFailed(code: Int32(bitPattern: 0xE000_02ED))
        let noDevice = HidppError.setReportFailed(code: Int32(bitPattern: 0xE000_02C0))
        let ordinaryFailure = HidppError.setReportFailed(code: Int32(bitPattern: 0xE000_02BC))

        #expect(notResponding.mayIndicateBootloaderTransition)
        #expect(noDevice.mayIndicateBootloaderTransition)
        #expect(!ordinaryFailure.mayIndicateBootloaderTransition)
    }

    @Test func selectedPackageIdentifiesFilesRegardlessOfSelectionOrder() throws {
        let marker = Array("MPR05_D0".utf8)
        let application = Data([0x02, 0x01] + marker + Array(repeating: 0, count: 32))
        let secondary = Data([0x01, 0x03] + marker + Array(repeating: 0, count: 32))

        let package = try SelectedFirmwarePackage.make(files: [
            ("bolt_receiver_C548_secondary_00.00_B013E.dfu", secondary),
            ("bolt_receiver_C548_app_MPR05.03_B0020.dfu", application),
        ])

        #expect(package.application.versionLabel == "MPR05.03_B0020")
        #expect(package.secondary.versionLabel == "00.00_B013E")
        #expect(package.images.map(\.first) == [0x02, 0x01])
    }

    @Test func selectedPackageRejectsNonBoltImages() {
        let wrongMarker = Data([0x02, 0x01] + Array("NOTBOLT!".utf8) + Array(repeating: 0, count: 32))
        let marker = Array("MPR05_D0".utf8)
        let secondary = Data([0x01, 0x03] + marker + Array(repeating: 0, count: 32))

        #expect(throws: HidppError.self) {
            try SelectedFirmwarePackage.make(files: [
                ("application.dfu", wrongMarker),
                ("secondary.dfu", secondary),
            ])
        }
    }

}
