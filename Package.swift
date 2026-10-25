// swift-tools-version: 6.0
import PackageDescription
import Foundation

// SwiftPM records the deployment target as the binary's SDK version, which makes
// AppKit fall back to the legacy window design (including the old traffic
// lights). Keep the macOS 15 deployment target, but tell the linker to record
// the SDK actually used to build the app so macOS can apply the current design.
let macosDeploymentTarget = "15.0"
let macosSDKVersion = ProcessInfo.processInfo.environment["AUDIA_MACOS_SDK_VERSION"] ?? "27.0"

let package = Package(
    name: "Audia",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "Audia",
            path: "Sources/Audia",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags([
                    "-Xlinker", "-platform_version",
                    "-Xlinker", "macos",
                    "-Xlinker", macosDeploymentTarget,
                    "-Xlinker", macosSDKVersion,
                ])
            ]
        )
    ]
)
