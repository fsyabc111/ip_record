// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "IPRecord", platforms: [.macOS("27.0")],
    products: [.executable(name: "IPRecord", targets: ["IPRecord"]), .library(name: "IPRecordCore", targets: ["IPRecordCore"])],
    targets: [
        .target(name: "CXDB", publicHeadersPath: "include"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "IPRecordCore", dependencies: ["CXDB", "CSQLite"], linkerSettings: [.linkedFramework("SystemConfiguration"), .linkedFramework("Network")]),
        .executableTarget(name: "IPRecord", dependencies: ["IPRecordCore"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("ServiceManagement")]),
        .testTarget(name: "IPRecordCoreTests", dependencies: ["IPRecordCore"])
    ], swiftLanguageModes: [.v6])
