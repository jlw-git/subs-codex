// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Subs",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Subs", targets: ["SubsApp"])
    ],
    targets: [
        .executableTarget(
            name: "SubsApp",
            path: "Sources/SubsApp"
        )
    ]
)
