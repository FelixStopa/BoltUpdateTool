# BoltUpdateTool for Windows

This directory contains the Windows implementation of BoltUpdateTool. It is a WPF application
written in C# and targets .NET 10.

The Windows application provides the same core update flow as the macOS version:

- detects Logitech Bolt runtime PID `046D:C548`
- communicates with the runtime through HID++ 1.0
- validates a matching application and radio/secondary DFU pair
- switches the receiver to bootloader PID `046D:AB07`
- flashes both signed images through HID++ 2.0 feature `0x00D0`
- waits for the runtime receiver to return and verifies its firmware information

Firmware is not included and is never downloaded by the application.

## Current binary releases

The current public Windows binaries are:

- version `1.0.0`
- framework-dependent
- not currently Authenticode-signed

| Architecture | Download | Required runtime |
|---|---|---|
| Windows ARM64 | [ZIP](https://github.com/FelixStopa/BoltUpdateTool/releases/download/windows-v1.0.0/BoltUpdateTool-1.0.0-Windows-arm64.zip) | [.NET 10 Desktop Runtime ARM64](https://dotnet.microsoft.com/download/dotnet/10.0) |
| Windows x86 (32-bit) | [ZIP](https://github.com/FelixStopa/BoltUpdateTool/releases/download/windows-v1.0.0/BoltUpdateTool-1.0.0-Windows-x86.zip) | [.NET 10 Desktop Runtime x86](https://dotnet.microsoft.com/download/dotnet/10.0) |

Because the executables are not yet Authenticode-signed, Windows SmartScreen may show a
warning. Verify the SHA-256 checksum provided with each release asset before starting the
application.

## Requirements

- a compatible Windows 10/11 installation
- .NET 10 SDK for development, or .NET 10 Desktop Runtime for the published binary
- Logitech Bolt USB Receiver
- two matching, unpacked, signed Bolt `.dfu` files
- a stable USB connection

The x86 download is a 32-bit application and can run on compatible x64 Windows installations
through Windows 32-bit compatibility. A native x64 download is not yet published, but can be
produced from the same source using runtime identifier `win-x64`.

## Build

Open `BoltUpdateTool.Windows.sln` in a compatible Visual Studio installation, or use the .NET
CLI on Windows:

```powershell
dotnet restore BoltUpdateTool.Windows.sln
dotnet build BoltUpdateTool.Windows.sln --configuration Release
```

Create a framework-dependent publish directory. Choose the required runtime identifier:

```powershell
dotnet publish src/BoltUpdateTool.Windows/BoltUpdateTool.Windows.csproj `
  --configuration Release `
  --runtime win-arm64 `
  --self-contained false `
  --output artifacts/BoltUpdateTool.Windows
```

- ARM64: `win-arm64`
- 32-bit x86: `win-x86`
- native 64-bit x64: `win-x64`

## Tests

The test executable covers package validation, HID++ message handling, DFU status handling, and
the expected two-entity transfer flow:

```powershell
dotnet run --project tests/Bolt.Protocol.Tests
```

When a receiver is connected, the same executable can run additional device diagnostics:

```powershell
dotnet run --project tests/Bolt.Protocol.Tests -- --device
```

Hardware diagnostics and firmware flashing should only be performed with a test receiver and a
stable USB connection.

## Structure

```text
BoltUpdateToolWin/
├── src/
│   ├── Bolt.Protocol/              HID++ and DFU protocol implementation
│   ├── Bolt.WindowsHid/            Windows HID discovery and transport
│   └── BoltUpdateTool.Windows/     WPF user interface
├── tests/Bolt.Protocol.Tests/      Protocol and optional device tests
├── BoltUpdateTool.Windows.sln      Visual Studio solution
└── Directory.Build.props           Shared .NET build settings
```

Build output, debug symbols, firmware, and local development files are intentionally excluded
from the source repository.
