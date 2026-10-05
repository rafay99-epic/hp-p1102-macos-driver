// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrinterBar",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CCups", path: "Sources/CCups"),
        .target(name: "PrinterBarKit", dependencies: ["CCups"]),
        .executableTarget(name: "PrinterBar", dependencies: ["PrinterBarKit"]),
        .testTarget(name: "PrinterBarKitTests", dependencies: ["PrinterBarKit"]),
    ],
    swiftLanguageModes: [.v5]
)
