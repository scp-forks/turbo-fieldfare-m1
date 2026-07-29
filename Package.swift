// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TurboFieldfare",
    // macOS 14 backport: upstream targets .macOS(.v26)/.iOS(.v26) for Metal 4.
    // Building at .v26 stamps a macOS 26 deployment target onto the binaries,
    // which dyld then refuses to load on macOS 14. Lowered to the oldest OS
    // this checkout is expected to run on.
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "TurboFieldfare", targets: ["TurboFieldfare"]),
        .executable(name: "TurboFieldfareRepack", targets: ["TurboFieldfareRepack"]),
        .executable(name: "TurboFieldfareCLI", targets: ["TurboFieldfareCLI"]),
        .executable(name: "TurboFieldfareMac", targets: ["TurboFieldfareMac"]),
        .executable(name: "TurboFieldfareDecodeService", targets: ["TurboFieldfareDecodeService"]),
        .executable(name: "TurboFieldfareServer", targets: ["TurboFieldfareServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.99.0"),
    ],
    targets: [
        // macOS 14 backport: provides a `Mutex` shim standing in for
        // Synchronization.Mutex, which requires macOS 15.
        .target(
            name: "TurboFieldfareCompat",
            path: "Sources/TurboFieldfareCompat"
        ),
        .target(
            name: "TurboFieldfare",
            dependencies: [
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/TurboFieldfare",
            resources: [
                .copy("Metal"),
            ]
        ),
        .target(
            name: "TurboFieldfareRepackCore",
            path: "Sources/TurboFieldfareRepack/Core"
        ),
        .executableTarget(
            name: "TurboFieldfareRepack",
            dependencies: ["TurboFieldfareRepackCore"],
            path: "Sources/TurboFieldfareRepack/Command"
        ),
        .target(
            name: "TurboFieldfareCLICore",
            dependencies: ["TurboFieldfare"],
            path: "Sources/TurboFieldfareCLI",
            exclude: ["Command"]
        ),
        .executableTarget(
            name: "TurboFieldfareCLI",
            dependencies: ["TurboFieldfareCLICore"],
            path: "Sources/TurboFieldfareCLI/Command"
        ),
        .target(
            name: "TurboFieldfareAppCore",
            dependencies: ["TurboFieldfare", "TurboFieldfareRepackCore", "TurboFieldfareDecodeProtocol", "TurboFieldfareCompat"],
            path: "Sources/TurboFieldfareApp/Core",
            resources: [
                .copy("Resources/app-prompts.json"),
            ]
        ),
        .target(
            name: "TurboFieldfareMacPresentation",
            dependencies: ["TurboFieldfareAppCore"],
            path: "Sources/TurboFieldfareApp/MacPresentation"
        ),
        .target(
            name: "TurboFieldfareDecodeProtocol",
            path: "Sources/TurboFieldfareDecodeProtocol"
        ),
        .executableTarget(
            name: "TurboFieldfareDecodeService",
            dependencies: ["TurboFieldfareAppCore", "TurboFieldfareDecodeProtocol"],
            path: "Sources/TurboFieldfareDecodeService"
        ),
        .target(
            name: "TurboFieldfareServerCore",
            dependencies: [
                "TurboFieldfare",
                "TurboFieldfareCompat",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/TurboFieldfareServer/Core"
        ),
        .executableTarget(
            name: "TurboFieldfareServer",
            dependencies: ["TurboFieldfareServerCore"],
            path: "Sources/TurboFieldfareServer/Command"
        ),
        .executableTarget(
            name: "TurboFieldfareMac",
            dependencies: ["TurboFieldfareAppCore", "TurboFieldfareMacPresentation"],
            path: "Sources/TurboFieldfareApp/Mac",
            resources: [
                .copy("Resources/turbofieldfare-app-icon.png"),
            ]
        ),
        .target(
            name: "TurboFieldfareValidationSupport",
            dependencies: ["TurboFieldfare"],
            path: "Sources/TurboFieldfareValidation/Support"
        ),
        .testTarget(
            name: "TurboFieldfareTestsCore",
            dependencies: ["TurboFieldfare", "TurboFieldfareValidationSupport", "TurboFieldfareRepackCore", "TurboFieldfareCLICore"],
            path: "Tests/TurboFieldfare/Core"
        ),
        // macOS 14 backport: these test targets additionally depend on
        // TurboFieldfareCompat for the `Mutex` shim.
        .testTarget(
            name: "TurboFieldfareRepackTests",
            dependencies: ["TurboFieldfareRepackCore", "TurboFieldfareCompat"],
            path: "Tests/TurboFieldfareRepack/Core"
        ),
        .testTarget(
            name: "TurboFieldfareAppCoreTests",
            dependencies: ["TurboFieldfareAppCore", "TurboFieldfare", "TurboFieldfareRepackCore", "TurboFieldfareDecodeProtocol", "TurboFieldfareCompat"],
            path: "Tests/TurboFieldfareApp/Core"
        ),
        .testTarget(
            name: "TurboFieldfareMacPresentationTests",
            dependencies: ["TurboFieldfareMacPresentation"],
            path: "Tests/TurboFieldfareApp/MacPresentation"
        ),
        .testTarget(
            name: "TurboFieldfareServerTests",
            dependencies: [
                "TurboFieldfareServerCore",
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Tests/TurboFieldfareServer",
            resources: [.copy("Fixtures")]
        ),
    ]
)
