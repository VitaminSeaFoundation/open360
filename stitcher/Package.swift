// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "open360-stitch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "open360-stitch",
            path: "Sources/open360-stitch",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        )
    ]
)
