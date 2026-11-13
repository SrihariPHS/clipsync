import AppKit

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run())
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
