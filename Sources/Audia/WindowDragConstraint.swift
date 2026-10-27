import AppKit
import CoreGraphics

/// Collision constraints for the custom-dragged Library/MiniPlayer window.
///
/// This is deliberately not edge snapping. The window never jumps toward another
/// window or a screen edge; it simply stops when the user drags it into contact,
/// and cannot overlap other visible normal windows or leave the active screen's
/// visible frame. The window list is captured once at mouse-down.
@MainActor
struct WindowDragConstraint {
    private let screenFrames: [NSRect]
    private let windowFrames: [NSRect]
    private let windowGap: CGFloat = 0

    init(excluding window: NSWindow) {
        screenFrames = NSScreen.screens.map(\.visibleFrame)
        windowFrames = Self.visibleWindowFrames(excluding: window)
    }

    func resolve(proposedOrigin: NSPoint,
                 size: NSSize,
                 previousFrame: NSRect) -> NSPoint {
        var frame = NSRect(origin: proposedOrigin, size: size)
        frame = constrainToScreen(frame)
        frame = avoidWindows(frame, previousFrame: previousFrame)
        frame = constrainToScreen(frame)
        return frame.origin
    }

    private func constrainToScreen(_ frame: NSRect) -> NSRect {
        guard !screenFrames.isEmpty else { return frame }

        let screen = screenFrames.max { lhs, rhs in
            intersectionArea(frame, lhs) < intersectionArea(frame, rhs)
        } ?? screenFrames[0]

        var result = frame
        if result.width <= screen.width {
            result.origin.x = min(max(result.origin.x, screen.minX), screen.maxX - result.width)
        } else {
            result.origin.x = screen.minX
        }
        if result.height <= screen.height {
            result.origin.y = min(max(result.origin.y, screen.minY), screen.maxY - result.height)
        } else {
            result.origin.y = screen.minY
        }
        return result
    }

    private func intersectionArea(_ frame: NSRect, _ screen: NSRect) -> CGFloat {
        let intersection = frame.intersection(screen)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func avoidWindows(_ proposedFrame: NSRect,
                              previousFrame: NSRect) -> NSRect {
        var frame = proposedFrame
        guard !windowFrames.isEmpty else { return frame }

        let movementX = proposedFrame.minX - previousFrame.minX
        let movementY = proposedFrame.minY - previousFrame.minY

        for _ in 0..<4 {
            var moved = false
            for other in windowFrames {
                // Ignore windows that were already overlapping when this drag
                // sample began. Trying to separate those would teleport the
                // window; only prevent newly entering another window.
                guard !previousFrame.intersects(other),
                      frame.intersects(other) else { continue }

                let overlapX = min(frame.maxX, other.maxX) - max(frame.minX, other.minX)
                let overlapY = min(frame.maxY, other.maxY) - max(frame.minY, other.minY)
                guard overlapX > 0, overlapY > 0 else { continue }

                // Resolve along the dominant drag direction so a horizontal
                // drag stops at the window's side instead of being pushed up or
                // down by the smallest-overlap heuristic.
                if abs(movementX) >= abs(movementY), abs(movementX) > 0.001 {
                    if movementX > 0 {
                        frame.origin.x = other.minX - frame.width - windowGap
                    } else {
                        frame.origin.x = other.maxX + windowGap
                    }
                } else if abs(movementY) > 0.001 {
                    if movementY > 0 {
                        frame.origin.y = other.minY - frame.height - windowGap
                    } else {
                        frame.origin.y = other.maxY + windowGap
                    }
                }
                moved = true
            }
            if !moved { break }
        }
        return frame
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
