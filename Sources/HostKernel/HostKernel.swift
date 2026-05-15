import Foundation

/// The kernel namespace. Real types arrive in Phase 2 (Manifest + Registry).
/// For Phase 1 this is just a marker so the target compiles and HostShell can import it.
public enum HostKernel {
    public static let version = "0.1.0"
}
