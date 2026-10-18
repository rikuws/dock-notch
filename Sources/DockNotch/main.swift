import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--render"), arguments.indices.contains(flag + 1) {
    Task {
        await CardRenderer.run(outputDirectory: arguments[flag + 1], sample: arguments.contains("--sample"))
        exit(0)
    }
    app.run()
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
