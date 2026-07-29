import Metal

/// Selects the highest Metal Shading Language version the running OS accepts,
/// without naming enum cases that older SDKs do not declare.
///
/// Upstream compiles the runtime shader library at MSL 4.0, which the Metal 4
/// tensor-ops kernels require. `MTLLanguageVersion.version4_0` exists only in
/// the macOS 26 SDK and `.version3_2` only from the macOS 15 SDK, so naming
/// either one prevents the package from building against an older SDK.
///
/// `MTLLanguageVersion` raw values are stable and encoded as
/// `(major << 16) | minor`, so the newer versions can be constructed by raw
/// value on any SDK. Availability checks then keep the request within what the
/// running OS can actually compile: asking a macOS 14 Metal framework for MSL
/// 4.0 fails at `makeLibrary` time.
///
/// The practical effect is that one source tree serves every OS. On macOS 26
/// the shaders still build at MSL 4.0 and the tensor-ops kernels compile in; on
/// macOS 15 they build at 3.2; on macOS 14 at 3.1, where the tensor-ops kernels
/// are excluded by their own `#if defined(__HAVE_TENSOR__)` guard and the
/// runtime falls back to the baseline attention kernel.
public enum MetalLanguageVersionCompat {
    static let msl3_2RawValue: UInt = (3 << 16) | 2
    static let msl4_0RawValue: UInt = (4 << 16) | 0

    /// The best MSL version available on the current OS.
    public static var best: MTLLanguageVersion {
        if #available(macOS 26.0, iOS 26.0, *),
           let version = MTLLanguageVersion(rawValue: msl4_0RawValue) {
            return version
        }
        if #available(macOS 15.0, iOS 18.0, *),
           let version = MTLLanguageVersion(rawValue: msl3_2RawValue) {
            return version
        }
        return .version3_1
    }
}
