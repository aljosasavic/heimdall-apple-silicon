// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HeimdallFront",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HeimdallFront",
            path: "Sources",
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        )
    ]
)
