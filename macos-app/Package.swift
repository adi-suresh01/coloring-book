// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ColoringBook",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ColoringBook", targets: ["ColoringBook"]),
    ],
    targets: [
        .executableTarget(
            name: "ColoringBook",
            path: "Sources/ColoringBook"
        ),
    ]
)
