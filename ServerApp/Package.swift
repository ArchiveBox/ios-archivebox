// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ArchiveBoxServer",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: ".."), .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"), .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0")],
    targets: [.executableTarget(name: "ArchiveBoxServer", dependencies: [.product(name: "ArchiveBoxCore", package: "ios-archivebox"), .product(name: "SwiftTerm", package: "SwiftTerm"), .product(name: "Sparkle", package: "Sparkle")], path: "Sources")],
    swiftLanguageModes: [.v6]
)
