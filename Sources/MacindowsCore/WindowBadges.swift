import Foundation

public enum WindowBadges {
    // 支持系统显示的分组数字和 99+。没有数字的点、星号及 0 都不转成数字角标。
    private static let numericLabel = try! NSRegularExpression(pattern: #"^(?:[0-9]{1,3}(?:[, ][0-9]{3})+|[0-9]+)\+?$"#)

    public static func dockNumber(_ label: String?) -> String? {
        guard let label else { return nil }
        let text = label.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard numericLabel.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
              text.contains(where: { ("1"..."9").contains($0) }) else { return nil }
        return text
    }
}
