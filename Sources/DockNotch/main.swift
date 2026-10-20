import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--render"), arguments.indices.contains(flag + 1) {
    let width = arguments.firstIndex(of: "--width")
        .flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 400
    Task {
        await CardRenderer.run(
            outputDirectory: arguments[flag + 1],
            sample: arguments.contains("--sample"),
            width: CGFloat(width),
            details: arguments.contains("--details")
        )
        exit(0)
    }
    app.run()
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
