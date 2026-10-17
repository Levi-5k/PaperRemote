// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PaperDeviceKit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "PaperDeviceKit", targets: ["PaperDeviceKit"])],
    targets: [
        .target(name: "PaperDeviceKit", resources: [.copy("Boards")]),
        .testTarget(name: "PaperDeviceKitTests", dependencies: ["PaperDeviceKit"], resources: [.copy("Fixtures")]),
    ]
)
