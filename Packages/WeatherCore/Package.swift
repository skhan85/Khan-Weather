// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WeatherCore",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14), // lets `swift test` run on a Mac or CI runner
    ],
    products: [
        .library(name: "WeatherCore", targets: ["WeatherCore"]),
    ],
    targets: [
        .target(name: "WeatherCore"),
        .testTarget(name: "WeatherCoreTests", dependencies: ["WeatherCore"]),
    ]
)
