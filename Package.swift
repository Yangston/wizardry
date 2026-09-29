// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WizardryCore",
    products: [.library(name: "GestureCore", targets: ["GestureCore"])],
    targets: [
        .target(name: "GestureCore"),
        .testTarget(name: "GestureCoreTests", dependencies: ["GestureCore"])
    ]
)
