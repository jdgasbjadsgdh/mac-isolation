import AppKit

let output = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.12, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 210, yRadius: 210).fill()
NSColor(calibratedRed: 0.38, green: 0.89, blue: 0.74, alpha: 0.28).setFill()
NSBezierPath(roundedRect: NSRect(x: 245, y: 195, width: 575, height: 500), xRadius: 65, yRadius: 65).fill()
let mint = NSColor(calibratedRed: 0.40, green: 0.90, blue: 0.75, alpha: 1)
mint.setStroke()
let back = NSBezierPath(roundedRect: NSRect(x: 200, y: 310, width: 550, height: 460), xRadius: 60, yRadius: 60)
back.lineWidth = 36
back.stroke()
NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.18, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 310, y: 225, width: 540, height: 440), xRadius: 60, yRadius: 60).fill()
mint.setFill()
NSBezierPath(roundedRect: NSRect(x: 345, y: 260, width: 470, height: 370), xRadius: 32, yRadius: 32).fill()
NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.23, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 390, y: 550, width: 130, height: 20), xRadius: 10, yRadius: 10).fill()
image.unlockFocus()
let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: output))
