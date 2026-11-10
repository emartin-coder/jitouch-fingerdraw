// Draws the 1024px app icon: Magic Mouse seen from above, with a fingertip stroke drawing a letter.
// Run: swift make_icon.swift icon_1024.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])!
}
func linear(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
}

// Background: Apple's 824pt rounded square on a 1024 canvas, deep blue to violet.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(30, 34, 80)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
linear([rgb(62, 76, 190), rgb(36, 30, 92)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
ctx.restoreGState()

// Magic Mouse body: a tall pill with a soft shadow and a light top-to-bottom sheen.
let mouse = CGRect(x: 337, y: 205, width: 350, height: 590)
let mousePath = CGPath(roundedRect: mouse, cornerWidth: 175, cornerHeight: 175, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0, 0, 20, 0.5))
ctx.addPath(mousePath); ctx.setFillColor(rgb(245, 246, 250)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(mousePath); ctx.clip()
linear([rgb(255, 255, 255), rgb(214, 218, 230)], from: CGPoint(x: 512, y: 795), to: CGPoint(x: 512, y: 205))
ctx.restoreGState()

// Fingertip stroke: a handwritten loop letter drawn on the mouse surface.
let stroke = CGMutablePath()
stroke.move(to: CGPoint(x: 420, y: 470))
stroke.addCurve(to: CGPoint(x: 575, y: 625), control1: CGPoint(x: 490, y: 480), control2: CGPoint(x: 585, y: 545))
stroke.addCurve(to: CGPoint(x: 515, y: 700), control1: CGPoint(x: 572, y: 690), control2: CGPoint(x: 540, y: 705))
stroke.addCurve(to: CGPoint(x: 502, y: 560), control1: CGPoint(x: 478, y: 690), control2: CGPoint(x: 482, y: 610))
stroke.addCurve(to: CGPoint(x: 625, y: 445), control1: CGPoint(x: 512, y: 420), control2: CGPoint(x: 585, y: 375))
ctx.saveGState()
ctx.addPath(stroke)
ctx.setLineWidth(34); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.replacePathWithStrokedPath(); ctx.clip()
linear([rgb(255, 160, 60), rgb(240, 80, 40)], from: CGPoint(x: 400, y: 700), to: CGPoint(x: 630, y: 380))
ctx.restoreGState()

// Fingertip at the end of the stroke: glow ring plus solid dot.
let tip = CGPoint(x: 625, y: 445)
ctx.setFillColor(rgb(255, 120, 50, 0.28))
ctx.fillEllipse(in: CGRect(x: tip.x - 46, y: tip.y - 46, width: 92, height: 92))
ctx.setFillColor(rgb(255, 255, 255))
ctx.fillEllipse(in: CGRect(x: tip.x - 25, y: tip.y - 25, width: 50, height: 50))
ctx.setFillColor(rgb(240, 80, 40))
ctx.fillEllipse(in: CGRect(x: tip.x - 15, y: tip.y - 15, width: 30, height: 30))

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest), "PNG write failed")
