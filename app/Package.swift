// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "turublok",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "turublok",
            path: "Sources/turublok",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
                .linkedFramework("IOKit"),
            ]
        )
    ]
)
