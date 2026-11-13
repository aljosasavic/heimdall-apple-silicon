import SwiftUI

@main
struct HeimdallFrontApp: App {
    @StateObject private var model = AppModel()

    init() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }
        // headless: HeimdallFront --extract <firmware.zip|folder> <out-dir>  (verify + extract + map, no flashing)
        if let i = args.firstIndex(of: "--extract"), args.count > i + 2 {
            do {
                let fw = try Firmware.open(URL(fileURLWithPath: args[i + 1]))
                let out = URL(fileURLWithPath: args[i + 2])
                try fw.extract(to: out, progress: { _, _ in }, log: { print($0) })
                let map = try Heimdall.mapping(in: out)
                map.forEach { print("--\($0.partition) \($0.file)") }
                print("\(map.count) partitions mapped")
                exit(0)
            } catch {
                print("ERROR: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup("Heimdall") {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}
