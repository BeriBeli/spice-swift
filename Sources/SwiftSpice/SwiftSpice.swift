#if !arch(arm64)
#error("SwiftSpice supports Apple Silicon (arm64) only.")
#endif

/// The public facade will be introduced with the connection/session milestone.
///
/// Stage A intentionally exposes no low-level wire API as supported public API.
public enum SwiftSpice {
    public static let protocolBaseline = "spice-protocol 0.14.5"
}
