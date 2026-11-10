// Renders docs/demo.gif from a touch_probe recording: the fingertip on the Magic Mouse (left) and the on-screen ink (right).
// The strokes are replayed from the recording, so the GIF shows real handwriting without capturing anyone's screen.
// Run: swift support/make_demo_gif.swift <recording.log> docs/demo.gif "F" "opens Finder"
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let (recPath, outPath, letter, action) = (args[1], args[2], args[3], args[4])

// Parse "t n=K [btn=B] [id=I st=S x=X y=Y sz=Z]" lines: first finger only.
struct Frame { let t: Double; let pt: CGPoint?; let id: Int }
var frames: [Frame] = []
let rx = try! NSRegularExpression(pattern: #"^([\d.]+) n=(\d+)(?:.*?\[id=(\d+) st=\d+ x=([\d.-]+) y=([\d.-]+))?"#)
for line in try! String(contentsOfFile: recPath, encoding: .utf8).split(separator: "\n") {
    let s = String(line)
    guard let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
    func g(_ i: Int) -> String? { Range(m.range(at: i), in: s).map { String(s[$0]) } }
    let t = Double(g(1)!)!
    if Int(g(2)!)! > 0, let x = g(4), let y = g(5) {
        frames.append(Frame(t: t, pt: CGPoint(x: Double(x)!, y: Double(y)!), id: Int(g(3)!)!))
    } else {
        frames.append(Frame(t: t, pt: nil, id: -1))
    }
}

let W = 600.0, H = 360.0, fps = 15.0
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])! }
let bg = rgb(244, 242, 238), ink = rgb(240, 96, 40), mouseFill = rgb(255, 255, 255), mouseEdge = rgb(200, 202, 210)
let screenFill = rgb(30, 34, 51), text = rgb(40, 42, 54), dim = rgb(120, 122, 130)

// Mouse surface (left) and ink box with the mouse's 10:15 proportions (right).
let mouse = CGRect(x: 60, y: 70, width: 160, height: 260)
let surface = mouse.insetBy(dx: 22, dy: 26)
let screen = CGRect(x: 270, y: 70, width: 300, height: 260)
let inkBox: CGRect = { let h = 200.0, w = h * 10 / 15; return CGRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h) }()
func onMouse(_ p: CGPoint) -> CGPoint { CGPoint(x: surface.minX + p.x * surface.width, y: surface.minY + p.y * surface.height) }
// The ink panel is zoomed to fit the letter (in physical proportions: the sensor is 10 x 15); the mouse panel is true scale.
let inkPts = frames.filter { $0.id != 99 }.compactMap { $0.pt }.map { CGPoint(x: $0.x * 10, y: $0.y * 15) }
let bb = inkPts.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
let zoom = min((screen.width - 120) / bb.width, (screen.height - 90) / bb.height)
func onScreen(_ p: CGPoint) -> CGPoint {
    CGPoint(x: screen.midX + (p.x * 10 - bb.midX) * zoom, y: screen.midY + 10 + (p.y * 15 - bb.midY) * zoom)
}

func drawText(_ ctx: CGContext, _ str: String, _ x: Double, _ y: Double, size: Double, color: CGColor, bold: Bool = false) {
    let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil)
    let attr = NSAttributedString(string: str, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                             kCTForegroundColorAttributeName as NSAttributedString.Key: color])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

// Strokes: runs of consecutive touches. The first run (id 99) is the tap.
let t0 = frames.first { $0.pt != nil }!.t
let lastTouch = frames.last { $0.pt != nil }!.t
let tapEnd = frames.first { $0.pt == nil && $0.t > t0 }!.t
let readAt = lastTouch + 0.5, end = readAt + 1.8

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.gif.identifier as CFString, Int(((end - t0 + 0.4) * fps).rounded(.up)), nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary

var t = t0 - 0.4
while t <= end {
    let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    // Panels
    ctx.addPath(CGPath(roundedRect: mouse, cornerWidth: 80, cornerHeight: 80, transform: nil))
    ctx.setFillColor(mouseFill); ctx.setStrokeColor(mouseEdge); ctx.setLineWidth(2); ctx.drawPath(using: .fillStroke)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(screenFill); ctx.fillPath()
    drawText(ctx, "Magic Mouse", mouse.minX + 32, 44, size: 15, color: dim)
    drawText(ctx, "On screen (zoomed)", screen.minX + 82, 44, size: 15, color: dim)

    // Ink so far, with pen-ups between strokes (the tap leaves no ink).
    let seen = frames.filter { $0.t <= min(t, lastTouch) && $0.t > tapEnd }
    for (map, width) in [(onMouse, 5.0), (onScreen, 9.0)] where t < readAt || width < 6 { // the app clears its ink once read
        ctx.setStrokeColor(ink); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        var penDown = false
        for f in seen {
            if let p = f.pt { if penDown { ctx.addLine(to: map(p)) } else { ctx.move(to: map(p)) }; penDown = true } else { penDown = false }
        }
        if t < readAt { ctx.strokePath() } else { ctx.setStrokeColor(rgb(240, 96, 40, 0.35)); ctx.strokePath() }
    }

    // Finger on the mouse, ring on screen.
    let now = frames.last { $0.t <= t }
    if let f = now, let p = f.pt, t <= lastTouch + 0.02 {
        let m = onMouse(p), s = onScreen(p)
        ctx.setFillColor(rgb(40, 42, 54, 0.28)); ctx.fillEllipse(in: CGRect(x: m.x - 15, y: m.y - 15, width: 30, height: 30))
        if f.id == 99 { // the tap: a ripple
            let r = 15 + (t - t0) / max(tapEnd - t0, 0.01) * 30
            ctx.setStrokeColor(rgb(240, 96, 40, 0.6)); ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: m.x - r, y: m.y - r, width: 2 * r, height: 2 * r))
        } else {
            ctx.setFillColor(rgb(255, 140, 50, 0.9)); ctx.fillEllipse(in: CGRect(x: s.x - 8, y: s.y - 8, width: 16, height: 16))
            ctx.setStrokeColor(rgb(255, 255, 255, 0.9)); ctx.setLineWidth(3); ctx.strokeEllipse(in: CGRect(x: s.x - 8, y: s.y - 8, width: 16, height: 16))
        }
    }

    // Result and caption.
    if t >= readAt {
        drawText(ctx, letter, screen.midX - 24, screen.midY - 10, size: 80, color: rgb(255, 255, 255), bold: true)
        drawText(ctx, "→ \(action)", screen.midX - 62, screen.minY + 40, size: 22, color: rgb(255, 180, 120))
    }
    let caption = t < t0 ? "" : t <= tapEnd + 0.15 ? "1. Tap the mouse" : t <= lastTouch ? "2. Draw \(letter), lifting between strokes" :
                  t < readAt ? "3. Lift, and it's read half a second later" : "\(letter) recognized, \(action)"
    drawText(ctx, caption, 60, 20, size: 18, color: text, bold: true)

    CGImageDestinationAddImage(dest, ctx.makeImage()!, frameProps)
    t += 1 / fps
}
precondition(CGImageDestinationFinalize(dest), "GIF write failed")
print("wrote \(outPath)")
