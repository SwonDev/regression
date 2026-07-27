// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Regression",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RegressionCore", targets: ["RegressionCore"]),
        .executable(name: "Regression", targets: ["Regression"]),
        .executable(name: "regressionctl", targets: ["RegressionControl"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "RegressionCore",
            dependencies: ["CSQLite"],
            path: "Sources/RegressionCore"
        ),
        .executableTarget(
            name: "Regression",
            dependencies: ["RegressionCore"],
            path: "Sources/Regression"
        ),
        .executableTarget(
            name: "RegressionControl",
            dependencies: ["RegressionCore"],
            path: "Sources/RegressionControl"
        ),
        .testTarget(
            name: "RegressionCoreTests",
            dependencies: ["RegressionCore"],
            path: "Tests/RegressionCoreTests"
        )
    ]
)
