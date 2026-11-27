import CoreGraphics

/// 切换器网格里的方向移动。
public enum SwitcherDirection: Equatable {
    case left, right, up, down
}

/// 快速切换面板按窗口顺序逐行排版，卡片宽度取决于窗口的宽高比。坐标原点在面板左上角。
public struct SwitcherLayout {
    public static let inset: CGFloat = 14
    public static let pictureInset: CGFloat = 7
    public static let titleSpace: CGFloat = 28
    public static let defaultAspect: CGFloat = 1.6
    public let size: CGSize
    /// 每张卡片在所属页面中的位置，下标就是窗口下标。
    public let frames: [CGRect]
    public let pages: [Range<Int>]

    public init(windowSizes: [CGSize?], screenSize: CGSize) {
        let gap: CGFloat = 10, top: CGFloat = 42, bottom = Self.inset
        let maxRoom = CGSize(width: max(1, floor(screenSize.width - min(64, screenSize.width * 0.06) - 2 * Self.inset)),
                             height: max(1, floor(screenSize.height - min(64, screenSize.height * 0.06) - top - bottom)))
        let minWidth = min(maxRoom.width, 236)
        guard !windowSizes.isEmpty else {
            frames = []
            pages = []
            size = .zero
            return
        }
        let chrome = 2 * Self.pictureInset + Self.titleSpace
        let aspects = windowSizes.map(Self.aspect(of:))

        // 过窄的卡片为标题留位置，超宽窗口也给相邻卡片留空间。预览本身始终按原比例放入。
        func rows(at height: CGFloat, in roomWidth: CGFloat) -> [[CGRect]] {
            var result: [[CGRect]] = []
            var row: [CGRect] = []
            var x: CGFloat = 0
            let titleWidth = max(120, min(168, round(height * 0.72)))
            for aspect in aspects {
                let width = min(roomWidth, max(titleWidth, round(min(aspect, 2.8) * height) + 2 * Self.pictureInset))
                if !row.isEmpty, x + width > roomWidth {
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

        func fitsAll(at height: Int, in room: CGSize) -> Bool {
            let count = rows(at: CGFloat(height), in: room.width).count
            return CGFloat(count) * (CGFloat(height) + chrome + gap) - gap <= room.height
        }

        // 日常窗口数优先落在屏幕中央克制的浮窗范围内（约占屏幕 72%×64%，单卡高度上限 156），
        // 避免几扇窗口就把屏幕铺满；只有窗口极多、舒适尺寸放不下时才向外扩展空间再分页。
        let comfortableMaxHeight = 156
        let comfortableMinHeight = 104
        let comfortableRoom = CGSize(
            width: min(maxRoom.width, max(min(maxRoom.width, 640), floor(min(screenSize.width * 0.72, 1080)) - 2 * Self.inset)),
            height: min(maxRoom.height, max(min(maxRoom.height, 360), floor(min(screenSize.height * 0.64, 580)) - top - bottom))
        )
        let comfortableCap = max(1, min(comfortableMaxHeight, Int(comfortableRoom.height - chrome)))
        let useComfortable = comfortableCap >= comfortableMinHeight && fitsAll(at: comfortableMinHeight, in: comfortableRoom)

        let room = useComfortable ? comfortableRoom : maxRoom
        let maximum = max(1, min(comfortableMaxHeight, Int(room.height - chrome)))
        var low = min(useComfortable ? comfortableMinHeight : 80, maximum), high = maximum
        while low < high {
            let middle = (low + high + 1) / 2
            if fitsAll(at: middle, in: room) {
                low = middle
            } else {
                high = middle - 1
            }
        }

        let packedRows = rows(at: CGFloat(low), in: room.width)
        let rowStride = CGFloat(low) + chrome + gap
        let rowsPerPage = min(packedRows.count, max(1, Int((room.height + gap) / rowStride)))
        let gridWidth = min(room.width, max(minWidth, packedRows.compactMap { $0.last?.maxX }.max() ?? 0))
        let gridBottom = top + CGFloat(rowsPerPage) * rowStride - gap
        size = CGSize(width: gridWidth + 2 * Self.inset, height: gridBottom + bottom)

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

    /// 方向键移动：左右沿顺序环绕（跨页），上下移动到相邻行中水平中心最近的卡片。
    public func neighbor(from index: Int, direction: SwitcherDirection) -> Int? {
        guard frames.indices.contains(index), !pages.isEmpty else { return nil }
        switch direction {
        case .left:
            return (index - 1 + frames.count) % frames.count
        case .right:
            return (index + 1) % frames.count
        case .up, .down:
            guard let pageIndex = pages.firstIndex(where: { $0.contains(index) }) else { return nil }
            let rows = rowsInPage(pages[pageIndex])
            guard let rowIndex = rows.firstIndex(where: { $0.contains(index) }) else { return nil }
            let targetRow: [Int]
            if direction == .up {
                if rowIndex > 0 {
                    targetRow = rows[rowIndex - 1]
                } else {
                    let prevPage = pages[(pageIndex - 1 + pages.count) % pages.count]
                    guard let last = rowsInPage(prevPage).last else { return index }
                    targetRow = last
                }
            } else {
                if rowIndex + 1 < rows.count {
                    targetRow = rows[rowIndex + 1]
                } else {
                    let nextPage = pages[(pageIndex + 1) % pages.count]
                    guard let first = rowsInPage(nextPage).first else { return index }
                    targetRow = first
                }
            }
            let x = frames[index].midX
            return targetRow.min { a, b in
                let da = abs(frames[a].midX - x), db = abs(frames[b].midX - x)
                return da != db ? da < db : a < b
            }
        }
    }

    private func rowsInPage(_ range: Range<Int>) -> [[Int]] {
        var rows: [[Int]] = []
        for i in range {
            if let last = rows.last?.first, abs(frames[i].minY - frames[last].minY) < 1 {
                rows[rows.count - 1].append(i)
            } else {
                rows.append([i])
            }
        }
        return rows
    }
}
