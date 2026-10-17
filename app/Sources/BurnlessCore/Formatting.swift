import Foundation

public enum Format {
  public static func currency(_ value: Double) -> String {
    value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(2)))
  }

  /// Compact token count: 1.2K, 3.4M, 5.67B.
  public static func tokens(_ value: UInt64) -> String {
    let number = Double(value)
    if number >= 1_000_000_000 { return String(format: "%.2fB", number / 1_000_000_000) }
    if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
    if number >= 1000 { return String(format: "%.1fK", number / 1000) }
    return String(value)
  }

  public static func fullTokens(_ value: UInt64) -> String {
    value.formatted(.number.locale(Locale(identifier: "en_US")))
  }

  public static func percent(_ value: Double) -> String {
    value.formatted(.percent.locale(Locale(identifier: "en_US")).precision(.fractionLength(1)))
  }

  /// Spend with an explicit marker when part of the usage has no price.
  public static func spend(_ totals: SpendTotals) -> String {
    currency(totals.cost) + (totals.isPartial ? "+" : "")
  }
}
