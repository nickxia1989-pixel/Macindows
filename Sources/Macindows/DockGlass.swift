import AppKit
import Darwin

/// 程序坞用的那种玻璃。
///
/// 系统的玻璃有二十来个「配方」，公开接口只给了两种（regular 和 clear），程序坞用的是另一种，叫 dock。
/// NSGlassEffectView 有一个未公开的属性 `_variant`，按编号选配方；麻烦在于编号随系统版本变
/// （实测 macOS 27 上 clear 是 2、dock 是 3；macOS 26 上 clear 是 1、dock 是 2）。
/// 所以这里不把编号写死，而是在运行时两头对：先看公开的 clear 在这台机器上是几号，
/// 再向 SwiftUI 按名字问 dock 是几号，两边对 clear 的说法一致才信。对不上、问不到，就退回公开的 clear。
enum DockGlass {
    /// dock 配方在这台机器上的编号；拿不准时为 nil
    static let variant: Int? = resolve()

    static var diagnosis: String { variant.map { "dock 配方 = \($0) 号" } ?? "未能确定 dock 配方，使用公开的 clear" }

    /// 让一块玻璃用上程序坞的配方。返回是否成功；不成功时调用方用公开的样式
    @discardableResult
    static func apply(to glass: NSGlassEffectView) -> Bool {
        guard let variant, glass.responds(to: NSSelectorFromString("set_variant:")) else { return false }
        glass.setValue(variant, forKey: "_variant")
        return true
    }

    private static func resolve() -> Int? {
        let probe = NSGlassEffectView()
        guard probe.responds(to: NSSelectorFromString("_variant")), probe.responds(to: NSSelectorFromString("set_variant:")) else { return nil }
        probe.style = .clear
        guard let clear = (probe.value(forKey: "_variant") as? NSNumber)?.intValue else { return nil }
        if let dock = SwiftUIGlass.index(of: "dock"), SwiftUIGlass.index(of: "clear") == clear { return dock }
        // SwiftUI 那边问不到时，认 macOS 26 的那张编号表（regular 0、clear 1、dock 2）
        return clear == 1 ? 2 : nil
    }
}

/// 按名字向 SwiftUI 问一种玻璃配方的编号。
///
/// SwiftUI 里有一个未公开的类型 `_Glass`，每种配方是它的一个静态属性（`_Glass.dock`、`_Glass.clear`……）。
/// 这里只调用这些属性的读取函数、看返回值开头的那个枚举值，不用它做别的。
/// 每一步都先确认再做：类型在不在、大小对不对、符号找不找得到；任何一步不对就返回 nil。
private enum SwiftUIGlass {
    #if arch(arm64)
    /// 读取函数把结果写进调用方给的一块内存。借一个足够大（128 字节）、同样靠内存返回的 C 结构体当这块内存；
    /// 在 arm64 上 Swift 和 C 传这块内存地址的方式相同，所以可以按 C 函数来调。
    private typealias Getter = @convention(c) () -> CATransform3D

    private static let handle = dlopen("/System/Library/Frameworks/SwiftUI.framework/SwiftUI", RTLD_LAZY)

    /// `_Glass` 实际的大小要在「靠内存返回」和「不超过借来的那块内存」之间，否则不能这么调
    private static let layoutIsSafe: Bool = {
        guard handle != nil, let type = _typeByName("7SwiftUI6_GlassV") else { return false }
        func size<T>(_: T.Type) -> Int { MemoryLayout<T>.size }
        let bytes = _openExistential(type, do: size)
        return bytes > 16 && bytes <= MemoryLayout<CATransform3D>.size
    }()

    static func index(of name: String) -> Int? {
        // 符号名是 Swift 的写法：SwiftUI._Glass.<name> 的读取函数
        guard layoutIsSafe, let symbol = dlsym(handle, "$s7SwiftUI6_GlassV\(name.utf8.count)\(name)ACvgZ") else { return nil }
        var storage = unsafeBitCast(symbol, to: Getter.self)()
        let word = withUnsafeBytes(of: &storage) { $0.load(as: UInt64.self) }
        // 实测开头 8 个字节是配方的枚举值：最高位是 1，序号从第 3 位起
        guard word >> 63 == 1 else { return nil }
        let index = (word & ~(1 << 63)) >> 3
        return index < 64 ? Int(index) : nil
    }
    #else
    // Intel 上 Swift 和 C 返回大结构体的方式不同，不能这么调；macOS 27 起也不再有 Intel 机器
    static func index(of name: String) -> Int? { nil }
    #endif
}
