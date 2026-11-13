import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    enum Stage: Equatable {
        case idle, preparing, ready, flashing, done
        case failed(String)
    }

    struct LogLine: Identifiable {
        let id: Int
        let text: String
    }

    @Published var deviceReady = false
    @Published var firmware: Firmware?
    @Published var images: [PartitionImage] = []
    @Published var stage: Stage = .idle
    @Published var progress = 0.0
    @Published var status = "Choose a firmware zip or folder."
    @Published var currentPartition = ""
    @Published var uploaded = 0
    @Published private(set) var log: [LogLine] = []

    private(set) var workDir: URL?
    private var nextLogID = 0
    private var poller: Timer?

    static let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HeimdallFront", isDirectory: true)

    var busy: Bool { stage == .preparing || stage == .flashing }
    var canFlash: Bool { deviceReady && !images.isEmpty && !busy }

    init() {
        if Heimdall.binary == nil { append("ERROR: heimdall not found. Build it first (./build.sh in the repo).") }
        poller = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollDevice() }
        }
        Task { await pollDevice() }
    }

    private func pollDevice() async {
        guard stage != .flashing else { return }  // never touch USB while a session is open
        deviceReady = await Task.detached { Heimdall.detect() }.value
    }

    func append(_ text: String) {
        log.append(LogLine(id: nextLogID, text: text))
        nextLogID += 1
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
    }

    private func fail(_ message: String) {
        stage = .failed(message)
        status = message
        append("ERROR: \(message)")
    }

    // MARK: actions

    func chooseFirmware() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Samsung firmware .zip, or a folder with its BL/AP/CP/CSC .tar.md5 files"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let fw = try Firmware.open(url)
            firmware = fw
            images = []
            workDir = nil
            stage = .idle
            progress = 0
            status = "Ready to verify and extract."
            append("Firmware: \(url.lastPathComponent)")
            fw.parts.forEach { append("  \($0.slot): \($0.displayName)") }
        } catch {
            firmware = nil
            fail(error.localizedDescription)
        }
    }

    func prepare() {
        guard let fw = firmware else { return }
        let dir = Self.cacheRoot.appendingPathComponent(fw.name, isDirectory: true)
        stage = .preparing
        progress = 0
        status = "Verifying and extracting…"
        Task.detached { [weak self] in
            do {
                if fw.isExtracted(in: dir) {
                    await self?.append("Already extracted and verified: \(dir.path)")
                } else {
                    try fw.extract(to: dir,
                                   progress: { slot, p in Task { @MainActor in
                                       self?.status = "Verifying and extracting \(slot)…"
                                       self?.progress = p
                                   } },
                                   log: { line in Task { @MainActor in self?.append(line) } })
                }
                let map = try Heimdall.mapping(in: dir)
                await MainActor.run {
                    guard let self else { return }
                    self.workDir = dir
                    self.images = map
                    self.stage = .ready
                    self.progress = 1
                    self.status = "\(map.count) partitions ready. Put the phone in Download Mode, then flash."
                    self.append("Mapped \(map.count) images to partitions using the firmware PIT")
                }
            } catch {
                await self?.fail(error.localizedDescription)
            }
        }
    }

    func flash() {
        guard let dir = workDir, canFlash else { return }
        let images = self.images
        stage = .flashing
        uploaded = 0
        progress = 0
        currentPartition = ""
        status = "Flashing… do not unplug the phone."
        append("Starting flash: \(images.count) partitions")
        Task.detached { [weak self] in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "Flashing firmware")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let parser = FlashParser()
            let code = Heimdall.flash(images, in: dir) { chunk in
                let events = parser.feed(chunk)
                Task { @MainActor in self?.apply(events) }
            }
            await MainActor.run {
                guard let self else { return }
                if code == 0 {
                    self.stage = .done
                    self.progress = 1
                    self.status = "Flash complete. The phone is rebooting; the first boot takes a few minutes."
                    self.append("Flash complete (heimdall exit 0)")
                } else {
                    self.fail("Flash failed (heimdall exit \(code)). Re-enter Download Mode before retrying: the phone accepts one session per entry.")
                }
            }
        }
    }

    private func apply(_ events: [FlashParser.Event]) {
        for e in events {
            switch e {
            case .uploading(let p): currentPartition = p; progress = 0
            case .uploaded: uploaded += 1
            case .percent(let pct): progress = Double(pct) / 100
            case .line(let text): append(text)
            }
        }
        if stage == .flashing, !currentPartition.isEmpty {
            status = "Uploading \(currentPartition) (\(uploaded + 1) of \(images.count))… do not unplug the phone."
        }
    }

    func deleteImages() {
        guard let fw = firmware else { return }
        let dir = Self.cacheRoot.appendingPathComponent(fw.name, isDirectory: true)
        do {
            try FileManager.default.removeItem(at: dir)
            images = []
            workDir = nil
            stage = .idle
            status = "Extracted images deleted."
            append("Deleted \(dir.path)")
        } catch {
            fail(error.localizedDescription)
        }
    }

    func revealImages() {
        if let workDir { NSWorkspace.shared.activateFileViewerSelecting([workDir]) }
    }
}
