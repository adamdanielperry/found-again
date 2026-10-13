// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DataRecover",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DataRecover", targets: ["DataRecover"])
    ],
    targets: [
        .target(
            name: "DataRecoverCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CDiskAccess",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "DataRecover",
            dependencies: ["DataRecoverCore", "CDiskAccess"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("QuickLookUI"),
            ]
        ),
        .executableTarget(
            name: "recover-cli",
            dependencies: ["DataRecoverCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DataRecoverCoreTests",
            dependencies: ["DataRecoverCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
