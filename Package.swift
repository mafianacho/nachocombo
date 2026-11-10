// swift-tools-version:5.5
import PackageDescription

var products: [Product] = [
    .library(name: "NachoComboCore", targets: ["NachoComboCore"]),
    // Dev/test client of the Nacho Pet core (scripts/pet-roundtrip.sh against tools/mock-server). Not shipped.
    .executable(name: "nacho-pet-cli", targets: ["NachoPetCLI"]),
    // Dev/test driver of the update engine (scripts/update-roundtrip.sh against tools/mock-server/releases.mjs).
    .executable(name: "nacho-update-cli", targets: ["NachoUpdateCLI"]),
]
var targets: [Target] = [
    // Foundation-only logic (settings, module lifecycle, math). Testable on any OS.
    .target(name: "NachoComboCore"),
    .executableTarget(name: "NachoPetCLI", dependencies: ["NachoComboCore"]),
    .executableTarget(name: "NachoUpdateCLI", dependencies: ["NachoComboCore"]),
    .testTarget(name: "NachoComboCoreTests", dependencies: ["NachoComboCore"]),
]

#if os(macOS)
// AppKit / Carbon / Accessibility layer. macOS only; skipped on Linux so the core can be tested there.
products.append(.executable(name: "NachoCombo", targets: ["NachoCombo"]))
// ScreenCaptureKit (recording) arrived in macOS 12.3: weak-linked so the app still opens on 12.0–12.2.
targets.append(.executableTarget(name: "NachoCombo", dependencies: ["NachoComboCore"],
                                 linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "ScreenCaptureKit"])]))
#endif

let package = Package(
    name: "NachoCombo",
    platforms: [.macOS(.v12)],
    products: products,
    targets: targets
)
