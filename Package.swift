// swift-tools-version: 6.0
import PackageDescription
import Foundation

let vendorSources = try! JSONDecoder().decode([String].self, from: Data(contentsOf:
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/WebRTCAudio/sources.json")))
let platformSources = ["Platform/FirFilterSSE.cpp", "Platform/SincResamplerSSE.cpp", "Platform/OouraFFTSSE.cpp"]
let audioDefines: [CSetting] = [.define("WEBRTC_MAC"), .define("WEBRTC_POSIX"),
    .define("WEBRTC_LIBRARY_IMPL"), .define("WEBRTC_ENABLE_SYMBOL_EXPORT"),
    .define("WEBRTC_APM_DEBUG_DUMP", to: "0"), .define("NDEBUG"),
    .headerSearchPath("."), .headerSearchPath("webrtc")]

let package = Package(
    name: "nfl-sound-recorder",
    platforms: [
        // Core Audio process taps require macOS 14.4+.
        .macOS("14.4")
    ],
    targets: [
        .target(name: "CWebRTCAudio", path: "Vendor/WebRTCAudio",
                sources: vendorSources.filter { !$0.hasPrefix("absl/random/") } + platformSources + ["TapDeckWebRTC.cpp"], publicHeadersPath: "include",
                cSettings: audioDefines + [.unsafeFlags(["-O2"])],
                cxxSettings: [.headerSearchPath("."), .headerSearchPath("webrtc"),
                    .unsafeFlags(["-O2", "-DWEBRTC_MAC", "-DWEBRTC_POSIX",
                        "-DWEBRTC_LIBRARY_IMPL", "-DWEBRTC_ENABLE_SYMBOL_EXPORT", "-DWEBRTC_APM_DEBUG_DUMP=0", "-DNDEBUG"])],
                linkerSettings: [.linkedFramework("Foundation")]),
        // Shared audio engine (tap + aggregate device + record/route IOProc).
        .target(
            name: "SoundRecorderKit",
            dependencies: ["CWebRTCAudio"],
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
        .executableTarget(
            name: "tapdeck-speaker-check",
            dependencies: ["SoundRecorderKit"]
        ),
        .testTarget(
            name: "SoundRecorderKitTests",
            dependencies: ["SoundRecorderKit"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
