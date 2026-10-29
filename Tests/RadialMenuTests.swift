import AppKit

@main
struct RadialMenuTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let size = WheelGeometry.panelSize
        let view = RadialMenu(frame:NSRect(x:0,y:0,width:size,height:size))
        let c = size/2
        let pdf = URL(fileURLWithPath:"/tmp/OrbitDrop-sample.pdf")
        let png = URL(fileURLWithPath:"/tmp/OrbitDrop-sample.png")
        view.actions = WheelAction.formats(for:pdf)
        precondition(view.actions.map(\.label) == ["DOCX","JPG","PNG","TXT"])
        let points = [NSPoint(x:c,y:c+80),NSPoint(x:c+80,y:c),NSPoint(x:c,y:c-80),NSPoint(x:c-80,y:c)]
        for (i,point) in points.enumerated() {
            precondition(view.index(at:point) == i,"Incorrect wheel target at \(point)")
            precondition(view.wedge(i).contains(point),"Visible wedge and hit target differ")
        }
        precondition(view.index(at:NSPoint(x:c,y:c)) == nil)
        precondition(view.index(at:NSPoint(x:c+WheelGeometry.radius+2,y:c)) == nil,"Outside the rim must not hit")
        precondition(size < 280,"Wheel must stay compact like the reference")
        precondition(view.index(at:NSPoint(x:0,y:0)) == nil)
        view.actions = WheelAction.formats(for:png)
        precondition(view.actions.map(\.label) == ["PNG","WEBP","HEIC","TIFF","AVIF","BMP","PDF","DOCX"])
        view.hovered = 7
        view.actions = WheelAction.tools
        precondition(view.hovered == nil,"Switching eight formats to seven tools must clear stale hover")
        for i in 0..<7 {
            let theta = (90-Double(i)*360/7)*Double.pi/180
            let point = NSPoint(x:c+80*cos(theta),y:c+80*sin(theta))
            precondition(view.index(at:point) == i)
            precondition(view.wedge(i).contains(point))
        }
        var result:String?
        view.onAction = { action,urls in precondition(urls == [png]); result = action.key }
        view.execute(5,urls:[png]); precondition(result == "crop")
        result = nil; view.busyLabel = "Busy"; view.execute(0,urls:[png]); precondition(result == nil)
        view.busyLabel = nil; view.execute(0,urls:[]); precondition(result == nil)
        let board = NSPasteboard(name:NSPasteboard.Name("OrbitDrop.IsolatedTests"))
        board.clearContents(); board.writeObjects([png as NSURL])
        precondition(RadialMenu.urls(from:board) == [png]); board.releaseGlobally()
        print("PASS: reference action ordering, all wheel hit targets, center/outside exclusion, busy guard, empty input guard, and file drag pasteboard decoding.")
    }
}
