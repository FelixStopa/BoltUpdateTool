import Foundation

struct FirmwareImage {
    enum Kind {
        case application
        case secondary

        var title: String {
            switch self {
            case .application: "Application"
            case .secondary: "Radio / secondary"
            }
        }
    }

    let kind: Kind
    let fileName: String
    let data: Data

    var versionLabel: String {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let separator = kind == .application ? "_app_" : "_secondary_"
        guard let range = stem.range(of: separator, options: .caseInsensitive) else {
            return "Version from selected file"
        }
        return String(stem[range.upperBound...])
    }
}

struct SelectedFirmwarePackage {
    let application: FirmwareImage
    let secondary: FirmwareImage

    var images: [[UInt8]] {
        [application, secondary].map { [UInt8]($0.data) }
    }

    var totalByteCount: Int {
        application.data.count + secondary.data.count
    }

    static func load(from urls: [URL]) throws -> SelectedFirmwarePackage {
        guard urls.count == 2 else {
            throw HidppError.malformed("select exactly two unpacked .dfu files")
        }

        let files = try urls.map { url -> (name: String, data: Data) in
            guard url.pathExtension.lowercased() == "dfu" else {
                throw HidppError.malformed("\(url.lastPathComponent) is not a .dfu file")
            }

            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return (url.lastPathComponent, data)
        }
        return try make(files: files)
    }

    static func make(files: [(name: String, data: Data)]) throws -> SelectedFirmwarePackage {
        guard files.count == 2 else {
            throw HidppError.malformed("a Bolt update requires exactly two DFU files")
        }

        let maximumFileSize = 16 * 1024 * 1024
        var application: FirmwareImage?
        var secondary: FirmwareImage?

        for file in files {
            guard file.name.lowercased().hasSuffix(".dfu") else {
                throw HidppError.malformed("\(file.name) is not a .dfu file")
            }
            guard file.data.count >= 16, file.data.count <= maximumFileSize else {
                throw HidppError.malformed(
                    "\(file.name) has an unexpected size (\(file.data.count) bytes)"
                )
            }

            let bytes = [UInt8](file.data.prefix(10))
            guard Array(bytes[2..<10]) == Array("MPR05_D0".utf8) else {
                throw HidppError.malformed(
                    "\(file.name) is not a supported Bolt C548 firmware image"
                )
            }

            switch (bytes[0], bytes[1]) {
            case (0x02, 0x01):
                guard application == nil else {
                    throw HidppError.malformed("two application images were selected")
                }
                application = FirmwareImage(
                    kind: .application,
                    fileName: file.name,
                    data: file.data
                )
            case (0x01, 0x03):
                guard secondary == nil else {
                    throw HidppError.malformed("two radio / secondary images were selected")
                }
                secondary = FirmwareImage(
                    kind: .secondary,
                    fileName: file.name,
                    data: file.data
                )
            default:
                throw HidppError.malformed(
                    "\(file.name) has unsupported Bolt entity bytes "
                        + String(format: "0x%02x 0x%02x", bytes[0], bytes[1])
                )
            }
        }

        guard let application, let secondary else {
            throw HidppError.malformed(
                "select one Bolt application image and one radio / secondary image"
            )
        }

        let package = SelectedFirmwarePackage(
            application: application,
            secondary: secondary
        )
        _ = try DfuFlasher.validatePackage(package.images)
        return package
    }
}
