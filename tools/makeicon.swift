import AppKit
import CoreGraphics

// AndrOS ikonu: koyu zemin uzerinde telefon silueti + yansiyan ekran isigi.
func drawIcon(size: CGFloat, ctx: CGContext) {
    let s = size
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Yuvarlatilmis kare zemin (macOS ikon oranlari)
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - inset*2, height: s - inset*2)
    let radius = rect.width * 0.2237
    let bg = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.09, green: 0.13, blue: 0.18, alpha: 1),
        CGColor(red: 0.05, green: 0.07, blue: 0.10, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    ctx.restoreGState()

    // Telefon govdesi (dikey, yesil kenarlik)
    let pw = s * 0.25, ph = s * 0.50
    let phone = CGRect(x: s*0.11, y: (s - ph)/2, width: pw, height: ph)
    let phonePath = CGPath(roundedRect: phone, cornerWidth: pw*0.16, cornerHeight: pw*0.16, transform: nil)
    ctx.addPath(phonePath)
    ctx.setFillColor(CGColor(red: 0.24, green: 0.80, blue: 0.52, alpha: 1))
    ctx.fillPath()

    // Ekran
    let inner = phone.insetBy(dx: pw*0.09, dy: ph*0.06)
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: pw*0.09, cornerHeight: pw*0.09, transform: nil))
    ctx.setFillColor(CGColor(red: 0.06, green: 0.09, blue: 0.12, alpha: 1))
    ctx.fillPath()

    // Yansiyan monitor (saga dogru, beyaz cerceve)
    let mw = s * 0.38, mh = s * 0.26
    let mon = CGRect(x: s*0.50, y: (s - mh)/2 + s*0.035, width: mw, height: mh)
    ctx.setLineWidth(s * 0.032)
    ctx.setStrokeColor(CGColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1))
    ctx.addPath(CGPath(roundedRect: mon, cornerWidth: s*0.028, cornerHeight: s*0.028, transform: nil))
    ctx.strokePath()
    // Ayak
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: mon.midX, y: mon.minY))
    ctx.addLine(to: CGPoint(x: mon.midX, y: mon.minY - s*0.055))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: mon.midX - s*0.075, y: mon.minY - s*0.055))
    ctx.addLine(to: CGPoint(x: mon.midX + s*0.075, y: mon.minY - s*0.055))
    ctx.strokePath()

    // Akis oku: telefondan monitore
    ctx.setStrokeColor(CGColor(red: 0.24, green: 0.80, blue: 0.52, alpha: 1))
    ctx.setLineWidth(s * 0.030)
    let ay = s * 0.50
    let ax0 = phone.maxX + s*0.035, ax1 = mon.minX - s*0.035
    ctx.move(to: CGPoint(x: ax0, y: ay))
    ctx.addLine(to: CGPoint(x: ax1, y: ay))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: ax1 - s*0.042, y: ay + s*0.038))
    ctx.addLine(to: CGPoint(x: ax1, y: ay))
    ctx.addLine(to: CGPoint(x: ax1 - s*0.042, y: ay - s*0.038))
    ctx.strokePath()
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AndrOS.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let specs: [(Int, String)] = [
    (16,"icon_16x16"), (32,"icon_16x16@2x"), (32,"icon_32x32"), (64,"icon_32x32@2x"),
    (128,"icon_128x128"), (256,"icon_128x128@2x"), (256,"icon_256x256"),
    (512,"icon_256x256@2x"), (512,"icon_512x512"), (1024,"icon_512x512@2x"),
]
for (px, name) in specs {
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    drawIcon(size: CGFloat(px), ctx: ctx)
    guard let img = ctx.makeImage() else { continue }
    let url = URL(fileURLWithPath: "\(out)/\(name).png")
    let rep = NSBitmapImageRep(cgImage: img)
    if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
}
print("iconset hazir: \(out)")
