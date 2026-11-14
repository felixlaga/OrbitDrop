import AppKit
import CoreServices

/// Asks Finder for its selection over Apple Events. Pressing a file in Finder selects it,
/// so after a still 2-second hold the selection is the held file (or all selected files,
/// as a drag would carry). macOS asks the user once before OrbitDrop may ask Finder.
enum FinderAccess {
    static let bundleIdentifier = "com.apple.finder"

    enum Status { case allowed, notAsked, denied, unavailable }

    /// With `ask`, macOS shows its permission prompt if the user hasn't answered yet.
    /// That call blocks until they answer, so only make it off the main thread.
    static func status(ask: Bool = false) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        let result: OSStatus = withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        }
        switch Int(result) {
        case 0: return .allowed
        case -1744: return .notAsked   // errAEEventWouldRequireUserConsent
        case -1743: return .denied     // errAEEventNotPermitted
        default: return .unavailable   // procNotFound: Finder isn't running
        }
    }

    private static let selectionScript: NSAppleScript? = {
        let script = NSAppleScript(source: """
        with timeout of 2 seconds
            tell application "Finder" to set picked to selection as alias list
        end timeout
        set paths to {}
        repeat with f in picked
            set end of paths to POSIX path of (contents of f)
        end repeat
        return paths
        """)
        var error: NSDictionary?
        guard script?.compileAndReturnError(&error) == true else { return nil }
        return script
    }()

    /// The selected files, or nil when Finder couldn't be asked. Main thread only.
    static func selectedFiles() -> [URL]? {
        guard let script = selectionScript else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        var urls: [URL] = []
        let count = result.numberOfItems
        if count > 0 {
            for index in 1...count {
                if let path = result.atIndex(index)?.stringValue { urls.append(URL(fileURLWithPath: path)) }
            }
        }
        return urls.filter { !$0.hasDirectoryPath }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
