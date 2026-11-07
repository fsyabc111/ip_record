import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.32, alpha: 1).setFill()
    NSBezierPath(
      roundedRect: NSRect(x: 0, y: 0, width: pixels, height: pixels).insetBy(
        dx: Double(pixels) * 0.04, dy: Double(pixels) * 0.04), xRadius: Double(pixels) * 0.21,
      yRadius: Double(pixels) * 0.21
    ).fill()
    let symbol = NSImage(systemSymbolName: "network", accessibilityDescription: nil)!
    let config = NSImage.SymbolConfiguration(pointSize: Double(pixels) * 0.65, weight: .medium)
      .applying(.init(paletteColors: [.white]))
    symbol.withSymbolConfiguration(config)?.draw(
      in: NSRect(
        x: Double(pixels) * 0.18, y: Double(pixels) * 0.18, width: Double(pixels) * 0.64,
        height: Double(pixels) * 0.64))
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: directory.appendingPathComponent(name))
  }
}
