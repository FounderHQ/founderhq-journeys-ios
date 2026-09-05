// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FounderHQJourneys",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "FounderHQJourneys", targets: ["FounderHQJourneys"]),
    ],
    targets: [
        .target(name: "FounderHQJourneys"),
        .testTarget(
            name: "FounderHQJourneysTests",
            dependencies: ["FounderHQJourneys"]
        ),
    ]
)
