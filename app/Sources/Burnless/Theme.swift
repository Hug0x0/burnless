// Visual primitives adapted from Agent Burn's Theme.swift
// (https://github.com/Melvynx/agent-burn, MIT, © 2025 ryoppippi, © 2026 Melvynx).

import BurnlessCore
import SwiftUI

enum BurnTheme {
  static let background = Color(nsColor: .windowBackgroundColor)
  static let muted = Color.secondary
  /// Burnless accent: a cooled ember, distinct from Agent Burn's flame.
  static let ember = adaptive(
    light: NSColor(red: 0.80, green: 0.30, blue: 0.16, alpha: 1),
    dark: NSColor(red: 1.00, green: 0.50, blue: 0.34, alpha: 1))
  static let card = adaptive(
    light: NSColor(white: 1, alpha: 0.9), dark: NSColor(white: 1, alpha: 0.055))
  static let cardStroke = adaptive(
    light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.08))
  static let track = adaptive(
    light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.1))
  static let hover = adaptive(
    light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.05))
  static let unknown = adaptive(
    light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.06))
  static let warning = adaptive(
    light: NSColor(red: 0.62, green: 0.38, blue: 0.0, alpha: 1), dark: .systemYellow)

  /// Stable series colors, identical in every chart, legend and card.
  static func color(for harness: Harness) -> Color {
    switch harness {
    case .claude:
      adaptive(
        light: NSColor(red: 0.85, green: 0.47, blue: 0.24, alpha: 1),
        dark: NSColor(red: 0.95, green: 0.58, blue: 0.36, alpha: 1))
    case .codex:
      adaptive(
        light: NSColor(red: 0.16, green: 0.42, blue: 0.86, alpha: 1),
        dark: NSColor(red: 0.42, green: 0.62, blue: 1.0, alpha: 1))
    }
  }

  static func symbol(for harness: Harness) -> String {
    switch harness {
    case .claude: "sparkle"
    case .codex: "chevron.left.forwardslash.chevron.right"
    }
  }

  private static func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      })
  }
}

struct BurnCardModifier: ViewModifier {
  var padding: CGFloat = 16
  var radius: CGFloat = 14
  func body(content: Content) -> some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(BurnTheme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(BurnTheme.cardStroke, lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
  }
}

extension View {
  func burnCard(padding: CGFloat = 16, radius: CGFloat = 14) -> some View {
    modifier(BurnCardModifier(padding: padding, radius: radius))
  }

  func hoverRow() -> some View { modifier(HoverRow()) }
}

struct IconBadge: View {
  let symbol: String
  var tint: Color = BurnTheme.ember
  var size: CGFloat = 22
  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.5, weight: .semibold))
      .foregroundStyle(tint)
      .frame(width: size, height: size)
      .background(
        tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
      )
      .accessibilityHidden(true)
  }
}

struct HarnessBadge: View {
  let harness: Harness
  var size: CGFloat = 22
  var body: some View {
    IconBadge(symbol: BurnTheme.symbol(for: harness), tint: BurnTheme.color(for: harness), size: size)
  }
}

struct CardHeader<Trailing: View>: View {
  let title: String
  var symbol: String? = nil
  var tint: Color = BurnTheme.ember
  @ViewBuilder var trailing: Trailing
  var body: some View {
    HStack(spacing: 8) {
      if let symbol { IconBadge(symbol: symbol, tint: tint) }
      Text(title).font(.system(size: 13, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      trailing.font(.system(size: 11)).foregroundStyle(BurnTheme.muted)
    }
  }
}

extension CardHeader where Trailing == EmptyView {
  init(title: String, symbol: String? = nil, tint: Color = BurnTheme.ember) {
    self.init(title: title, symbol: symbol, tint: tint) { EmptyView() }
  }
}

struct MetricTile<Accessory: View>: View {
  let title: String
  let value: String
  var detail = ""
  var symbol: String? = nil
  var tint: Color = BurnTheme.ember
  @ViewBuilder var accessory: Accessory
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        if let symbol { IconBadge(symbol: symbol, tint: tint, size: 20) }
        Text(title).font(.system(size: 12, weight: .medium))
          .foregroundStyle(BurnTheme.muted).lineLimit(1)
        Spacer(minLength: 0)
        accessory
      }
      Text(value)
        .font(.system(size: 24, weight: .semibold, design: .rounded))
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        .contentTransition(.numericText())
        .animation(.snappy, value: value)
      if !detail.isEmpty {
        Text(detail).font(.system(size: 11))
          .foregroundStyle(BurnTheme.muted).lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

extension MetricTile where Accessory == EmptyView {
  init(title: String, value: String, detail: String = "", symbol: String? = nil, tint: Color = BurnTheme.ember) {
    self.init(title: title, value: value, detail: detail, symbol: symbol, tint: tint) { EmptyView() }
  }
}

struct ShareBar: View {
  let value: Double
  var tint: Color = BurnTheme.ember
  var height: CGFloat = 5
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(BurnTheme.track)
        Capsule().fill(tint.gradient)
          .frame(width: max(height, geometry.size.width * clamped))
          .opacity(clamped > 0 ? 1 : 0)
      }
    }
    .frame(height: height)
    .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: clamped)
    .accessibilityHidden(true)
  }
  private var clamped: Double { max(0, min(1, value)) }
}

struct HoverRow: ViewModifier {
  @State private var hovering = false
  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(
        hovering ? BurnTheme.hover : .clear,
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
  }
}

struct Notice: View {
  enum Kind { case info, warning }
  let message: String
  var kind: Kind = .info
  var symbol: String? = nil
  var body: some View {
    let tint = kind == .warning ? BurnTheme.warning : BurnTheme.muted
    Label(message, systemImage: symbol ?? (kind == .warning ? "exclamationmark.triangle" : "info.circle"))
      .font(.system(size: 12)).foregroundStyle(tint)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 12).padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        (kind == .warning ? BurnTheme.warning : Color.secondary).opacity(0.08),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}
