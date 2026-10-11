import Foundation

/// 界面文字。代码里写的是简体中文原文，英文译文在 Resources/en.lproj/Localizable.strings 里，以中文原文为键。
/// 系统语言是简体中文时显示原文，其他语言显示英文；新增文字时记得补上译文。
func L(_ text: String) -> String {
    Bundle.main.localizedString(forKey: text, value: text, table: nil)
}
