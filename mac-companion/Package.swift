// swift-tools-version: 5.10

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let infoPlistPath = packageRoot
    .appendingPathComponent("Sources/PaperGIFMac/Info.plist")
    .path

let package = Package(
    name: "PaperGIFMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PaperGIFMac", targets: ["PaperGIFMac"]),
    ],
    targets: [
        .executableTarget(
            name: "PaperGIFMac",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath,
                ]),
            ]
        ),
        .testTarget(name: "PaperGIFMacTests", dependencies: ["PaperGIFMac"]),
    ]
)
