import SwiftUI

/// Live geometry for a SwiftUI scroll view. Kept in content coordinates: a
/// frame at y == 0 is the very top of the scrollable content.
struct ListScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var contentHeight: CGFloat = 0

    var maxOffset: CGFloat { max(contentHeight - viewportHeight, 0) }
}

enum ListScroll {
    /// Scroll just enough to show `frame` completely, while keeping the same
    /// `padding` above/below it that the content uses at its top/bottom edge.
    /// Returns nil when the item is already comfortably visible.
    static func revealTarget(for frame: CGRect,
                             metrics: ListScrollMetrics,
                             padding: CGFloat) -> CGFloat? {
        guard metrics.viewportHeight > 0 else { return nil }
        let top = metrics.offset
        let bottom = top + metrics.viewportHeight
        let target: CGFloat
        if frame.maxY > bottom - padding {
            target = frame.maxY + padding - metrics.viewportHeight
        } else if frame.minY < top + padding {
            target = frame.minY - padding
        } else {
            return nil
        }
        let clamped = min(max(target, 0), metrics.maxOffset)
        return abs(clamped - top) > 0.5 ? clamped : nil
    }

    /// Go to Album/reveal semantics: leave the viewport alone when the item is
    /// already fully visible, even if it sits close to an edge. Only when it is
    /// actually clipped do we move it to the nearest fully visible edge, with
    /// the same content padding used by `revealTarget`.
    static func ensureVisibleTarget(for frame: CGRect,
                                    metrics: ListScrollMetrics,
                                    padding: CGFloat) -> CGFloat? {
        guard metrics.viewportHeight > 0 else { return nil }
        let top = metrics.offset
        let bottom = top + metrics.viewportHeight
        let target: CGFloat
        if frame.maxY > bottom {
            target = frame.maxY + padding - metrics.viewportHeight
        } else if frame.minY < top {
            target = frame.minY - padding
        } else {
            return nil
        }
        let clamped = min(max(target, 0), metrics.maxOffset)
        return abs(clamped - top) > 0.5 ? clamped : nil
    }

    /// Page navigation keeps the target row at the same top inset the content
    /// itself uses, clamped to the real content edges.
    static func pageTarget(for frame: CGRect,
                           metrics: ListScrollMetrics,
                           padding: CGFloat) -> CGFloat {
        let target = frame.minY - padding
        return min(max(target, 0), metrics.maxOffset)
    }
}
