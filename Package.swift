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
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "SubsApp",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/SubsApp",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "SubsAppTests",
            dependencies: ["SubsApp"],
            path: "Tests/SubsAppTests"
        )
    ]
)
