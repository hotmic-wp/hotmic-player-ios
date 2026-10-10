import Foundation

/// Compact social counts: exact below 1,000; K, M and B for larger values.
/// Rounds half up to one decimal, omits trailing .0 and rolls 1000K/M up to 1M/B.
/// Digits and decimal separator follow locale; suffixes are fixed. Negatives clamp to zero.
public struct HMCountFormatter: Sendable {
    /// Locale used for digits and the decimal separator; suffixes remain K, M and B.
    public var locale: Locale
    /// Creates a formatter using the supplied locale, or the user's current locale.
    public init(locale: Locale = .current) { self.locale = locale }
    /// Formats an exact small count or a rounded compact social count; negatives clamp to zero.
    public func string(from count: Int) -> String {
        let count = max(0, count)
        let divisor = count < 1_000 ? 1 : (count < 999_950 ? 1_000 : (count < 999_950_000 ? 1_000_000 : 1_000_000_000))
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = divisor == 1 ? 0 : 1
        formatter.roundingMode = .halfUp
        let number = NSDecimalNumber(value: count).dividing(by: NSDecimalNumber(value: divisor))
        return (formatter.string(from: number) ?? "0") + (divisor == 1 ? "" : (divisor == 1_000 ? "K" : (divisor == 1_000_000 ? "M" : "B")))
    }
}
