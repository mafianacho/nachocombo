// swift-tools-version:5.5
import PackageDescription

var products: [Product] = [.library(name: "NachoComboCore", targets: ["NachoComboCore"])]
var targets: [Target] = [
    // Foundation-only logic (settings, module lifecycle, math). Testable on any OS.
    .target(name: "NachoComboCore"),
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
