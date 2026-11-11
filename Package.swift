// swift-tools-version:5.10
import PackageDescription

// No outside dependencies on purpose. Anything added here should be a
// deliberate, documented choice (see README, "Decisions").
let package = Package(
    name: "LabBox",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LabBoxCore", targets: ["LabBoxCore"]),
        .executable(name: "labbox", targets: ["labbox"]),
    ],
    targets: [
        .target(name: "LabBoxCore"),
        .executableTarget(name: "labbox", dependencies: ["LabBoxCore"]),
        .testTarget(name: "LabBoxCoreTests", dependencies: ["LabBoxCore"]),
    ]
)
