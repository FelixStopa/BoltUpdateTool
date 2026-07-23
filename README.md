<p align="center">
  <img src="BoltUpdateTool/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" width="128" height="128" alt="BoltUpdateTool app icon">
</p>

<h1 align="center">BoltUpdateTool</h1>

<p align="center">
  <strong>English</strong> · <a href="README.de.md">Deutsch</a>
</p>

<p align="center">
  An unofficial macOS and Windows firmware updater for the Logitech Bolt USB receiver.
</p>

> [!WARNING]
> This project is experimental and is not developed, reviewed, or supported by Logitech.
> An interrupted flash or an incompatible firmware package may render the receiver unusable.
> Use this tool at your own risk and, whenever possible, test it with a spare receiver first.

## Overview

BoltUpdateTool provides native applications for macOS (SwiftUI) and Windows (WPF/.NET). It
detects a Logitech Bolt receiver, reads its firmware information through HID++, and transfers a
signed firmware package selected by the user. Firmware is **not** included in this repository,
and neither application downloads it from the internet.

The application supports the complete update process:

1. Detect the Bolt receiver in runtime mode
2. Read the installed firmware components
3. Validate two selected DFU files
4. Switch the receiver into bootloader mode
5. Transfer the application and radio firmware
6. Restart the receiver and verify the installed version

The progress bar remains visible throughout flashing. If the automatic bootloader transition
is not detected immediately, the application provides clear instructions for unplugging and
reconnecting the receiver.

## Project status

- Hardware-tested with the Logitech Bolt USB Receiver
- Native applications for macOS and Windows
- Entirely local operation with no telemetry or network access
- Firmware must be selected manually
- No intentional firmware downgrade mode
- Windows ARM64 release available; x64 build is not yet published

Although the practical update process has been tested, the application should still be treated
as experimental. Other hardware or firmware revisions may behave differently.

## Supported hardware

| State | USB Vendor ID | USB Product ID | Protocol |
|---|---:|---:|---|
| Runtime | `046D` | `C548` | HID++ 1.0 |
| Bootloader | `046D` | `AB07` | HID++ 2.0 |

In runtime mode, the application uses the Logitech-specific HID interface with Usage Page
`FF00` and Usage `0001`. The receiver's other HID interfaces provide keyboard, mouse, and
consumer-control functions and are not suitable for firmware updates.

Other Logitech receivers, Unifying receivers, and devices with different IDs are not
supported.

## Requirements

To run the application:

- macOS 26.0 or later, or Windows 11 ARM64 with .NET 10 Desktop Runtime
- Logitech Bolt USB Receiver
- two matching, signed Bolt DFU files
- a stable, direct USB connection

To build the application:

- Xcode 26 or later
- Swift 5 Language Mode
- an Apple Developer team configured for macOS if the application will be signed or notarized
  for distribution
- .NET 10 SDK on Windows for the WPF application

The current macOS deployment target is macOS 26.0. The available Windows binary targets
Windows ARM64 and requires the .NET 10 Desktop Runtime.

## Downloads

| Platform | Download | Notes |
|---|---|---|
| macOS | [BoltUpdateTool 1.0.0](https://github.com/FelixStopa/BoltUpdateTool/releases/tag/v1.0.0) | Universal, Developer ID signed and notarized |
| Windows ARM64 | [BoltUpdateTool 1.0.0 for Windows ARM64](https://github.com/FelixStopa/BoltUpdateTool/releases/tag/windows-v1.0.0) | Framework-dependent, currently unsigned |

The Windows build is not Authenticode-signed. Windows SmartScreen may therefore display a
warning. Verify the SHA-256 checksum published with the release before running it.

## Selecting firmware

BoltUpdateTool expects **two unpacked `.dfu` files**, selected together in the file picker:

- the receiver application firmware
- the matching radio/secondary firmware

A ZIP archive cannot be selected directly. Extract the lawfully obtained firmware package
first, then select both DFU files at the same time.

The application validates, among other details:

- the file extension and a plausible file size
- the expected Bolt DFU identifier
- distinct and matching firmware entities
- a complete application and radio firmware pair

These checks reduce accidental incorrect selections, but they cannot guarantee that a package
is compatible with every hardware revision. Only use signed firmware obtained from a source
that you are authorized to use.

## Usage

1. Close applications that may access the receiver, such as Logi Options+.
2. Connect the Bolt receiver directly to the computer whenever possible.
3. Launch BoltUpdateTool.
4. Review the displayed firmware information.
5. Click **Change files** in the firmware section.
6. Select both matching `.dfu` files at the same time.
7. Review the detected version numbers.
8. Start the update with **Update receiver**.
9. Only unplug and reconnect the receiver when the application explicitly asks you to do so.
10. Wait for the final verification to complete successfully.

Do not disconnect USB or turn off the computer while firmware data is being written.

## Technical update flow

In runtime mode, the application communicates with the receiver through HID++ 1.0. It prepares
signed DFU mode through register `F5`. The device then reconnects with bootloader PID `AB07`.

In bootloader mode, BoltUpdateTool uses HID++ 2.0 and DFU feature `0x00D0`. The images are sent
in packets, acknowledged, and activated. The application then waits for runtime PID `C548` to
return and reads the firmware information again for verification.

```text
C548 Runtime
    │  HID++ 1.0 / prepare DFU
    ▼
AB07 Bootloader
    │  HID++ 2.0 / transfer firmware
    ▼
C548 Runtime
       read versions again
```

## Troubleshooting

### The receiver is not detected

- Unplug and reconnect the Bolt receiver
- Use a direct USB port instead of an unreliable hub
- Fully quit Logi Options+, Logitech Firmware Update Tool, and similar applications
- Search again with **Refresh info**
- Confirm that the connected device is a Bolt receiver with PID `C548`

### The application is waiting for the bootloader

The receiver may briefly disappear completely from the device list during the DFU command.
Follow the instructions shown by the application. If requested, unplug the receiver once and
reconnect it. The application will continue waiting for bootloader PID `AB07`.

### `IOHIDDeviceSetReport` fails

Common causes include a HID interface held by another application, an unsuitable USB hub, or
the device switching modes during the command. Close other Logitech applications, connect the
receiver directly, and try again.

This error does not automatically mean that the same firmware version is already installed.
When the selected version is identical, the application should explain that condition instead
of interpreting a transport error as a version comparison.

### `DFU packet 0 failed: unhandled status 0x27 (0xa7)`

The bootloader rejected the image at the first data packet. This can happen when the package is
incompatible, damaged, or not permitted. The signed bootloader may also reject firmware
downgrades. Repeating the same flash does not bypass this check.

### The file selection is rejected

Select exactly two unpacked `.dfu` files from the same firmware package at the same time. A
single file, two application images, or two secondary images do not form a valid package.

## Building from source

### macOS

Clone the repository and open the project:

```bash
git clone https://github.com/FelixStopa/BoltUpdateTool.git
cd BoltUpdateTool
open BoltUpdateTool.xcodeproj
```

Select the **BoltUpdateTool** scheme in Xcode and run the application. For a local development
build, select your own Development Team in the Signing settings.

Alternatively, create an unsigned test build from the command line:

```bash
xcodebuild \
  -project BoltUpdateTool.xcodeproj \
  -scheme BoltUpdateTool \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### Windows

On a Windows system with the .NET 10 SDK:

```powershell
cd BoltUpdateToolWin
dotnet restore BoltUpdateTool.Windows.sln
dotnet build BoltUpdateTool.Windows.sln --configuration Release
```

See [BoltUpdateToolWin/README.md](BoltUpdateToolWin/README.md) for Windows architecture,
publishing, and runtime details.

## Tests

The macOS unit tests primarily cover selection and classification of the two firmware files:

```bash
xcodebuild \
  -project BoltUpdateTool.xcodeproj \
  -scheme BoltUpdateTool \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:BoltUpdateToolTests \
  test
```

Run the Windows protocol and HID tests on Windows with:

```powershell
dotnet run --project BoltUpdateToolWin/tests/Bolt.Protocol.Tests
```

Unit tests are not a replacement for hardware testing. Changes to HID++, DFU packet handling,
timeouts, or device transitions should also be tested with a spare receiver.

## Project structure

```text
BoltUpdateTool/
├── BoltUpdateTool/                 SwiftUI application and state model
│   ├── HIDPP/                      HID++, device detection, and DFU
│   └── Assets.xcassets/            Application icon and colors
├── BoltUpdateToolTests/            Unit tests
├── BoltUpdateToolUITests/          UI test target
├── BoltUpdateTool.xcodeproj/       Xcode project
└── BoltUpdateToolWin/              Windows WPF/.NET solution and tests
```

Important components:

- `HIDDeviceManager`: detects runtime and bootloader interfaces
- `Hidpp10Session`: runtime communication and firmware information
- `Hidpp20Session`: bootloader feature discovery
- `DfuFlasher`: packet transfer and status handling
- `FirmwarePackage`: safe selection and validation of both DFU files
- `UpdaterViewModel`: coordinates detection, update flow, progress, and errors

## Privacy

BoltUpdateTool:

- sends no telemetry
- uses no user accounts
- does not download firmware
- does not transmit device information over the internet

Communication takes place locally between the application and the USB receiver. Links in the
interface are only opened when the user clicks them.

## Contributing

Reproducible bug reports and well-tested improvements are welcome. For hardware-related issues,
please include at least:

- operating-system version and computer architecture
- runtime or bootloader PID
- displayed firmware versions
- complete error text with private information removed
- whether a USB hub or adapter was used

Do not publish proprietary firmware or components of official Logitech applications in issues,
pull requests, or forks of this repository.

## Legal notice

Logitech, Logi, Bolt, and related trademarks belong to their respective owners. This project is
not affiliated with Logitech and is neither supported nor endorsed by Logitech.

This repository contains no Logitech firmware and no official Logitech applications. Protocol
behavior and constants were reconstructed through device analysis and publicly available
implementations. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for further information.

No software license has been selected for this project yet. Public availability of the source
code does not automatically grant permission to copy, modify, or redistribute it.

## Contact

Project and technical information: [felix.stopa.net](https://felix.stopa.net)
