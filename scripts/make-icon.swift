// Renders Burnless's app icon (ember bars on a dark tile) into an .icns.
// Usage: swift scripts/make-icon.swift app/Sources/Burnless/Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
  .appendingPathComponent("Burnless-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(size)
  // macOS icon grid: ~10% margin, continuous-corner tile.
  let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
  let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
  NSGradient(colors: [
    NSColor(red: 0.13, green: 0.12, blue: 0.14, alpha: 1),
    NSColor(red: 0.22, green: 0.17, blue: 0.16, alpha: 1),
  ])!.draw(in: path, angle: 90)
  // Three bars, the last one an ember that has stopped burning.
  let heights: [CGFloat] = [0.28, 0.44, 0.34]
  let colors = [
    NSColor(red: 0.95, green: 0.58, blue: 0.36, alpha: 1),
    NSColor(red: 0.42, green: 0.62, blue: 1.0, alpha: 1),
    NSColor(red: 1.0, green: 0.42, blue: 0.24, alpha: 1),
  ]
  let barWidth = s * 0.12
  let gap = s * 0.06
  let startX = s * 0.5 - (barWidth * 3 + gap * 2) / 2
  let baseY = s * 0.27
  for (index, height) in heights.enumerated() {
    let rect = NSRect(
      x: startX + CGFloat(index) * (barWidth + gap), y: baseY, width: barWidth, height: s * height)
    colors[index].setFill()
    NSBezierPath(roundedRect: rect, xRadius: barWidth * 0.3, yRadius: barWidth * 0.3).fill()
  }
  NSColor(white: 1, alpha: 0.18).setFill()
  NSBezierPath(rect: NSRect(x: s * 0.24, y: baseY - s * 0.035, width: s * 0.52, height: max(1, s * 0.012))).fill()
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
  try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
  try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(process.terminationStatus)
