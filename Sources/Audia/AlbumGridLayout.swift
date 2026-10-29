import CoreGraphics

/// Pure geometry for the album grid. The layout is derived from measured
/// values, so an album can be located without asking a lazy SwiftUI view for
/// the frame of a card that may not be instantiated.
struct AlbumGridLayout: Equatable {
    let count: Int
    let columns: Int
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat
    let padding: CGFloat

    var rowHeight: CGFloat { cardHeight + rowSpacing }

    func frame(at index: Int) -> CGRect? {
        guard index >= 0, index < count, columns > 0 else { return nil }
        let row = index / columns
        let column = index % columns
        return CGRect(
            x: padding + CGFloat(column) * (cardWidth + columnSpacing),
            y: padding + CGFloat(row) * rowHeight,
            width: cardWidth,
            height: cardHeight
        )
    }

    func index(at point: CGPoint) -> Int? {
        guard count > 0, columns > 0,
              cardWidth > 0, rowHeight > 0,
              point.x >= padding, point.y >= padding else { return nil }
        let column = Int((point.x - padding) / (cardWidth + columnSpacing))
        let row = Int((point.y - padding) / rowHeight)
        guard column >= 0, column < columns, row >= 0 else { return nil }
        let index = row * columns + column
        return index < count ? index : nil
    }
}
