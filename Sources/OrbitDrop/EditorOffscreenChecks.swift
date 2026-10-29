import AppKit
import CoreGraphics

/// Optional native-editor QA. It only constructs hidden windows and dispatches
/// actions directly to controls. It never shows, orders, or activates a window.
/// Run from a CLI host on the main thread after initializing NSApplication.shared.
public enum EditorOffscreenChecks {
    public static func run(outputDirectory: URL) throws -> [String] {
        precondition(Thread.isMainThread)
        try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
        var results: [String] = []
        let source = outputDirectory.appendingPathComponent("Page 001.jpg")
        let fixture = try makeFixture()
        let transparentContext = try require(CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),"Alpha fixture")
        let transparent = try require(transparentContext.makeImage(),"Transparent source")
        let background = try require(ODBackgroundRenderer.render(image:transparent,style:.init(name:"White",colors:[.white]),padding:16,corner:12,shadow:24,ratio:nil),"Transparent background render")
        let sample = try require(CGContext(data:nil,width:96,height:96,bitsPerComponent:8,bytesPerRow:96*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),"Alpha sample")
        sample.draw(background,in:CGRect(x:0,y:0,width:96,height:96))
        let bytes = sample.data!.assumingMemoryBound(to:UInt8.self)
        let offset = (48*96+48)*4
        try check((0..<4).allSatisfy { bytes[offset+$0] == 255 },"Transparent input must reveal the background, including with shadow enabled")
        results.append("Add BG: transparent PNG alpha retained; no opaque plate beneath shadow")
        try MediaEngine.writeImage(fixture,format:"jpg",to:source,quality:1)
        let coordinator = EditorCoordinator()
        defer { coordinator.openWindows.forEach { $0.close() } }

        var cropResult: URL?
        let crop = try coordinator.makeOffscreenWindow(action:"crop",url:source,onSaved:{ cropResult = $0 })
        let canvas = try require(find("editor.crop.canvas",in:crop.contentView!) as? ODCropCanvas,"Missing crop canvas")
        let ratios = try require(find("editor.crop.ratio",in:crop.contentView!) as? NSSegmentedControl,"Missing crop ratios")
        // Dispatch synthetic events straight to the hidden view, never to the desktop.
        try drag(canvas,from:CGPoint(x:10,y:81.5),to:CGPoint(x:40,y:111.5),window:crop)
        try check(canvas.selection.minX > 80 && canvas.selection.minY > 80,"Crop corner handle resize")
        let beforeMove = canvas.selection
        try drag(canvas,from:CGPoint(x:190,y:220),to:CGPoint(x:180,y:210),window:crop)
        try check(canvas.selection.width == beforeMove.width && canvas.selection.minX < beforeMove.minX,"Move crop selection")
        for (index,expected) in [(1,CGFloat(1)),(2,16.0/9),(3,9.0/16),(4,4.0/3),(5,3.0/4)] {
            canvas.reset()
            ratios.selectedSegment = index
            ratios.sendAction(ratios.action,to:ratios.target)
            try check(abs(canvas.selection.width/canvas.selection.height-expected)<0.0001,"Crop ratio \(index)")
        }
        canvas.reset()
        ratios.selectedSegment = 0
        ratios.sendAction(ratios.action,to:ratios.target)
        canvas.selection = CGRect(x:160,y:100,width:640,height:480)
        try snapshot(crop,to:outputDirectory.appendingPathComponent("crop-panel.png"))
        try save(crop,id:"editor.crop.save",result:{ cropResult })
        let croppedURL = try require(cropResult,"No crop callback")
        try check(croppedURL.pathExtension == "jpg","Crop must preserve JPEG")
        try check(croppedURL.lastPathComponent.contains(" Cropped"),"Crop suffix")
        let cropped = try MediaEngine.loadImage(croppedURL)
        try check(cropped.width == 640 && cropped.height == 480,"Free crop pixel dimensions")
        results.append("Crop: corner drag, selection move, five fixed ratios, free crop, Apply callback, JPEG preservation, 640×480 export")

        var wideResult: URL?
        let wide = try coordinator.makeOffscreenWindow(action:"crop",url:source,onSaved:{ wideResult = $0 })
        let wideCanvas = try require(find("editor.crop.canvas",in:wide.contentView!) as? ODCropCanvas,"Missing crop canvas")
        wideCanvas.selection = CGRect(x:160,y:100,width:640,height:480)
        let wideRatios = try require(find("editor.crop.ratio",in:wide.contentView!) as? NSSegmentedControl,"Missing crop ratios")
        wideRatios.selectedSegment = 2; wideRatios.sendAction(wideRatios.action,to:wideRatios.target)
        try save(wide,id:"editor.crop.save",result:{ wideResult })
        let wideImage = try MediaEngine.loadImage(try require(wideResult,"No 16:9 crop callback"))
        try check(wideImage.width == 640 && wideImage.height == 360,"16:9 crop export dimensions")
        results.append("Crop: actual 16:9 Apply export is 640×360")

        for (index,name,expectedWidth,expectedHeight) in [(0,"auto",960,800),(1,"square",960,960),(2,"wide",1422,800),(3,"portrait",960,1200)] {
            var saved: URL?
            let window = try coordinator.makeOffscreenWindow(action:"background",url:croppedURL,onSaved:{ saved = $0 })
            let control = try require(find("editor.background.ratio",in:window.contentView!) as? NSSegmentedControl,"Missing background ratio")
            for (id,expected) in [("padding",160.0),("corners",184.0),("shadow",24.0)] {
                let slider = try require(find("editor.background.\(id)",in:window.contentView!) as? NSSlider,"Missing \(id)")
                try check(slider.doubleValue == expected,"Reference default \(id)")
            }
            control.selectedSegment = index; control.sendAction(control.action,to:control.target)
            if index < 2 { try snapshot(window,to:outputDirectory.appendingPathComponent("background-\(name)-panel.png")) }
            try save(window,id:"editor.background.save",result:{ saved })
            let resultURL = try require(saved,"No background callback")
            try check(resultURL.pathExtension == "png" && resultURL.lastPathComponent.contains(" With Background"),"Background filename")
            let result = try MediaEngine.loadImage(resultURL)
            try check(result.width == expectedWidth && result.height == expectedHeight,"Background \(name): got \(result.width)×\(result.height)")
            results.append("Add BG \(name): actual Save callback, PNG, \(expectedWidth)×\(expectedHeight)")
        }

        for action in ["edit","annotate","redact","compress","metadata"] {
            let window = try coordinator.makeOffscreenWindow(action:action,url:source)
            try snapshot(window,to:outputDirectory.appendingPathComponent("\(action)-panel.png"))
            try check(!window.isVisible,"Off-screen \(action) unexpectedly visible")
            window.close()
        }
        try referenceSnapshots(coordinator:coordinator,directory:outputDirectory)
        try check(coordinator.openWindows.isEmpty,"Closed windows should leave coordinator ownership")
        results.append("All seven native panels snapshotted while hidden; no desktop interaction")
        return results
    }

    private static func referenceSnapshots(coordinator:EditorCoordinator,directory:URL) throws {
        let page = try makeFixture(width:2550,height:3300)
        let source = directory.appendingPathComponent("Reference Page.jpg")
        try MediaEngine.writeImage(page,format:"jpg",to:source,quality:1)
        let crop = try coordinator.makeOffscreenWindow(action:"crop",url:source)
        let canvas = try require(find("editor.crop.canvas",in:crop.contentView!) as? ODCropCanvas,"Missing crop")
        canvas.selection = CGRect(x:0,y:210,width:2550,height:1877)
        let width = try require(find("editor.crop.width",in:crop.contentView!) as? NSTextField,"Missing pixel width")
        let height = try require(find("editor.crop.height",in:crop.contentView!) as? NSTextField,"Missing pixel height")
        try check(width.stringValue == "2550" && height.stringValue == "1877","Pixel fields must not contain locale grouping separators")
        width.sendAction(width.action,to:width.target)
        try check(canvas.selection.width == 2550 && canvas.selection.height == 1877,"Numeric pixel controls must preserve integer dimensions")
        try snapshot(crop,to:directory.appendingPathComponent("reference-crop-panel.png"))
        let cropped = try require(canvas.croppedImage(),"Reference crop")
        crop.close()
        let croppedURL = directory.appendingPathComponent("Reference Page Cropped.jpg")
        try MediaEngine.writeImage(cropped,format:"jpg",to:croppedURL,quality:1)
        for (ratio,name,padding) in [(0,"auto",160.0),(1,"square",609.0)] {
            let window = try coordinator.makeOffscreenWindow(action:"background",url:croppedURL)
            let control = try require(find("editor.background.ratio",in:window.contentView!) as? NSSegmentedControl,"Missing ratio")
            control.selectedSegment = ratio; control.sendAction(control.action,to:control.target)
            let slider = try require(find("editor.background.padding",in:window.contentView!) as? NSSlider,"Missing padding")
            slider.doubleValue = padding; slider.sendAction(slider.action,to:slider.target)
            try snapshot(window,to:directory.appendingPathComponent("reference-background-\(name)-panel.png"))
            window.close()
        }
    }

    /// Produces a native AppKit control snapshot. Behind-window vibrancy has no
    /// live desktop to sample off-screen, so its backing material is approximate.
    public static func snapshot(_ window: NSWindow, to url: URL) throws {
        try check(!window.isVisible,"Refusing to snapshot a visible editor")
        let view = try require(window.contentView,"Missing content view")
        view.layoutSubtreeIfNeeded()
        let bitmap = try require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"Could not allocate snapshot")
        view.cacheDisplay(in:view.bounds,to:bitmap)
        let png = try require(bitmap.representation(using:.png,properties:[:]),"Could not encode snapshot")
        try png.write(to:url)
    }

    private static func save(_ window:NSWindow,id:String,result:()->URL?) throws {
        try check(!window.isVisible,"Editor must remain hidden")
        let button = try require(find(id,in:window.contentView!) as? NSButton,"Missing \(id)")
        button.performClick(nil)
        let deadline = Date().addingTimeInterval(15)
        while result() == nil && Date() < deadline {
            if let error = (window.windowController as? ODEditorController)?.lastError { throw error }
            RunLoop.current.run(until:Date().addingTimeInterval(0.015))
        }
        try check(result() != nil,"Save did not finish: \(id)")
        try check(!window.isVisible,"Save must not show an editor")
    }

    private static func find(_ id:String,in view:NSView)->NSView? {
        if view.identifier?.rawValue == id || view.accessibilityIdentifier() == id { return view }
        for child in view.subviews { if let match = find(id,in:child) { return match } }
        return nil
    }
    private static func drag(_ view:NSView,from start:CGPoint,to end:CGPoint,window:NSWindow) throws {
        func event(_ type:NSEvent.EventType,_ point:CGPoint) throws -> NSEvent {
            try require(NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1),"Synthetic view event")
        }
        view.mouseDown(with:try event(.leftMouseDown,start))
        view.mouseDragged(with:try event(.leftMouseDragged,end))
        view.mouseUp(with:try event(.leftMouseUp,end))
    }
    private static func check(_ condition:Bool,_ message:String) throws { if !condition { throw NSError(domain:"EditorOffscreenChecks",code:1,userInfo:[NSLocalizedDescriptionKey:message]) } }
    private static func require<T>(_ value:T?,_ message:String) throws -> T { guard let value = value else { throw NSError(domain:"EditorOffscreenChecks",code:2,userInfo:[NSLocalizedDescriptionKey:message]) }; return value }
    private static func makeFixture(width:Int = 960,height:Int = 720) throws -> CGImage {
        let context = try require(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),"Fixture context")
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x:0,y:0,width:width,height:height))
        let scale = CGFloat(width)/960
        context.scaleBy(x:scale,y:scale)
        let pageHeight = CGFloat(height)/scale
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
        let heading = "A small space for big ideas" as NSString
        heading.draw(at:CGPoint(x:62,y:pageHeight-92),withAttributes:[.font:NSFont.systemFont(ofSize:32,weight:.semibold),.foregroundColor:NSColor(calibratedWhite:0.18,alpha:1)])
        let body = ["Notes on making everyday work feel a little lighter.","Keep the useful things close. Give everything else room.","A photograph, a thought, a page worth coming back to.","Crop it. Frame it. Make it yours."]
        for index in 0..<Int((pageHeight-250)/37) {
            (body[index % body.count] as NSString).draw(at:CGPoint(x:64,y:pageHeight-150-CGFloat(index)*37),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:18,weight:.regular),.foregroundColor:NSColor(calibratedWhite:0.27,alpha:1)])
        }
        NSGraphicsContext.restoreGraphicsState()
        context.setFillColor(NSColor.systemOrange.cgColor); context.fill(CGRect(x:62,y:58,width:100,height:6))
        return try require(context.makeImage(),"Fixture image")
    }
}
