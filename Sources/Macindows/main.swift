import AppKit

let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--render-sample"), arguments.indices.contains(index + 1) {
    _ = NSApplication.shared
    SampleRender.run(outputDirectory: arguments[index + 1])
    exit(0)
}

if arguments.contains("--selftest") {
    _ = NSApplication.shared
    SelfTest.run()
    exit(0)
}

if arguments.contains("--check-hover") {
    _ = NSApplication.shared
    print(SampleRender.checkHover().joined(separator: "\n"))
    exit(0)
}

if arguments.contains("--diagnose") {
    Diagnose.run()
    exit(0)
}

// 同时跑两份会各自截一遍点击，直接让后来的那份退出
if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
