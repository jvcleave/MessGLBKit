// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MessGLBKit",
    platforms: [.macOS("15.6")],
    products: [.library(name: "MessGLBKit", targets: ["MessGLBKit"])],
    targets: [
        .binaryTarget(name: "GLTFKit2", path: "ThirdParty/Artifacts/GLTFKit2.xcframework"),
        .binaryTarget(name: "Draco", path: "ThirdParty/Artifacts/Draco.xcframework"),
        .target(
            name: "GLBDracoBridge",
            dependencies: ["GLTFKit2", "Draco"]
        ),
        .target(
            name: "MessGLBKit",
            dependencies: ["GLTFKit2", "GLBDracoBridge"],
            resources: [.copy("Resources/ThirdPartyNotices")]
        ),
        .testTarget(name: "MessGLBKitTests", dependencies: ["MessGLBKit"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
