// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FSMon",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FSMonCore", targets: ["FSMonCore"]),
        .executable(name: "fsmond", targets: ["fsmond"]),
    ],
    targets: [
        .target(name: "FSMonCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "fsmond", dependencies: ["FSMonCore"]),
        .testTarget(name: "FSMonCoreTests", dependencies: ["FSMonCore"]),
    ],
    swiftLanguageModes: [.v5]
)
