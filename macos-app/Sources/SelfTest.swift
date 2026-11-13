import CryptoKit
import Foundation

/// `HeimdallFront --selftest`: builds a fake Samsung firmware (folder and zip), extracts it, and checks
/// MD5 verification, lz4 decompression, HOME_CSC/meta-data skipping and GNU base-256 tar sizes.
enum SelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) {
            print((cond ? "PASS " : "FAIL ") + what)
            ok = ok && cond
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("heimdallfront-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            let src = root.appendingPathComponent("src"), fwDir = root.appendingPathComponent("fw")
            try fm.createDirectory(at: src.appendingPathComponent("meta-data"), withIntermediateDirectories: true)
            try fm.createDirectory(at: fwDir, withIntermediateDirectories: true)

            let image = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) })
            try image.write(to: src.appendingPathComponent("super.img"))
            try Data("PIT".utf8).write(to: src.appendingPathComponent("test.pit"))
            try Data("bl".utf8).write(to: src.appendingPathComponent("abl.elf"))
            try Data("x".utf8).write(to: src.appendingPathComponent("meta-data/fota.zip"))
            guard let lz4 = Shell.find("lz4") else { check(false, "lz4 installed"); return false }
            for f in ["super.img", "abl.elf"] {
                _ = Shell.run(lz4, ["-q", "-f", src.appendingPathComponent(f).path, src.appendingPathComponent(f + ".lz4").path])
            }

            func makeTarMD5(_ name: String, _ members: [String]) throws {
                let tar = fwDir.appendingPathComponent(name + ".tar")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                p.arguments = ["--format", "ustar", "-cf", tar.path, "-C", src.path] + members
                p.environment = ["COPYFILE_DISABLE": "1"]  // no AppleDouble ._ entries
                try p.run()
                p.waitUntilExit()
                var data = try Data(contentsOf: tar)
                let sum = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
                data.append(Data("\(sum)  \(name).tar\n".utf8))
                try data.write(to: fwDir.appendingPathComponent(name + ".tar.md5"))
                try fm.removeItem(at: tar)
            }
            try makeTarMD5("BL_TEST", ["abl.elf.lz4"])
            try makeTarMD5("AP_TEST", ["super.img.lz4", "meta-data"])
            try makeTarMD5("CSC_TEST", ["test.pit"])
            try makeTarMD5("HOME_CSC_TEST", ["test.pit"])

            for (label, url) in [("folder", fwDir), ("zip", try zip(fwDir, root))] {
                let fw = try Firmware.open(url)
                check(fw.parts.map(\.slot) == ["BL", "AP", "CSC"], "\(label): BL/AP/CSC found, HOME_CSC skipped")
                let out = root.appendingPathComponent("out-\(label)")
                try fw.extract(to: out, progress: { _, _ in }, log: { _ in })
                check((try? Data(contentsOf: out.appendingPathComponent("super.img"))) == image, "\(label): lz4 image restored byte for byte")
                check((try? String(contentsOf: out.appendingPathComponent("abl.elf"), encoding: .utf8)) == "bl", "\(label): BL image restored")
                check(fm.fileExists(atPath: out.appendingPathComponent("test.pit").path), "\(label): PIT copied")
                check(!fm.fileExists(atPath: out.appendingPathComponent("fota.zip").path), "\(label): meta-data skipped")
                check(fw.isExtracted(in: out), "\(label): completion marker written")
            }

            // a flipped byte in an uncompressed member (the PIT, right after CSC's first header) must fail the MD5 check
            let csc = fwDir.appendingPathComponent("CSC_TEST.tar.md5")
            var bad = try Data(contentsOf: csc)
            bad[512] ^= 0xFF
            try bad.write(to: csc)
            do {
                try Firmware.open(fwDir).extract(to: root.appendingPathComponent("out-bad"), progress: { _, _ in }, log: { _ in })
                check(false, "corrupted archive rejected")
            } catch {
                check(error.localizedDescription.contains("MD5 mismatch"), "corrupted archive rejected (\(error.localizedDescription.prefix(40))…)")
            }

            // GNU base-256 size field, as used for members of 8 GiB and more
            var header = Data(count: 512)
            header[124] = 0x80
            let big: Int64 = 11_567_300_000
            for i in 0..<8 { header[135 - i] = UInt8(truncatingIfNeeded: big >> (8 * Int64(i))) }
            check((try? TarExtractor.parseSize(header)) == big, "base-256 tar size parsed")

            // flash output parsing: backspace-redrawn percentages and status lines
            let parser = FlashParser()
            let events = parser.feed("Uploading SUPER\n0%\u{8}\u{8}57%\u{8}\u{8}\u{8}100%\nSUPER upload successful\n")
            check(events.contains(.uploading("SUPER")) && events.contains(.percent(100)) && events.contains(.uploaded("SUPER")),
                  "flash output parsed")
        } catch {
            check(false, "unexpected error: \(error.localizedDescription)")
        }
        print(ok ? "selftest OK" : "selftest FAILED")
        return ok
    }

    private static func zip(_ dir: URL, _ root: URL) throws -> URL {
        let out = root.appendingPathComponent("fw.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "-j", out.path] + ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .map { dir.appendingPathComponent($0).path }
        try p.run()
        p.waitUntilExit()
        return out
    }
}
