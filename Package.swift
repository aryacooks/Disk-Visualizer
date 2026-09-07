// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskBuddy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScannerCore", targets: ["ScannerCore"]),
        .executable(name: "dbscan", targets: ["dbscan"]),
        .executable(name: "DiskBuddyApp", targets: ["DiskBuddyApp"])
    ],
    targets: [
        .target(
            name: "ScannerCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        ),
        .executableTarget(
            name: "dbscan",
            dependencies: ["ScannerCore"],
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        ),
        .executableTarget(
            name: "DiskBuddyApp",
            dependencies: ["ScannerCore"],
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        )
    ]
)
