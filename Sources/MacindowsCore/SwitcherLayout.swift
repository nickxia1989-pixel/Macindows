import CoreGraphics

/// 快速切换面板按窗口顺序逐行排版，卡片宽度取决于窗口的宽高比。坐标原点在面板左上角。
public struct SwitcherLayout {
    public static let inset: CGFloat = 16
    public static let pictureInset: CGFloat = 7
    public static let titleSpace: CGFloat = 30
    public static let defaultAspect: CGFloat = 1.6

    public let size: CGSize
    /// 每张卡片在所属页面中的位置，下标就是窗口下标。
    public let frames: [CGRect]
    public let pages: [Range<Int>]

    public init(windowSizes: [CGSize?], screenSize: CGSize) {
        guard !windowSizes.isEmpty else {
            size = .zero
            frames = []
            pages = []
            return
        }
        let gap: CGFloat = 8, top: CGFloat = 46, bottom: CGFloat = 38
        // 在小屏幕上把空间留给窗口，只在屏幕外围留少量空白。
        let room = CGSize(width: max(1, floor(screenSize.width - min(64, screenSize.width * 0.06) - 2 * Self.inset)),
                          height: max(1, floor(screenSize.height - min(64, screenSize.height * 0.06) - top - bottom)))
        let chrome = 2 * Self.pictureInset + Self.titleSpace
        let aspects = windowSizes.map(Self.aspect(of:))

        // 过窄的卡片为标题留位置，超宽窗口也给相邻卡片留空间。预览本身始终按原比例放入。
        func rows(at height: CGFloat) -> [[CGRect]] {
            var result: [[CGRect]] = []
            var row: [CGRect] = []
            var x: CGFloat = 0
            let titleWidth = max(120, min(172, round(height * 0.72)))
            for aspect in aspects {
                let width = min(room.width, max(titleWidth, round(min(aspect, 2.8) * height) + 2 * Self.pictureInset))
                if !row.isEmpty, x + width > room.width {
                    result.append(row)
                    row = []
                    x = 0
                }
                row.append(CGRect(x: x, y: 0, width: width, height: height + chrome))
                x += width + gap
            }
            result.append(row)
            return result
        }

        // 找仍能整页放下的最大预览高度。只有降到可辨认的下限仍放不下时才分页。
        let maximum = max(1, min(260, Int(room.height - chrome)))
        var low = min(80, maximum), high = maximum
        while low < high {
            let middle = (low + high + 1) / 2
            let count = rows(at: CGFloat(middle)).count
            if CGFloat(count) * (CGFloat(middle) + chrome + gap) - gap <= room.height {
                low = middle
            } else {
                high = middle - 1
            }
        }

        let packedRows = rows(at: CGFloat(low))
        let rowStride = CGFloat(low) + chrome + gap
        let rowsPerPage = min(packedRows.count, max(1, Int((room.height + gap) / rowStride)))
        let gridWidth = min(room.width, max(236, packedRows.compactMap { $0.last?.maxX }.max() ?? 0))
        size = CGSize(width: gridWidth + 2 * Self.inset, height: top + CGFloat(rowsPerPage) * rowStride - gap + bottom)

        var frames: [CGRect] = []
        var pages: [Range<Int>] = []
        var pageStart = 0
        for (index, row) in packedRows.enumerated() {
            let offset = floor((gridWidth - (row.last?.maxX ?? 0)) / 2)
            let pageRow = index % rowsPerPage
            frames += row.map { $0.offsetBy(dx: Self.inset + offset, dy: top + CGFloat(pageRow) * rowStride) }
            if pageRow + 1 == rowsPerPage || index + 1 == packedRows.count {
                pages.append(pageStart..<frames.count)
                pageStart = frames.count
            }
        }
        self.frames = frames
        self.pages = pages
    }

    private static func aspect(of size: CGSize?) -> CGFloat {
        guard let size, size.width > 0, size.height > 0 else { return defaultAspect }
        let aspect = size.width / size.height
        return aspect.isFinite && aspect > 0 ? aspect : defaultAspect
    }

    /// 给占位轮廓、截图和角标共用同一个实际预览边界。
    public static func pictureFrame(for size: CGSize?, in card: CGRect) -> CGRect {
        let area = CGRect(x: pictureInset, y: pictureInset,
                          width: max(1, card.width - 2 * pictureInset),
                          height: max(1, card.height - 2 * pictureInset - titleSpace))
        let aspect = aspect(of: size)
        let height = min(area.height, area.width / aspect)
        let width = max(1, round(height * aspect))
        return CGRect(x: round(area.midX - width / 2), y: round(area.midY - height / 2),
                      width: width, height: max(1, round(height)))
    }
}
