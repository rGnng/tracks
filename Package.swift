// swift-tools-version: 6.0
import PackageDescription

// SwiftPM records the deployment target as the binary's SDK version, which makes
// AppKit fall back to the legacy window design. `scripts/build.sh` passes the
// macOS 27 SDK version through `-Xlinker -platform_version` when building the
// app; keeping that build-only override out of the manifest means this package
// remains usable by other SwiftPM packages.
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
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
