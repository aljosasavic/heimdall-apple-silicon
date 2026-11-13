import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var confirmFlash = false
    @State private var showPartitions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            deviceRow
            firmwareBox
            progressBox
            actions
            logBox
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 680)
        .alert("Flash the phone?", isPresented: $confirmFlash) {
            Button("Flash and erase", role: .destructive) { model.flash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This writes \(model.images.count) partitions, including CSC, and erases everything on the phone. "
                 + "Keep the cable connected until it finishes.")
        }
    }

    private var deviceRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.deviceReady ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(model.deviceReady ? "Phone in Download Mode" : "No phone in Download Mode")
                .font(.headline)
            Spacer()
            if !model.deviceReady {
                Text("Power off, hold both volume buttons, plug in USB, press Volume Up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var firmwareBox: some View {
        GroupBox("Firmware") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.firmware?.source.lastPathComponent ?? "None selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { model.chooseFirmware() }
                        .disabled(model.busy)
                }
                if let fw = model.firmware {
                    ForEach(fw.parts) { part in
                        HStack {
                            Text(part.slot)
                                .font(.system(.body, design: .monospaced).bold())
                                .frame(width: 44, alignment: .leading)
                            Text(part.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: part.size, countStyle: .file))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    Text("HOME_CSC is not used: flashing CSC changes the carrier code and wipes the phone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !model.images.isEmpty {
                    DisclosureGroup("\(model.images.count) partitions mapped from the firmware PIT", isExpanded: $showPartitions) {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 4) {
                                ForEach(model.images) { img in
                                    Text("\(img.partition) ← \(img.file)")
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                    .font(.callout)
                }
            }
            .padding(8)
        }
    }

    private var progressBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.status)
                .font(.callout)
                .foregroundStyle(statusColor)
            ProgressView(value: model.progress)
                .opacity(model.stage == .idle ? 0.3 : 1)
            if model.stage == .flashing || model.stage == .done {
                ProgressView(value: Double(model.uploaded), total: Double(max(model.images.count, 1))) {
                    Text("\(model.uploaded) of \(model.images.count) partitions")
                        .font(.caption)
                        .monospacedDigit()
                }
            }
        }
    }

    private var statusColor: Color {
        switch model.stage {
        case .failed: return .red
        case .done: return .green
        default: return .primary
        }
    }

    private var actions: some View {
        HStack {
            Button("Verify & Extract") { model.prepare() }
                .disabled(model.firmware == nil || model.busy)
            Button("Flash…") { confirmFlash = true }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!model.canFlash)
            Spacer()
            Button("Show Images") { model.revealImages() }
                .disabled(model.workDir == nil)
            Button("Delete Images") { model.deleteImages() }
                .disabled(model.firmware == nil || model.busy)
        }
    }

    private var logBox: some View {
        GroupBox("Log") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.log) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.text.hasPrefix("ERROR") ? Color.red : Color.primary)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .onChange(of: model.log.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}
