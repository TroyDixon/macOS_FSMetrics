// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "macOS_FSMetrics",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "FSMetricsCore", targets: ["FSMetricsCore"]),
        .executable(name: "FSMetricsApp", targets: ["FSMetricsApp"]),
        .executable(name: "fsmetrics", targets: ["fsmetrics"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "FSMetricsCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(name: "FSMetricsApp", dependencies: ["FSMetricsCore"]),
        .executableTarget(name: "fsmetrics", dependencies: ["FSMetricsCore"]),
        .testTarget(
            name: "FSMetricsCoreTests",
            dependencies: ["FSMetricsCore"],
            path: "tests/FSMetricsCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
