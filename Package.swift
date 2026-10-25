// swift-tools-version: 6.0
import PackageDescription

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
