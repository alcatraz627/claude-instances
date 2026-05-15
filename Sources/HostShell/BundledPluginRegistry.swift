import Foundation
import HostKernel
import AboutPlugin
import OverviewPlugin
import EventsPlugin

/// Compile-time registry of every native plugin shipped inside the host
/// binary. Phase 4 has three pilots; later phases add more here as native
/// ports land. The dispatch happens by manifest id — the kernel Registry
/// loads JSON manifests from disk and asks this registry for matching
/// Swift instances.
@MainActor
public final class BundledPluginRegistry {
    public static let shared = BundledPluginRegistry()

    private var instances: [String: any Plugin] = [:]

    private init() {}

    /// Called once at app launch from `AppDelegate`. Adding a new native
    /// plugin = adding one `register(NewPlugin())` line here + adding the
    /// SPM target to Package.swift + dropping the manifest under
    /// `plugins/<id>/manifest.json`.
    public func bootstrap() {
        register(AboutPlugin())
        register(OverviewPlugin())
        register(EventsPlugin())
    }

    private func register<P: Plugin>(_ plugin: P) {
        instances[P.id] = plugin
    }

    public func instance(forId id: String) -> (any Plugin)? {
        instances[id]
    }

    public var allInstances: [(any Plugin)] {
        Array(instances.values)
    }
}
