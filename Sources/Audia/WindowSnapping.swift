import AppKit
import CoreGraphics

/// Edge-to-edge snapping for the custom-dragged Library/MiniPlayer window.
/// AppKit's title-bar snapping is bypassed because this window disables native
/// window movement and drags itself. This deliberately does not attract from a
/// distance: a snap only takes effect when abutting edges actually meet. The
/// snapshot is captured once at mouse-down so per-event work stays small.
@MainActor
struct WindowSnapContext {
    struct Result {
        var origin: NSPoint
        var activeX: CGFloat?
        var activeY: CGFloat?
    }

    private let screenFrames: [NSRect]
    private let windowFrames: [NSRect]
    private let attachDistance: CGFloat = 2
    private let detachDistance: CGFloat = 8

    init(excluding window: NSWindow) {
        screenFrames = NSScreen.screens.map(\.visibleFrame)
        windowFrames = Self.visibleWindowFrames(excluding: window)
    }

    func snap(proposedOrigin: NSPoint,
              size: NSSize,
              activeX: CGFloat?,
              activeY: CGFloat?) -> Result {
        let width = size.width
        let height = size.height
        let proposedFrame = NSRect(origin: proposedOrigin, size: size)

        var snappedX = activeX
        if let activeX, abs(proposedOrigin.x - activeX) > detachDistance {
            snappedX = nil
        }
        if snappedX == nil {
            snappedX = nearestTarget(
                proposedOrigin.x,
                candidates: xCandidates(for: proposedFrame)
            )
        }

        let x = snappedX ?? proposedOrigin.x
        var snappedY = activeY
        if let activeY, abs(proposedOrigin.y - activeY) > detachDistance {
            snappedY = nil
        }
        if snappedY == nil {
            let frameForY = NSRect(x: x, y: proposedOrigin.y, width: width, height: height)
            snappedY = nearestTarget(
                proposedOrigin.y,
                candidates: yCandidates(for: frameForY)
            )
        }

        let y = snappedY ?? proposedOrigin.y
        return Result(origin: NSPoint(x: x, y: y),
                      activeX: snappedX,
                      activeY: snappedY)
    }

    private func nearestTarget(_ value: CGFloat, candidates: [CGFloat]) -> CGFloat? {
        var result: CGFloat?
        var best = attachDistance
        for candidate in candidates {
            let distance = abs(candidate - value)
            if distance <= best {
                best = distance
                result = candidate
            }
        }
        return result
    }

    private func xCandidates(for frame: NSRect) -> [CGFloat] {
        var candidates: [CGFloat] = []
        for screen in screenFrames {
            candidates.append(screen.minX)
            candidates.append(screen.maxX - frame.width)
        }

        for other in windowFrames {
            guard spansOverlap(frame.minY...frame.maxY,
                               other.minY...other.maxY) else { continue }
            // Only flush contact: our right meets their left, or vice versa.
            candidates.append(other.minX - frame.width)
            candidates.append(other.maxX)
        }
        return candidates
    }

    private func yCandidates(for frame: NSRect) -> [CGFloat] {
        var candidates: [CGFloat] = []
        for screen in screenFrames {
            candidates.append(screen.minY)
            candidates.append(screen.maxY - frame.height)
        }

        for other in windowFrames {
            guard spansOverlap(frame.minX...frame.maxX,
                               other.minX...other.maxX) else { continue }
            // Only flush contact: our bottom meets their top, or vice versa.
            candidates.append(other.maxY)
            candidates.append(other.minY - frame.height)
        }
        return candidates
    }

    private func spansOverlap(_ lhs: ClosedRange<CGFloat>,
                              _ rhs: ClosedRange<CGFloat>) -> Bool {
        lhs.lowerBound < rhs.upperBound && lhs.upperBound > rhs.lowerBound
    }

    private static func visibleWindowFrames(excluding window: NSWindow) -> [NSRect] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let mainHeight = mainScreenHeight()
        var frames: [NSRect] = []
        frames.reserveCapacity(info.count)

        for entry in info {
            guard let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha > 0.01,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  number != window.windowNumber,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let quartzFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                continue
            }

            let frame = NSRect(
                x: quartzFrame.minX,
                y: mainHeight - quartzFrame.maxY,
                width: quartzFrame.width,
                height: quartzFrame.height
            )
            guard frame.width >= 80,
                  frame.height >= 40,
                  NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else {
                continue
            }
            frames.append(frame)
        }
        return frames
    }

    private static func mainScreenHeight() -> CGFloat {
        let mainDisplayID = CGMainDisplayID()
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if number?.uint32Value == mainDisplayID {
                return screen.frame.maxY
            }
        }
        return NSScreen.screens.first?.frame.maxY ?? 0
    }
}
