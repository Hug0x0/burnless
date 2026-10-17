// Visual primitives adapted from Agent Burn's Theme.swift
// (https://github.com/Melvynx/agent-burn, MIT, © 2025 ryoppippi, © 2026 Melvynx).

import BurnlessCore
import SwiftUI

enum BurnTheme {
  static let background = Color(nsColor: .windowBackgroundColor)
  static let muted = Color.secondary
  /// Accent: Agent Burn's flame.
  static let ember = adaptive(
    light: NSColor(red: 0.86, green: 0.36, blue: 0.05, alpha: 1),
    dark: NSColor(red: 1, green: 0.52, blue: 0.2, alpha: 1))
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
  /// Recessed panels inside a card.
  static let inset = adaptive(
    light: NSColor(white: 0, alpha: 0.025), dark: NSColor(white: 0, alpha: 0.16))
  static let line = Color(nsColor: .separatorColor).opacity(0.5)
  static let grid = Color(nsColor: .separatorColor)
  // Pace status: remaining above even pace is ahead, below is behind.
  static let ahead = Color.green
  static let behind = Color.red
  /// Muted text that stays legible on menu material in both appearances.
  static let quotaMuted = adaptive(
    light: NSColor(white: 0.38, alpha: 1), dark: NSColor(white: 0.68, alpha: 1))

  /// Tone for a remaining share: red under 15%, orange under 35%.
  static func tone(remaining: Double) -> Color {
    remaining < 15 ? behind : remaining < 35 ? .orange : .green
  }

  /// Stable series colors, as in Agent Burn: Claude orange, Codex green.
  static func color(for harness: Harness) -> Color {
    switch harness {
    case .claude: .orange
    case .codex: .green
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

/// Resources live in SwiftPM's bundle. Inside Burnless.app it is copied to
/// Contents/Resources and found through the main bundle; `swift run` falls
/// back to `Bundle.module`.
enum ResourceBundle {
  static let bundle: Bundle =
    Bundle.main.url(forResource: "Burnless_Burnless", withExtension: "bundle")
    .flatMap { Bundle(url: $0) } ?? Bundle.module
}

@MainActor enum BrandImages {
  // Provider logos from Agent Burn (exported from the installed Claude and
  // ChatGPT macOS apps). They identify the integrations; no endorsement.
  static let images: [Harness: NSImage] = Dictionary(
    uniqueKeysWithValues: Harness.allCases.compactMap { harness in
      guard
        let url = ResourceBundle.bundle.url(
          forResource: harness.rawValue, withExtension: "png", subdirectory: "Brands"),
        let image = NSImage(contentsOf: url)
      else { return nil }
      return (harness, image)
    })
}

struct HarnessBadge: View {
  let harness: Harness
  var size: CGFloat = 22
  var body: some View {
    Group {
      if let image = BrandImages.images[harness] {
        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
      } else {
        IconBadge(symbol: BurnTheme.symbol(for: harness), tint: BurnTheme.color(for: harness), size: size)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
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

struct StatusBadge: View {
  let text: String
  var color: Color = .green
  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 5, height: 5)
      Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
    }
    .foregroundStyle(color)
    .padding(.horizontal, 9).padding(.vertical, 5)
    .background(color.opacity(0.09), in: Capsule())
  }
}

struct SectionLabel: View {
  let title: String
  var detail: String = ""
  var body: some View {
    HStack {
      Text(title).font(.system(size: 13, weight: .semibold))
      Spacer()
      if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(BurnTheme.muted) }
    }
  }
}

/// Small quota pill: "62%" tinted by how much is left.
struct QuotaBadge: View {
  let remaining: Double
  var body: some View {
    let tone = BurnTheme.tone(remaining: remaining)
    Text("\(Int(remaining.rounded(.down)))%")
      .font(.system(size: 10, weight: .semibold)).monospacedDigit()
      .foregroundStyle(tone)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(tone.opacity(0.14), in: Capsule())
  }
}
