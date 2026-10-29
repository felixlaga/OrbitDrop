import AppKit

@main
struct RadialMenuTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let view = RadialMenu(frame:NSRect(x:0,y:0,width:420,height:420))
        let pdf = URL(fileURLWithPath:"/tmp/OrbitDrop-sample.pdf")
        let png = URL(fileURLWithPath:"/tmp/OrbitDrop-sample.png")
        view.actions = WheelAction.formats(for:pdf)
        precondition(view.actions.map(\.label) == ["DOCX","JPG","PNG","TXT"])
        let points = [NSPoint(x:210,y:350),NSPoint(x:350,y:210),NSPoint(x:210,y:70),NSPoint(x:70,y:210)]
        for (i,point) in points.enumerated() {
            precondition(view.index(at:point) == i,"Incorrect wheel target at \(point)")
            precondition(view.wedge(i).contains(point),"Visible wedge and hit target differ")
        }
        precondition(view.index(at:NSPoint(x:210,y:210)) == nil)
        precondition(view.index(at:NSPoint(x:0,y:0)) == nil)
        view.actions = WheelAction.formats(for:png)
        precondition(view.actions.map(\.label) == ["PNG","WEBP","HEIC","TIFF","AVIF","BMP","PDF","DOCX"])
        view.hovered = 7
        view.actions = WheelAction.tools
        precondition(view.hovered == nil,"Switching eight formats to seven tools must clear stale hover")
        for i in 0..<7 {
            let theta = (90-Double(i)*360/7)*Double.pi/180
            let point = NSPoint(x:210+145*cos(theta),y:210+145*sin(theta))
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
