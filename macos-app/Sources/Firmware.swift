import CryptoKit
import Foundation

struct FirmwareError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// One BL/AP/CP/CSC archive (.tar.md5 or .tar), either a member of a firmware zip or a file in a folder.
struct FirmwarePart: Identifiable, Hashable {
    let id: String  // zip member name, or file path for a folder
    let slot: String
    let size: Int64
    var displayName: String { (id as NSString).lastPathComponent }
}

/// A Samsung stock firmware download: a zip from samfw/samfrew etc., or a folder of its extracted .tar.md5 files.
/// HOME_CSC is never used: flashing CSC is what changes the carrier code (and wipes the phone).
struct Firmware {
    let source: URL
    let isZip: Bool
    let parts: [FirmwarePart]

    var name: String { source.deletingPathExtension().lastPathComponent }
    var totalSize: Int64 { parts.reduce(0) { $0 + $1.size } }

    static let slotOrder = ["BL", "AP", "CP", "CSC"]

    static func open(_ url: URL) throws -> Firmware {
        let isZip = url.pathExtension.lowercased() == "zip"
        var entries: [(String, Int64)] = []
        if isZip {
            // `unzip -l` rows: "<length>  <date> <time>   <name>"
            let (code, out) = Shell.run("/usr/bin/unzip", ["-l", url.path])
            guard code == 0 else { throw FirmwareError("Can't read zip: \(out)") }
            for line in out.split(separator: "\n") {
                let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                if cols.count == 4, let size = Int64(cols[0]) {
                    entries.append((cols[3].trimmingCharacters(in: .whitespaces), size))  // name keeps column padding
                }
            }
        } else {
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])
            for f in files {
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                entries.append((f.path, size))
            }
        }
        var parts: [FirmwarePart] = []
        for (id, size) in entries {
            let file = (id as NSString).lastPathComponent
            guard file.hasSuffix(".tar.md5") || file.hasSuffix(".tar") else { continue }
            // "CSC_" does not match "HOME_CSC_", so HOME_CSC is skipped on purpose
            if let slot = slotOrder.first(where: { file.hasPrefix($0 + "_") }) {
                parts.append(FirmwarePart(id: id, slot: slot, size: size))
            }
        }
        parts.sort { slotOrder.firstIndex(of: $0.slot)! < slotOrder.firstIndex(of: $1.slot)! }
        for required in ["BL", "AP", "CSC"] where !parts.contains(where: { $0.slot == required }) {
            let found = entries.map { ($0.0 as NSString).lastPathComponent }.joined(separator: ", ")
            throw FirmwareError("No \(required)_ archive found in \(url.lastPathComponent). Found: \(found.isEmpty ? "nothing" : found)")
        }
        return Firmware(source: url, isZip: isZip, parts: parts)
    }

    // MARK: extraction

    private var marker: String { "\(source.path)|\(totalSize)" }

    func isExtracted(in dir: URL) -> Bool {
        (try? String(contentsOf: dir.appendingPathComponent(".complete"), encoding: .utf8)) == marker
    }

    /// Streams every archive once: verifies its MD5 and writes each image (lz4-decompressed) into `dir`.
    /// Nothing but the final images touches the disk, so a 17 GB firmware needs about 18 GB free.
    func extract(to dir: URL, progress: @escaping (String, Double) -> Void, log: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: dir.appendingPathComponent(".complete"))

        let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? Int64.max
        let needed = Int64(Double(totalSize) * 1.15)  // decompressed images run ~5-10% bigger than the archives
        guard free > needed else {
            throw FirmwareError(String(format: "Not enough disk space: need about %.1f GB, have %.1f GB.",
                                       Double(needed) / 1e9, Double(free) / 1e9))
        }
        guard let lz4 = Shell.find("lz4") else { throw FirmwareError("lz4 not found. Install it: brew install lz4") }

        let total = Double(totalSize)
        var done: Int64 = 0
        for part in parts {
            log("Reading \(part.displayName)")
            let (handle, process) = try openStream(part)
            let reader = StreamReader(handle: handle, hashTrailer: part.id.hasSuffix(".md5")) { n in
                done += n
                progress(part.slot, Double(done) / total)
            }
            try TarExtractor.extract(from: reader, to: dir, lz4: lz4, log: log)
            try reader.finishAndVerify()
            if let process {
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw FirmwareError("unzip failed on \(part.displayName)") }
            }
            log(part.id.hasSuffix(".md5") ? "MD5 OK: \(part.displayName)" : "No MD5 to check: \(part.displayName)")
        }
        try marker.write(to: dir.appendingPathComponent(".complete"), atomically: true, encoding: .utf8)
    }

    private func openStream(_ part: FirmwarePart) throws -> (FileHandle, Process?) {
        guard isZip else { return (try FileHandle(forReadingFrom: URL(fileURLWithPath: part.id)), nil) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", source.path, part.id]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        return (pipe.fileHandleForReading, p)
    }
}

/// Buffered reader over a pipe or file that also MD5s everything except the Samsung trailer line.
final class StreamReader {
    private let handle: FileHandle
    private let hashTrailer: Bool
    private let onRead: (Int64) -> Void
    private var buffer = Data()
    private var md5 = Insecure.MD5()
    private var held = Data()  // last bytes, not hashed yet: the "<md5>  <name>.tar" line hides in them
    private static let tail = 4096

    init(handle: FileHandle, hashTrailer: Bool, onRead: @escaping (Int64) -> Void) {
        self.handle = handle
        self.hashTrailer = hashTrailer
        self.onRead = onRead
    }

    @discardableResult
    private func fill() -> Bool {
        let chunk = handle.readData(ofLength: 8 << 20)
        guard !chunk.isEmpty else { return false }
        onRead(Int64(chunk.count))
        held.append(chunk)
        if held.count > Self.tail {
            md5.update(data: held.prefix(held.count - Self.tail))
            held = Data(held.suffix(Self.tail))
        }
        buffer.append(chunk)
        return true
    }

    /// Up to `max` bytes, or empty at end of stream.
    func read(upTo max: Int) -> Data {
        if buffer.isEmpty { fill() }
        let n = min(max, buffer.count)
        let out = Data(buffer.prefix(n))
        buffer = Data(buffer.dropFirst(n))
        return out
    }

    /// Exactly `count` bytes, nil if the stream ends first.
    func read(exactly count: Int) -> Data? {
        while buffer.count < count { if !fill() { return nil } }
        let out = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return out
    }

    func skip(_ count: Int64) throws {
        var left = count
        while left > 0 {
            let d = read(upTo: Int(min(left, 8 << 20)))
            if d.isEmpty { throw FirmwareError("Archive ended early (truncated download?)") }
            left -= Int64(d.count)
        }
    }

    func finishAndVerify() throws {
        buffer.removeAll()
        while fill() { buffer.removeAll() }
        guard hashTrailer else { return }
        var body = held
        while body.last == 0x0A { body.removeLast() }
        // the md5 line follows the tar's zero padding, so it starts after the last NUL or newline
        let cut = (body.lastIndex(where: { $0 == 0 || $0 == 0x0A }) ?? -1) + 1
        md5.update(data: held.prefix(cut))
        let expected = String(decoding: body.suffix(from: cut), as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        let actual = md5.finalize().map { String(format: "%02x", $0) }.joined()
        guard expected.count == 32 else { throw FirmwareError("No MD5 trailer found; the archive may be truncated.") }
        guard actual == expected.lowercased() else { throw FirmwareError("MD5 mismatch (got \(actual), expected \(expected)). Re-download the firmware.") }
    }
}

/// Minimal ustar/GNU tar reader: top-level regular files only; meta-data/ and other entries are skipped.
enum TarExtractor {
    static func extract(from r: StreamReader, to dir: URL, lz4: String, log: (String) -> Void) throws {
        while let header = r.read(exactly: 512) {
            if header.allSatisfy({ $0 == 0 }) { return }  // end-of-archive block
            let name = string(header, 0, 100)
            let prefix = string(header, 345, 155)
            let path = prefix.isEmpty ? name : prefix + "/" + name
            let size = try parseSize(header)
            let padded = (size + 511) / 512 * 512
            let type = header[156]
            let isFile = type == 0x30 || type == 0
            // trust boundary: only plain names, so nothing can be written outside `dir`
            guard isFile, !path.contains("/"), path != ".", path != "..", !path.isEmpty else {
                try r.skip(padded)
                continue
            }
            try write(member: path, size: size, from: r, to: dir, lz4: lz4)
            try r.skip(padded - size)
            log("  \(path)")
        }
        throw FirmwareError("Archive ended without an end-of-archive block (truncated download?)")
    }

    /// Octal, or GNU base-256 (high bit set) for members of 8 GiB and more, like super.img.lz4.
    static func parseSize(_ h: Data) throws -> Int64 {
        let field = h.subdata(in: 124..<136)
        if field[0] & 0x80 != 0 {
            return field.dropFirst().reduce(Int64(field[0] & 0x7F)) { $0 << 8 | Int64($1) }
        }
        let text = String(decoding: field, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
        guard let n = Int64(text.isEmpty ? "0" : text, radix: 8) else { throw FirmwareError("Bad tar header size field") }
        return n
    }

    private static func string(_ h: Data, _ offset: Int, _ length: Int) -> String {
        let bytes = h.subdata(in: offset..<offset + length)
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    private static func write(member: String, size: Int64, from r: StreamReader, to dir: URL, lz4: String) throws {
        let compressed = member.hasSuffix(".lz4")
        let dest = dir.appendingPathComponent(compressed ? String(member.dropLast(4)) : member)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }

        var sink = out
        var process: Process?
        var stdin: Pipe?
        if compressed {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: lz4)
            p.arguments = ["-d", "-c", "-q"]
            let pipe = Pipe()
            p.standardInput = pipe
            p.standardOutput = out
            try p.run()
            process = p
            stdin = pipe
            sink = pipe.fileHandleForWriting
        }
        var left = size
        while left > 0 {
            let d = r.read(upTo: Int(min(left, 8 << 20)))
            if d.isEmpty { throw FirmwareError("Archive ended inside \(member)") }
            try sink.write(contentsOf: d)
            left -= Int64(d.count)
        }
        if let process, let stdin {
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw FirmwareError("lz4 failed on \(member)") }
        }
    }
}

enum Shell {
    static func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Apps launched from Finder get a minimal PATH, so look in Homebrew's folders directly.
    static func find(_ tool: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
