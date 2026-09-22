// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "nfl-sound-recorder",
    platforms: [
        // Core Audio process taps require macOS 14.4+.
        .macOS("14.4")
    ],
    targets: [
        // Shared audio engine (tap + aggregate device + record/route IOProc).
        .target(
            name: "SoundRecorderKit",
            path: "Sources/SoundRecorderKit"
        ),
        // Command-line front end.
        .executableTarget(
            name: "nfl-sound-recorder",
            dependencies: ["SoundRecorderKit"],
            path: "Sources/nfl-sound-recorder"
        ),
        // Menu bar app front end.
        .executableTarget(
            name: "NFLSoundRecorderApp",
            dependencies: ["SoundRecorderKit"],
            path: "Sources/NFLSoundRecorderApp"
        ),
        // MCP server front end (JSON-RPC over stdio; no external deps).
        .executableTarget(
            name: "nfl-sound-recorder-mcp",
            dependencies: ["SoundRecorderKit"],
            path: "Sources/NFLSoundRecorderMCP"
        ),
        .testTarget(
            name: "SoundRecorderKitTests",
            dependencies: ["SoundRecorderKit"]
        ),
    ]
)
