// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ArchiveBoxCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "ArchiveBoxCore", targets: ["ArchiveBoxCore"])],
    targets: [
        .target(name: "ArchiveBoxCore", resources: [.copy("Resources/public_suffix_list.dat")]),
        .executableTarget(name: "ArchiveBoxIntegration", dependencies: ["ArchiveBoxCore"], path: "IntegrationTests"),
        .testTarget(name: "ArchiveBoxCoreTests", dependencies: ["ArchiveBoxCore"]),
    ]
)
