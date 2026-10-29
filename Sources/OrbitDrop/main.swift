import AppKit
import Carbon
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: WheelPanel!
    var wheel: RadialMenu!
    var editor = EditorCoordinator()
    var timer: Timer?
    var currentFiles: [URL] = []
    var pendingDragFiles: [URL] = []
    var showingTools = false
    var dragStart: CFAbsoluteTime?
    var initialDragPoint = NSPoint.zero
    var lastDragChange = -1
    var dragWasShown = false
    var dragSession = false
    var wasDown = false
    var hideAfterDrag: CFAbsoluteTime?
    var localMonitor: Any?
    var hotKey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var introduction: NSWindow?
    var working = false
    var testing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named:.aqua)
        testing = CommandLine.arguments.contains("--test-mode")
        buildWheel()
        buildStatusItem()
        registerHotkey()
        timer = Timer(timeInterval:0.045,repeats:true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!,forMode:.common)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown]) { [weak self] event in
            if event.keyCode == 53,let self,self.panel.isVisible,event.window === self.panel { self.hideWheel(); return nil }; return event
        }
        if let i = CommandLine.arguments.firstIndex(of:"--open"), CommandLine.arguments.count > i+1 {
            currentFiles = [URL(fileURLWithPath:CommandLine.arguments[i+1])]
            if let j = CommandLine.arguments.firstIndex(of:"--editor"), CommandLine.arguments.count > j+1 {
                openEditor(CommandLine.arguments[j+1],url:currentFiles[0])
            } else { showWheel(at:NSScreen.main.map { NSPoint(x:$0.visibleFrame.midX,y:$0.visibleFrame.midY) } ?? NSEvent.mouseLocation,tools:CommandLine.arguments.contains("--tools"),dragging:false) }
        } else if !testing && !UserDefaults.standard.bool(forKey:"hasOpenedOrbitDrop") {
            showIntroduction()
            UserDefaults.standard.set(true,forKey:"hasOpenedOrbitDrop")
        }
    }
    func buildWheel() {
        let size: CGFloat = 420
        panel = WheelPanel(contentRect:NSRect(x:0,y:0,width:size,height:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.transient,.ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.title = "OrbitDrop"
        let glass = NSVisualEffectView(frame:NSRect(x:0,y:0,width:size,height:size))
        glass.material = .popover; glass.blendingMode = .behindWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = size/2; glass.layer?.masksToBounds = true
        wheel = RadialMenu(frame:glass.bounds)
        wheel.autoresizingMask = [.width,.height]
        glass.addSubview(wheel); panel.contentView = glass
        wheel.onAction = { [weak self] action,urls in self?.perform(action,urls:urls) }
        wheel.onToggle = { [weak self] in self?.toggleMode() }
        wheel.onDismiss = { [weak self] in self?.hideWheel() }
        wheel.onDragModifiers = { [weak self] flags in
            guard let self else { return }
            self.setToolMode(flags.contains(.option))
        }
    }
    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName:"circle.hexagongrid",accessibilityDescription:"OrbitDrop")
        statusItem.button?.toolTip = "OrbitDrop — drag a file to convert or edit"
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])
    }
    @objc func statusClicked(_ sender: Any?) {
        let menu = NSMenu()
        let title = NSMenuItem(title:"OrbitDrop",action:nil,keyEquivalent:""); menu.addItem(title)
        menu.addItem(.separator())
        item("Open File…",#selector(chooseFile),menu,"o")
        item("Show Wheel",#selector(showCurrentWheel),menu,"")
        let auto = item("Show When Dragging Files",#selector(toggleAutomatic(_:)),menu,"")
        auto.state = UserDefaults.standard.object(forKey:"automaticDrag") as? Bool == false ? .off : .on
        item("How to Use…",#selector(showIntroduction),menu,"")
        if #available(macOS 13.0,*) {
            let login = item("Open at Login",#selector(toggleLogin),menu,"")
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        menu.addItem(.separator())
        item("Quit OrbitDrop",#selector(quit),menu,"q")
        statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
    }
    @discardableResult func item(_ title:String,_ selector:Selector,_ menu:NSMenu,_ key:String)->NSMenuItem {
        let item = NSMenuItem(title:title,action:selector,keyEquivalent:key); item.target = self; menu.addItem(item); return item
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleAutomatic(_ sender:NSMenuItem) { UserDefaults.standard.set(sender.state != .on,forKey:"automaticDrag") }
    @objc func toggleLogin() {
        if #available(macOS 13.0,*) {
            do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
            catch { showError(error) }
        }
    }
    @objc func chooseFile() {
        hideWheel(); NSApp.activate(ignoringOtherApps:true)
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = true
        picker.allowedContentTypes = [.image,.pdf]; picker.message = "Choose a file to convert or edit."
        picker.begin { [weak self] result in
            guard result == .OK,let self else { return }; self.currentFiles = picker.urls
            self.showWheel(at:NSEvent.mouseLocation,tools:false,dragging:false)
        }
    }
    @objc func showCurrentWheel() {
        if panel.isVisible { hideWheel(); return }
        if currentFiles.isEmpty { chooseFile() } else { showWheel(at:NSEvent.mouseLocation,tools:false,dragging:false) }
    }
    func showWheel(at point:NSPoint,tools:Bool,dragging:Bool,files:[URL]? = nil) {
        guard !working else { return }
        hideAfterDrag = nil
        let displayedFiles = files ?? currentFiles
        showingTools = tools
        wheel.files = displayedFiles; wheel.file = displayedFiles.first
        wheel.isTools = tools; wheel.actions = tools ? WheelAction.tools : WheelAction.formats(for:displayedFiles.first)
        wheel.hovered = nil; wheel.busyLabel = nil
        let frame = NSScreen.screens.first(where:{$0.frame.contains(point)})?.visibleFrame ?? NSScreen.main!.visibleFrame
        let size = panel.frame.size
        let x = max(frame.minX+4,min(point.x-size.width/2,frame.maxX-size.width-4))
        let y = max(frame.minY+4,min(point.y-size.height/2,frame.maxY-size.height-4))
        panel.setFrameOrigin(NSPoint(x:x,y:y))
        panel.alphaValue = 1
        panel.hidesOnDeactivate = !dragging
        if dragging { panel.orderFrontRegardless() }
        else { NSApp.activate(ignoringOtherApps:true); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(wheel) }
        dragSession = dragging
    }
    func hideWheel() { panel.orderOut(nil); wheel.hovered = nil; hideAfterDrag = nil; dragSession = false }
    func toggleMode() { setToolMode(!showingTools) }
    func setToolMode(_ tools:Bool) {
        guard showingTools != tools else { return }
        showingTools = tools; wheel.isTools = showingTools
        wheel.actions = showingTools ? WheelAction.tools : WheelAction.formats(for:wheel.file)
        if dragSession { wheel.hovered = wheel.index(at:wheel.convert(panel.convertPoint(fromScreen:NSEvent.mouseLocation),from:nil)) }
    }
    func tick() {
        guard !testing else { return }
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let option = NSEvent.modifierFlags.contains(.option)
        let now = CFAbsoluteTimeGetCurrent()
        if panel.isVisible, down, dragSession { setToolMode(option) }
        if down && !wasDown {
            dragStart = nil; pendingDragFiles = []; initialDragPoint = NSEvent.mouseLocation; dragWasShown = false
        }
        if down && !working && UserDefaults.standard.object(forKey:"automaticDrag") as? Bool != false {
            let board = NSPasteboard(name:.drag)
            let changed = board.changeCount != lastDragChange
            if changed && dragStart == nil {
                let urls = RadialMenu.urls(from:board)
                if !urls.isEmpty && urls.allSatisfy({ supported($0) }) { dragStart = now; pendingDragFiles = urls }
            }
            if let start = dragStart,now-start>0.24,!dragWasShown {
                showWheel(at:NSEvent.mouseLocation,tools:option,dragging:true,files:pendingDragFiles); dragWasShown = true
            }
        }
        if !down && wasDown && dragSession { hideAfterDrag = now+0.22 }
        if let deadline = hideAfterDrag,now>deadline { hideWheel() }
        if !down { lastDragChange = NSPasteboard(name:.drag).changeCount }
        wasDown = down
    }
    func supported(_ url:URL)->Bool { ["png","jpg","jpeg","heic","heif","webp","tif","tiff","avif","bmp","gif","pdf"].contains(url.pathExtension.lowercased()) }
    func perform(_ action:WheelAction,urls:[URL]) {
        hideAfterDrag = nil
        if WheelAction.tools.contains(where:{$0.key == action.key}) {
            currentFiles = urls
            hideWheel(); for url in urls { openEditor(action.key,url:url) }; return
        }
        guard !working else { return }; working = true; wheel.busyLabel = "Converting…"
        DispatchQueue.global(qos:.userInitiated).async {
            var outputs:[URL] = [],failures:[String] = []
            for url in urls {
                do { outputs += try MediaEngine.convert(url,to:action.key) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                self.working = false; self.hideWheel()
                if let last = outputs.last { self.currentFiles = [last] }
                if !failures.isEmpty { self.showError(NSError(domain:"OrbitDrop",code:1,userInfo:[NSLocalizedDescriptionKey:failures.joined(separator:"\n\n")])) }
                else if !outputs.isEmpty { self.showToast("Saved \(outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files")") }
            }
        }
    }
    func openEditor(_ action:String,url:URL) {
        editor.open(action:action,url:url) { [weak self] output in self?.currentFiles = [output]; self?.showToast("Saved \(output.lastPathComponent)") }
    }
    func showError(_ error:Error) {
        NSApp.activate(ignoringOtherApps:true)
        let alert = NSAlert(); alert.messageText = "Couldn’t complete this file"; alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning; alert.runModal()
    }
    func showToast(_ text:String) {
        let toast = NSPanel(contentRect:NSRect(x:0,y:0,width:340,height:54),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        toast.isOpaque = false; toast.backgroundColor = .clear; toast.level = .floating; toast.hasShadow = true
        let glass = NSVisualEffectView(frame:NSRect(x:0,y:0,width:340,height:54)); glass.material = .popover; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = 14; glass.layer?.masksToBounds = true
        let label = NSTextField(labelWithString:"✓  "+text); label.font = .systemFont(ofSize:12,weight:.medium); label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x:17,y:18,width:306,height:18); glass.addSubview(label); toast.contentView = glass
        let screen = NSScreen.main!.visibleFrame; toast.setFrameOrigin(NSPoint(x:screen.midX-170,y:screen.minY+28)); toast.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline:.now()+2.5) { toast.orderOut(nil) }
    }
    func registerHotkey() {
        let callback:EventHandlerUPP = { _,event,context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            app.showCurrentWheel(); return noErr
        }
        var type = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),callback,1,&type,Unmanaged.passUnretained(self).toOpaque(),&eventHandler)
        let id = EventHotKeyID(signature:0x4F524254,id:1)
        RegisterEventHotKey(UInt32(kVK_Space),UInt32(controlKey|optionKey),id,GetApplicationEventTarget(),0,&hotKey)
    }
    @objc func showIntroduction() {
        if let introduction { NSApp.activate(ignoringOtherApps:true); introduction.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:430,height:345),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "OrbitDrop"; window.isReleasedWhenClosed = false; window.center()
        let view = NSVisualEffectView(frame:NSRect(x:0,y:0,width:430,height:345)); view.material = .popover; view.state = .active
        let heading = NSTextField(labelWithString:"Your files. One gesture."); heading.font = .systemFont(ofSize:25,weight:.semibold); heading.frame = NSRect(x:28,y:284,width:374,height:34); view.addSubview(heading)
        let body = NSTextField(wrappingLabelWithString:"Drag an image or PDF in Finder. A wheel appears around your pointer. Drop on a format to convert.\n\nHold ⌥ Option while dragging to reveal Crop, Add BG, and the other tools. Release ⌥ to switch back.\n\nClick the center to switch wheels; drag it to move. Escape dismisses. ⌃⌥Space opens or hides the wheel.\n\nNew files are saved beside the original. OrbitDrop lives in the menu bar, with no Dock icon.")
        body.font = .systemFont(ofSize:13); body.textColor = .secondaryLabelColor; body.frame = NSRect(x:28,y:61,width:374,height:210); view.addSubview(body)
        let button = NSButton(title:"Open a File…",target:self,action:#selector(chooseFile)); button.bezelStyle = .rounded; button.keyEquivalent = "\r"; button.frame = NSRect(x:276,y:20,width:128,height:30); view.addSubview(button)
        window.contentView = view; introduction = window; NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil)
    }
    func application(_ application:NSApplication,open urls:[URL]) {
        currentFiles = urls.filter { supported($0) }
        if !currentFiles.isEmpty { showWheel(at:NSEvent.mouseLocation,tools:false,dragging:false) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
}

// The command-line conversion path also allows packaged builds to be verified
// without opening a window or taking focus from the user's desktop.
if let sourceIndex = CommandLine.arguments.firstIndex(of:"--convert") {
    guard CommandLine.arguments.count > sourceIndex+1,
          let formatIndex = CommandLine.arguments.firstIndex(of:"--to"),
          CommandLine.arguments.count > formatIndex+1 else {
        fputs("Usage: OrbitDrop --convert /path/to/file --to png\n",stderr)
        exit(2)
    }
    do {
        let outputs = try MediaEngine.convert(URL(fileURLWithPath:CommandLine.arguments[sourceIndex+1]),to:CommandLine.arguments[formatIndex+1])
        for output in outputs { print(output.path) }
        exit(0)
    } catch { fputs(error.localizedDescription+"\n",stderr); exit(1) }
}
if CommandLine.arguments.contains("--version") { print("OrbitDrop 1.0.0"); exit(0) }

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
