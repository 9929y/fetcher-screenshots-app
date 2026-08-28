// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fetcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Fetcher",
            path: "Sources/Fetcher"
        )
    ]
)
