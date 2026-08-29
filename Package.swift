// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SightsAndSounds",
    platforms: [.macOS(.v15)],
    products: [
        // Shared model + store package. iOS/iPadOS/tvOS (Phase 10) build their
        // own presentation on top of this — nothing platform-specific lives here.
        .library(name: "SightsAndSoundsKit", targets: ["SightsAndSoundsKit"]),
        // The macOS app shell. Phase 0 keeps it minimal; Phase 3 grows it.
        .executable(name: "SightsAndSounds", targets: ["SightsAndSoundsApp"]),
    ],
    dependencies: [
        // GRDB, not SwiftData: the three-way tag filter must compile to a SQL
        // predicate (locked decision 01/07 in docs/replatform-brief.md §7).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "SightsAndSoundsKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "SightsAndSoundsApp",
            dependencies: ["SightsAndSoundsKit"],
            // Archivo (UI) and JetBrains Mono (every filename, path, count,
            // duration, size, timestamp, job kind and command) — the two
            // faces `design-tokens.md` specifies. Both OFL; the licences
            // ship beside them. `.copy` keeps the .ttf bytes intact —
            // `.process` would try to compile them.
            resources: [.copy("Resources/Fonts")]
        ),
        .testTarget(
            name: "SightsAndSoundsKitTests",
            dependencies: ["SightsAndSoundsKit"]
        ),
    ]
)
