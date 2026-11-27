import AppKit

let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--render-sample"), arguments.indices.contains(index + 1) {
    _ = NSApplication.shared
    SampleRender.run(outputDirectory: arguments[index + 1])
    exit(0)
}

if let index = arguments.firstIndex(of: "--show-sample") {
    NSApplication.shared.setActivationPolicy(.accessory)
    SampleRender.show(arguments: Array(arguments[(index + 1)...]))
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

// 从菜单栏触发重启时，先等旧进程退出再继续启动，避免被单实例检查拦掉
if let index = arguments.firstIndex(of: "--relaunch"),
   arguments.indices.contains(index + 1),
   let oldPID = pid_t(arguments[index + 1]) {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline, NSRunningApplication(processIdentifier: oldPID) != nil {
        Thread.sleep(forTimeInterval: 0.05)
    }
}

// 同时跑两份会各自截一遍点击；重复打开时通知已有实例展开菜单栏菜单，让用户立刻看到它已在运行
if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.xianing.Macindows.reopen"),
        object: bundleID,
        userInfo: nil,
        deliverImmediately: true
    )
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
