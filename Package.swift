// swift-tools-version: 6.0
import PackageDescription

// Velo Visualiser for macOS. Apple Silicon only, by design: the whole point is
// to lean on the newest graphics stack (Metal 4, macOS 26) rather than carry a
// compatibility path nobody on this project will use.
let package = Package(
    name: "Velo",
    platforms: [.macOS("26.0")],
    targets: [
        // Ableton Link C++ bridge. Compiled with exceptions/RTTI so Link's
        // internals work, and exposes a flat C API via LinkBridge.h. The
        // Link library is header-only (vendored in Vendor/link/); ASIO
        // (standalone, networking) is its sole dependency.
        .target(
            name: "CLinkBridge",
            path: "Sources/CLinkBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../Vendor/link/include"),
                .headerSearchPath("../../Vendor/link/modules/asio-standalone/asio/include"),
                .define("LINK_PLATFORM_MACOSX", to: "1"),
                .unsafeFlags(["-Wno-deprecated-literal-operator"]),
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
            ]
        ),

        // Vendored Syphon Metal server (BSD 2-Clause). Compiled from source
        // so we don't need a pre-built framework or the Metal CLI toolchain.
        // The shader is compiled at runtime from an inline string.
        .target(
            name: "CSyphon",
            path: "Sources/CSyphon",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .unsafeFlags(["-include", "SyphonPrefix.h"]),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("IOSurface"),
            ]
        ),

        .executableTarget(
            name: "Velo",
            dependencies: ["CLinkBridge", "CSyphon"],
            path: "Sources/Velo"
        )
    ]
)
