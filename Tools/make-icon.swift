import AppKit
// Draws the Traceless icon: a glossy pinwheel whose last blade breaks into fading dots.
let s: CGFloat = 1024
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
let shadow = NSShadow(); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); shadow.set()
NSColor.white.setFill(); squircle.fill()
ctx.restoreGState()
NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(calibratedRed: 0.89, green: 0.92, blue: 0.96, alpha: 1)])!
  .draw(in: squircle, angle: -90)
let center = CGPoint(x: 470, y: 540), r: CGFloat = 250
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: 1) }
let blades: [NSColor] = [rgb(30,100,240), rgb(40,170,70), rgb(250,195,10), rgb(245,120,20), rgb(225,40,60), rgb(135,60,210)]
for (i, c) in blades.enumerated() {
  let a0 = CGFloat(i) / 6 * 360 + 90, a1 = a0 + 60
  let p = NSBezierPath(); p.move(to: center)
  p.appendArc(withCenter: center, radius: r, startAngle: a0, endAngle: a1); p.close()
  NSGradient(colors: [c.blended(withFraction: 0.18, of: .white)!, c.blended(withFraction: 0.12, of: .black)!])!
    .draw(in: p, relativeCenterPosition: NSPoint(x: -0.3, y: 0.4))
}
let ball = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r))
NSGradient(colors: [NSColor.white.withAlphaComponent(0.38), NSColor.white.withAlphaComponent(0)])!
  .draw(in: ball, relativeCenterPosition: NSPoint(x: -0.35, y: 0.45))
NSColor.black.withAlphaComponent(0.12).setStroke(); ball.lineWidth = 4; ball.stroke()
// trace dissolving away to the lower right
let dots: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
  (722, 398, 34, blades[5]), (776, 340, 26, blades[0]), (818, 293, 19, blades[1]),
  (850, 256, 13, blades[2]), (872, 228, 8, blades[3])]
for (i, d) in dots.enumerated() {
  d.3.withAlphaComponent(1 - CGFloat(i) * 0.17).setFill()
  NSBezierPath(ovalIn: CGRect(x: d.0 - d.2, y: d.1 - d.2, width: d.2*2, height: d.2*2)).fill()
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
