// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AndroidConnection",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AndroidConnection", targets: ["AndroidConnection"])
    ],
    targets: [
        .executableTarget(
            name: "AndroidConnection",
            path: "Sources/AndroidConnection"
        )
    ]
)
