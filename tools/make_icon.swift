import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)]
let colors: [NSColor] = [.systemRed, .systemOrange, .systemGreen, .systemBlue]
for (name, px) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let bg = NSBezierPath(roundedRect: NSRect(x: s*0.1, y: s*0.1, width: s*0.8, height: s*0.8), xRadius: s*0.18, yRadius: s*0.18)
    NSGradient(starting: NSColor(white: 0.22, alpha: 1), ending: NSColor(white: 0.08, alpha: 1))!.draw(in: bg, angle: -90)
    let cell = s*0.26, gap = s*0.06, ox = s*0.5 - cell - gap/2, oy = s*0.5 - cell - gap/2
    for i in 0..<4 {
        let r = NSRect(x: ox + CGFloat(i%2)*(cell+gap), y: oy + CGFloat(1 - i/2)*(cell+gap), width: cell, height: cell)
        colors[i].setFill(); NSBezierPath(roundedRect: r, xRadius: cell*0.25, yRadius: cell*0.25).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
