import AppKit
import CoreGraphics

func bitmap(_ width:Int,_ height:Int,_ draw:(CGContext)->Void)->CGImage {
    let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    let old = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
    draw(context); NSGraphicsContext.current = old
    return context.makeImage()!
}
func save(_ image:CGImage,_ path:String) {
    try! NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path))
}
try! FileManager.default.createDirectory(atPath:"Resources/AppIcon.iconset",withIntermediateDirectories:true)
for size in [16,32,64,128,256,512,1024] {
    let image = bitmap(size,size) { c in
        c.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
        let rect = NSRect(x:24,y:24,width:976,height:976)
        NSGradient(colors:[NSColor(srgbRed:1,green:0.72,blue:0.30,alpha:1),NSColor(srgbRed:1,green:0.22,blue:0.10,alpha:1)])!.draw(in:NSBezierPath(roundedRect:rect,xRadius:220,yRadius:220),angle:-90)
        let center = CGPoint(x:512,y:512)
        for i in 0..<7 {
            let angle = Double(i)*2*Double.pi/7+Double.pi/2
            let p = NSBezierPath(); let r1:Double = 175,r2:Double = 380,gap = 0.07,half = Double.pi/7-gap
            p.appendArc(withCenter:center,radius:r2,startAngle:(angle-half)*180 / .pi,endAngle:(angle+half)*180 / .pi)
            p.appendArc(withCenter:center,radius:r1,startAngle:(angle+half)*180 / .pi,endAngle:(angle-half)*180 / .pi,clockwise:true); p.close()
            NSColor.white.withAlphaComponent(0.75).setFill(); p.fill()
        }
        NSColor.white.withAlphaComponent(0.9).setFill(); NSBezierPath(roundedRect:NSRect(x:395,y:465,width:234,height:94),xRadius:47,yRadius:47).fill()
    }
    if size <= 512 { save(image,"Resources/AppIcon.iconset/icon_\(size)x\(size).png") }
    if size >= 32 { save(image,"Resources/AppIcon.iconset/icon_\(size/2)x\(size/2)@2x.png") }
}
try! FileManager.default.createDirectory(atPath:"Tests/Fixtures",withIntermediateDirectories:true)
let page = bitmap(1200,1600) { c in
    c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x:0,y:0,width:1200,height:1600))
    let headline = "A little space for a big idea."
    headline.draw(at:NSPoint(x:100,y:1370),withAttributes:[.font:NSFont.systemFont(ofSize:52,weight:.bold),.foregroundColor:NSColor.black])
    "ORBITDROP  /  TEST DOCUMENT".draw(at:NSPoint(x:100,y:1480),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:18,weight:.medium),.foregroundColor:NSColor.gray])
    let lines = ["A file starts as a document. A gesture makes it an image.","Crop the part that matters. Add a little color.","Make something worth sharing.","","This is a local test fixture, created for this application.","The original always stays right where you left it."]
    for (i,line) in lines.enumerated() { line.draw(at:NSPoint(x:100,y:1270-CGFloat(i)*48),withAttributes:[.font:NSFont.systemFont(ofSize:25),.foregroundColor:NSColor.darkGray]) }
    let colors:[NSColor] = [.systemOrange,.systemPink,.systemPurple,.systemBlue]
    for (i,color) in colors.enumerated() {
        color.setFill(); NSBezierPath(roundedRect:NSRect(x:100+CGFloat(i%2)*510,y:160+CGFloat(i/2)*280,width:470,height:240),xRadius:22,yRadius:22).fill()
        "\(i+1)".draw(at:NSPoint(x:130+CGFloat(i%2)*510,y:190+CGFloat(i/2)*280),withAttributes:[.font:NSFont.systemFont(ofSize:36,weight:.bold),.foregroundColor:NSColor.white])
    }
}
save(page,"Tests/Fixtures/Sample.png")
let url = URL(fileURLWithPath:"Tests/Fixtures/Sample.pdf")
var media = CGRect(x:0,y:0,width:600,height:800)
let consumer = CGDataConsumer(url:url as CFURL)!
let pdf = CGContext(consumer:consumer,mediaBox:&media,nil)!
pdf.beginPDFPage(nil); pdf.draw(page,in:media); pdf.endPDFPage(); pdf.closePDF()
