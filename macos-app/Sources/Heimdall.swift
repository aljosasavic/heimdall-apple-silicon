import Foundation

struct PartitionImage: Identifiable, Hashable {
    let partition: String
    let file: String
    var id: String { partition }
}

/// Thin wrapper over the patched heimdall CLI bundled in the app (or built next to it in the repo).
enum Heimdall {
    static var binary: String? {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("heimdall").path) }
        // running from the repo: macos-app/.build/<triple>/<config>/HeimdallFront -> build/bin/heimdall
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent("../../../../build/bin/heimdall").standardized.path)
        candidates.append("/opt/homebrew/bin/heimdall")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// True when a Samsung device in Download Mode is on USB. Only enumerates; it does not open a session.
    static func detect() -> Bool {
        guard let bin = binary else { return false }
        return Shell.run(bin, ["detect"]).0 == 0
    }

    /// Image-to-partition mapping from the firmware's own PIT (shipped inside CSC), limited to images on disk.
    static func mapping(in dir: URL) throws -> [PartitionImage] {
        guard let bin = binary else { throw FirmwareError("heimdall binary not found") }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let pit = files.first(where: { $0.hasSuffix(".pit") }) else {
            throw FirmwareError("No .pit file in the firmware (it normally ships inside CSC).")
        }
        let (code, out) = Shell.run(bin, ["print-pit", "--file", dir.appendingPathComponent(pit).path])
        guard code == 0 else { throw FirmwareError("heimdall print-pit failed:\n\(out)") }
        var result: [PartitionImage] = []
        var name = ""
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "Partition Name" { name = parts[1] }
            if parts[0] == "Flash Filename", !parts[1].isEmpty, parts[1] != "-", files.contains(parts[1]) {
                result.append(PartitionImage(partition: name, file: parts[1]))
            }
        }
        guard !result.isEmpty else { throw FirmwareError("No firmware image matched the PIT.") }
        return result
    }

    /// Runs one flash session; streams raw output (progress uses backspaces) and returns the exit code.
    static func flash(_ images: [PartitionImage], in dir: URL, onOutput: @escaping (String) -> Void) -> Int32 {
        guard let bin = binary else { onOutput("ERROR: heimdall binary not found\n"); return -1 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["flash"] + images.flatMap { ["--\($0.partition)", dir.appendingPathComponent($0.file).path] }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { onOutput(String(decoding: d, as: UTF8.self)) }
        }
        do { try p.run() } catch { onOutput("ERROR: \(error.localizedDescription)\n"); return -1 }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        if !rest.isEmpty { onOutput(String(decoding: rest, as: UTF8.self)) }
        return p.terminationStatus
    }
}

/// Turns heimdall's flash output into events. Percentages are redrawn in place with backspaces,
/// so they are read from each raw chunk; everything else is handled line by line.
final class FlashParser {
    enum Event: Equatable {
        case uploading(String)
        case uploaded(String)
        case percent(Int)
        case line(String)
    }

    private var pending = ""

    func feed(_ chunk: String) -> [Event] {
        var events: [Event] = []
        if let pct = chunk.matches(of: /(\d{1,3})%/).last.flatMap({ Int($0.output.1) }) { events.append(.percent(pct)) }
        pending += chunk
        while let nl = pending.firstIndex(of: "\n") {
            let raw = String(pending[..<nl])
            pending = String(pending[pending.index(after: nl)...])
            let text = raw.replacing(/\d{1,3}%/, with: "").replacingOccurrences(of: "\u{8}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let m = text.wholeMatch(of: /Uploading (\S+)/) { events.append(.uploading(String(m.output.1))) }
            else if let m = text.wholeMatch(of: /(\S+) upload successful/) { events.append(.uploaded(String(m.output.1))) }
            events.append(.line(text))
        }
        return events
    }
}
