// swift-tools-version: 6.0
import PackageDescription

// Velo Visualiser for macOS. Apple Silicon only, by design: the whole point is
// to lean on the newest graphics stack (Metal 4, macOS 26) rather than carry a
// compatibility path nobody on this project will use.
let package = Package(
    name: "Velo",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Velo",
            path: "Sources/Velo"
        )
    ]
)
