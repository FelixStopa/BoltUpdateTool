import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = UpdaterViewModel()
    @State private var showFlashConfirmation = false
    @State private var showFirmwareImporter = false
    @State private var confirmationText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            deviceStatus

            if let message = vm.stage.message {
                stageBanner(message)
            }

            Divider()
            firmwarePackage
            Divider()
            logView

            if let error = vm.lastErrorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 590)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if shouldShowFlashProgress {
                flashProgressFooter
            }
        }
        .onAppear { vm.refreshInfo() }
        .alert("Flash both Bolt firmware images?", isPresented: $showFlashConfirmation) {
            TextField("Type FLASH to confirm", text: $confirmationText)
            Button("Cancel", role: .cancel) { confirmationText = "" }
            Button("Start update", role: .destructive) {
                if confirmationText == "FLASH" {
                    vm.flashSelectedPackage()
                }
                confirmationText = ""
            }
            .disabled(confirmationText != "FLASH")
        } message: {
            Text(
                "The selected application and radio images will be written together. The app first tries to enter the bootloader automatically; if a physical reconnect is required, it will tell you. Once writing begins, do not unplug the receiver. Type FLASH to confirm."
            )
        }
        .fileImporter(
            isPresented: $showFirmwareImporter,
            allowedContentTypes: [UTType(filenameExtension: "dfu") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                vm.selectFirmwareFiles(urls)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    vm.reportFirmwareSelectionError(error)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bolt Receiver Firmware Updater")
                .font(.title2.bold())
            Text("Updater for Logitech Logi Bolt USB receivers. Normal mode: 046D:C548 · Update mode: 046D:AB07. Unofficial; use at your own risk.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("Felix Stopa ·")
                    .foregroundStyle(.secondary)
                Link("felix.stopa.net", destination: URL(string: "https://felix.stopa.net")!)
                    .accessibilityHint("Opens Felix Stopa's homepage in the default browser")
            }
            .font(.caption)
        }
    }

    private var deviceStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(vm.deviceFound ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(vm.deviceFound ? "Receiver found: \(vm.deviceProductString)" : "No Bolt receiver detected")
                    .font(.headline)
                Spacer()
                Button {
                    vm.refreshInfo()
                } label: {
                    Label("Refresh info", systemImage: "arrow.clockwise")
                }
                .disabled(vm.isBusy)
            }

            if vm.isInBootloaderMode {
                Label("Receiver is in AB07 bootloader mode; an interrupted update can be resumed.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if !vm.entities.isEmpty {
                Table(vm.entities) {
                    TableColumn("Entity") { entity in Text("\(entity.index)") }
                    TableColumn("Kind") { entity in Text(entity.kindDescription) }
                    TableColumn("Version") { entity in Text(entity.versionString).monospaced() }
                    TableColumn("Active") { entity in Text(entity.active ? "yes" : "no") }
                }
                .frame(height: 120)
            }
        }
    }

    private func stageBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if vm.stage.requiresUserAction {
                Image(systemName: "cable.connector.slash")
                    .font(.title2)
            } else if vm.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: vm.stage == .completed ? "checkmark.circle.fill" : "info.circle.fill")
            }
            Text(message)
                .font(vm.stage.requiresUserAction ? .headline : .callout)
        }
        .foregroundStyle(vm.stage.requiresUserAction ? Color.orange : Color.primary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((vm.stage.requiresUserAction ? Color.orange : Color.secondary).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var firmwarePackage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Firmware package").font(.headline)
                Spacer()
                Button {
                    showFirmwareImporter = true
                } label: {
                    Label(
                        vm.selectedFirmwarePackage == nil ? "Select DFU files" : "Change files",
                        systemImage: "doc.badge.plus"
                    )
                    .frame(minWidth: 96, minHeight: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(vm.isBusy)

                if vm.selectedFirmwarePackage != nil {
                    Button {
                        vm.clearFirmwareSelection()
                    } label: {
                        Label("Clear", systemImage: "xmark")
                            .frame(minWidth: 96, minHeight: 20)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(vm.isBusy)
                }
            }

            if let package = vm.selectedFirmwarePackage {
                firmwareRow(package.application, systemImage: "cpu")
                firmwareRow(
                    package.secondary,
                    systemImage: "antenna.radiowaves.left.and.right"
                )
                Label(
                    "Compatible Bolt C548 package selected (\(package.totalByteCount.formatted()) bytes).",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            } else {
                Label(
                    "Select the unpacked application and radio .dfu files together.",
                    systemImage: "doc.on.doc"
                )
                .foregroundStyle(.secondary)
                Text("The app does not contain or download Logitech firmware.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let selectionError = vm.firmwareSelectionError {
                Label(selectionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Text("Both images are checked for the expected Bolt C548 format and always flashed together.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button {
                    showFlashConfirmation = true
                } label: {
                    Label(vm.isInBootloaderMode ? "Resume update" : "Update receiver", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(
                    vm.isBusy
                        || !vm.deviceFound
                        || vm.selectedFirmwarePackage == nil
                )
                .accessibilityHint("Writes both selected firmware images to the Bolt receiver")
            }
        }
    }

    private func firmwareRow(_ image: FirmwareImage, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("\(image.kind.title): \(image.versionLabel)", systemImage: systemImage)
            Text(image.fileName)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Log").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: vm.logLines.count) { _, _ in
                    if let last = vm.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .background(Color.black.opacity(0.05))
            .frame(minHeight: 120, maxHeight: .infinity)
        }
    }

    private var shouldShowFlashProgress: Bool {
        vm.stage == .flashing || vm.stage == .restarting || vm.progress != nil
    }

    private var flashProgressFooter: some View {
        VStack(spacing: 8) {
            Divider()
            if vm.stage == .restarting {
                ProgressView(value: 1) {
                    Text("Firmware transferred. Restarting and verifying the receiver…")
                }
            } else if let progress = vm.progress, progress.packetCount > 0 {
                ProgressView(value: Double(progress.packetIndex), total: Double(progress.packetCount)) {
                    Text("Flashing packet \(progress.packetIndex)/\(progress.packetCount)")
                }
            } else {
                ProgressView {
                    Text("Starting firmware transfer…")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ContentView()
}
