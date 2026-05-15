// swift-tools-version: 5.9
import PackageDescription

/// claude-instances V2 — the plugin platform.
///
/// HostKernel is the dumb-but-strict runtime: registry, manifest parsing,
/// event bus, surface routing. HostShell is the macOS NSApplication shell:
/// NSStatusItem, dashboard NSPanel, AppDelegate. Each native plugin is its
/// own SPM target under `plugins/<id>/` (clean module boundary, manifest
/// next to code). HostShell depends on every native plugin; the bundled
/// registry instantiates them at startup.
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
        // Native plugins. Each is a tiny standalone target that compiles
        // its `Plugin.swift` against HostKernel and exposes one Plugin class.
        .target(
            name: "AboutPlugin",
            dependencies: ["HostKernel"],
            path: "plugins/about",
            sources: ["Plugin.swift"]
        ),
        .target(
            name: "OverviewPlugin",
            dependencies: ["HostKernel"],
            path: "plugins/overview",
            sources: ["Plugin.swift"]
        ),
        .target(
            name: "EventsPlugin",
            dependencies: ["HostKernel"],
            path: "plugins/events",
            sources: ["Plugin.swift"]
        ),
        .executableTarget(
            name: "HostShell",
            dependencies: [
                "HostKernel",
                "AboutPlugin",
                "OverviewPlugin",
                "EventsPlugin",
            ],
            path: "Sources/HostShell"
        ),
        .executableTarget(
            name: "ManifestTest",
            dependencies: ["HostKernel"],
            path: "Sources/ManifestTest"
        ),
        // Tests require Xcode (XCTest / Swift Testing modules ship in the Xcode toolchain,
        // not in Command Line Tools alone). Sources sit in `Tests/HostKernelTests/`;
        // re-enable when Xcode is installed.
        // .testTarget(
        //     name: "HostKernelTests",
        //     dependencies: ["HostKernel"],
        //     path: "Tests/HostKernelTests"
        // ),
    ]
)
