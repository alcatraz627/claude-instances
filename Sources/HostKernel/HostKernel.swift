import Foundation

/// Kernel-wide constants. The host's own version is what plugin manifests'
/// `engines.claude-instances` range is matched against.
public enum HostKernel {
    /// Public semver of this V2 build. Plugin manifests compare against this.
    public static let version = "2.0.0"

    /// Parsed form of `version`. Crashes only on a programmer error (an
    /// invalid hard-coded version above), which is what we want.
    public static var semver: SemVer { SemVer(version)! }
}
