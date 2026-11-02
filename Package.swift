// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MenuHub",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MenuHub",
            path: "Sources/MenuHub",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("DiskArbitration")]
        )
    ]
)
