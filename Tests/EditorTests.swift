import AppKit

@main
enum EditorTests {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard NSApp.activationPolicy() == .prohibited else {
            fputs("FAIL: Could not prohibit application activation; refusing editor QA.\n",stderr)
            exit(1)
        }
        let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath,isDirectory:true)
            .appendingPathComponent("build/editor-qa",isDirectory:true)
            .appendingPathComponent(UUID().uuidString.lowercased(),isDirectory:true)
        do {
            let checks = try EditorOffscreenChecks.run(outputDirectory:output)
            let report = checks.map { "PASS: " + $0 }.joined(separator:"\n")
                + "\nArtifacts: \(output.path)\n"
                + "Off-screen material rendering cannot reproduce live desktop vibrancy.\n"
            try report.write(to:output.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
            print(report)
        } catch {
            fputs("FAIL: Editor QA: \(error.localizedDescription)\nArtifacts: \(output.path)\n",stderr)
            exit(1)
        }
    }
}
