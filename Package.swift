// swift-tools-version:5.10
import PackageDescription
import Foundation

// Pro/ is git-ignored and has its own repository.
//   - Pro/ present → official build, including the paid engine.
//   - Pro/ absent  → community build; Pro screens show an activation prompt instead.
// Everything compiles into one module, so nothing needs to be marked `public`.
let proSources = "Pro/Sources/OmitXPro"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let proTests = "Pro/Tests/OmitXProTests"
let hasPro = FileManager.default.fileExists(atPath: root.appendingPathComponent(proSources).path)

// Each target must exclude the other target's Pro files, or SwiftPM reports "unhandled file".
// Archived/ and build/ are git-ignored, so a fresh clone lacks them — exclude only what exists,
// otherwise every contributor sees "Invalid Exclude" warnings.
let common = ["Localization", "Archived", "scripts", "docs", "build", "omitx-backend", "README.md", "LICENSE", "Package.swift"]
    .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
let proExtras = hasPro ? ["Pro/README.md"] : []

let package = Package(
    name: "OmitX",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OmitX",
            path: ".",
            exclude: common + ["Tests"] + proExtras + (hasPro ? ["Pro/Tests"] : []),
            sources: hasPro ? ["Sources/OmitX", proSources] : ["Sources/OmitX"]
        ),
        .testTarget(
            name: "OmitXTests",
            dependencies: ["OmitX"],
            path: ".",
            exclude: common + ["Sources"] + proExtras + (hasPro ? ["Pro/Sources", "Pro/Tests/Fixtures"] : []),
            sources: hasPro ? ["Tests/OmitXTests", proTests] : ["Tests/OmitXTests"]
        ),
    ]
)
