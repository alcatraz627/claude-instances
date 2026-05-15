// swift-tools-version: 5.9
import PackageDescription

/// claude-instances V2 — the plugin platform.
///
/// HostKernel is the dumb-but-strict runtime: registry, manifest parsing, event bus,
/// surface routing. HostShell is the macOS NSApplication shell: NSStatusItem, dashboard
/// NSPanel, AppDelegate. Per-plugin modules will appear under `plugins/<id>/Sources/`
/// as V2 grows; the bundled-plugin registry compiles them into HostShell.
let package = Package(
    name: "claude-instances-v2",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HostShell", targets: ["HostShell"]),
        .executable(name: "manifest-test", targets: ["ManifestTest"]),
        .library(name: "HostKernel", targets: ["HostKernel"]),
    ],
    targets: [
        .target(
            name: "HostKernel",
            path: "Sources/HostKernel"
        ),
        .executableTarget(
            name: "HostShell",
            dependencies: ["HostKernel"],
            path: "Sources/HostShell"
        ),
        // CLI driver that exercises the manifest loader against fixtures.
        // Stand-in for unit tests until Xcode is installed.
        .executableTarget(
            name: "ManifestTest",
            dependencies: ["HostKernel"],
            path: "Sources/ManifestTest"
        ),
        // Tests require Xcode (XCTest / Swift Testing modules ship in the Xcode toolchain,
        // not in Command Line Tools alone). The test sources live in `Tests/HostKernelTests/`;
        // re-enable this target when Xcode is installed.
        // .testTarget(
        //     name: "HostKernelTests",
        //     dependencies: ["HostKernel"],
        //     path: "Tests/HostKernelTests"
        // ),
    ]
)
