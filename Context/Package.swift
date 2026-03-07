// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Workspace",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(path: "LocalPackages/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "Workspace",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Workspace",
            resources: [
                .copy("Resources/AppIcon.icns"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "WorkspaceMCP",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/WorkspaceMCP",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
