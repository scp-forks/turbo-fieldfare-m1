import Metal

/// GPU-family queries that compile against SDKs predating the family they name.
///
/// `MTLGPUFamily` gains cases over time, and referring to a case by name fails
/// to compile on an SDK that does not yet declare it. The raw values are stable
/// across SDKs, so constructing the family by raw value keeps a single source
/// tree buildable against both older and newer SDKs while still reporting the
/// correct answer at runtime on hardware that supports it.
public enum MetalGPUFamilyCompat {
    /// `MTLGPUFamily.apple10`, added in the macOS 26 SDK. Apple GPU family raw
    /// values are `1000 + n`, so Apple7 is 1007 and Apple10 is 1010.
    static let apple10RawValue = 1010

    /// Whether `device` is Apple10 (M5 generation) or newer.
    ///
    /// Returns `false` rather than trapping when the running Metal framework
    /// does not recognise the family, which is the correct answer on every
    /// pre-Apple10 GPU.
    public static func supportsApple10(_ device: MTLDevice) -> Bool {
        guard let family = MTLGPUFamily(rawValue: apple10RawValue) else {
            return false
        }
        return device.supportsFamily(family)
    }
}
