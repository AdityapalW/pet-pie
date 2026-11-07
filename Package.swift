// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PiePet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PiePet", path: "Sources/PiePet")
    ]
)
