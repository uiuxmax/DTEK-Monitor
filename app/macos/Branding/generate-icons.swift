// Deterministic vector artwork. Run only by the macOS app resource build phase.
// No application launch, provider, profile, Login Item or system-setting access.
import AppKit
import Foundation

guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--output-directory",
      CommandLine.arguments[2].hasPrefix("/") else { fatalError("Expected an absolute build resource directory") }
let output=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
let manager=FileManager.default
try manager.createDirectory(at:output,withIntermediateDirectories:true)
let temporary=manager.temporaryDirectory.appendingPathComponent("dtekmonitor-icons-"+UUID().uuidString,isDirectory:true)
try manager.createDirectory(at:temporary,withIntermediateDirectories:false)
defer { try? manager.removeItem(at:temporary) }
let iconset=temporary.appendingPathComponent("DTEKMonitor.iconset",isDirectory:true)
try manager.createDirectory(at:iconset,withIntermediateDirectories:false)

func polygon(_ points: [(CGFloat,CGFloat)]) -> NSBezierPath {
    let path=NSBezierPath()
    path.move(to:NSPoint(x:points[0].0,y:points[0].1))
    for point in points.dropFirst() { path.line(to:NSPoint(x:point.0,y:point.1)) }
    path.close(); return path
}
func png(_ size: Int, canvas: CGFloat, draw: () -> Void) throws -> Data {
    guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,
        samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
        let context=NSGraphicsContext(bitmapImageRep:bitmap) else { fatalError("Cannot allocate icon bitmap") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=context
    context.cgContext.clear(CGRect(x:0,y:0,width:CGFloat(size),height:CGFloat(size)))
    context.cgContext.scaleBy(x:CGFloat(size)/canvas,y:CGFloat(size)/canvas)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    guard let data=bitmap.representation(using:.png,properties:[:]) else { fatalError("Cannot encode icon PNG") }
    return data
}
func appArtwork() {
    let tile=NSBezierPath(roundedRect:NSRect(x:80,y:80,width:864,height:864),xRadius:192,yRadius:192)
    NSGraphicsContext.saveGraphicsState()
    let shadow=NSShadow(); shadow.shadowColor=NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius=22; shadow.shadowOffset=NSSize(width:0,height:-10); shadow.set()
    NSColor(calibratedRed:0.05,green:0.22,blue:0.24,alpha:1).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting:NSColor(calibratedRed:0.12,green:0.43,blue:0.39,alpha:1),
        ending:NSColor(calibratedRed:0.035,green:0.15,blue:0.20,alpha:1))!.draw(in:tile,angle:-70)
    NSColor.white.withAlphaComponent(0.20).setStroke(); tile.lineWidth=3; tile.stroke()
    let bolt=polygon([(588,832),(300,448),(475,448),(420,192),(728,594),(550,594),(650,832)])
    NSGraphicsContext.saveGraphicsState()
    let boltShadow=NSShadow(); boltShadow.shadowColor=NSColor.black.withAlphaComponent(0.30)
    boltShadow.shadowBlurRadius=12; boltShadow.shadowOffset=NSSize(width:0,height:-9); boltShadow.set()
    NSColor.systemYellow.setFill(); bolt.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting:NSColor(calibratedRed:1,green:0.91,blue:0.43,alpha:1),
        ending:NSColor(calibratedRed:1,green:0.62,blue:0.06,alpha:1))!.draw(in:bolt,angle:-90)
    NSColor(calibratedRed:1,green:0.96,blue:0.68,alpha:0.60).setStroke(); bolt.lineWidth=3; bolt.stroke()
}
func menuArtwork() {
    let disc=NSBezierPath(ovalIn:NSRect(x:0.75,y:0.75,width:18.5,height:18.5))
    NSColor(calibratedRed:1,green:0.72,blue:0.12,alpha:1).setFill(); disc.fill()
    NSColor(calibratedWhite:0.10,alpha:1).setStroke(); disc.lineWidth=0.8; disc.stroke()
    NSColor(calibratedWhite:0.08,alpha:1).setFill()
    polygon([(11.1,17),(5.2,8.7),(8.9,8.7),(8.0,3),(14.8,11.6),(10.9,11.6),(12.9,17)]).fill()
}

for points in [16,32,128,256,512] {
    for scale in [1,2] {
        let suffix=scale == 2 ? "@2x" : ""
        let name="icon_\(points)x\(points)\(suffix).png"
        try png(points*scale,canvas:1024,draw:appArtwork).write(to:iconset.appendingPathComponent(name),options:.atomic)
    }
}
let compiled=temporary.appendingPathComponent("DTEKMonitor.icns")
let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/iconutil")
process.arguments=["-c","icns","-o",compiled.path,iconset.path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
let icon=try Data(contentsOf:compiled)
guard icon.count>8,icon.prefix(4)==Data("icns".utf8) else { fatalError("Invalid ICNS output") }
try icon.write(to:output.appendingPathComponent("DTEKMonitor.icns"),options:.atomic)
try png(40,canvas:20,draw:menuArtwork).write(to:output.appendingPathComponent("DTEKMenuBarIcon.png"),options:.atomic)
print("Generated app ICNS (ten 1x/2x representations) and 40px menu bar artwork")
