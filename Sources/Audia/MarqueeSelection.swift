import SwiftUI

struct MarqueeFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Adds drag-to-select behavior to a list/grid content view. Rows publish their
/// frames through `MarqueeFramesKey`; a quick drag draws a selection rectangle,
/// while a long-press-armed drag promotes the row's payload to an item drag.
private struct MarqueeSelectionModifier: ViewModifier {
    @Binding var selection: Set<UUID>
    let space: String

    @State private var frames: [UUID: CGRect] = [:]
    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @State private var baseSelection: Set<UUID> = []
    @State private var globalOrigin: CGPoint = .zero

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: space)
            .onPreferenceChange(MarqueeFramesKey.self) { frames = $0 }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { globalOrigin = proxy.frame(in: .global).origin }
                        .onChange(of: proxy.frame(in: .global).origin) { _, origin in
                            globalOrigin = origin
                        }
                }
            )
            .overlay {
                if let start, let current {
                    let rect = CGRect(x: min(start.x, current.x),
                                      y: min(start.y, current.y),
                                      width: abs(start.x - current.x),
                                      height: abs(start.y - current.y))
                    Rectangle()
                        .fill(Theme.selectionFill.opacity(0.14))
                        .overlay(
                            Rectangle().strokeBorder(Theme.selectionFill.opacity(0.80), lineWidth: 1)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(marqueeGesture)
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
            .onChanged { value in
                if DragController.shared.isArmed {
                    DragController.shared.isMarqueeActive = false
                    start = nil
                    current = nil
                    if DragController.shared.payload == nil {
                        DragController.shared.beginArmed()
                    }
                    let global = CGPoint(x: value.location.x + globalOrigin.x,
                                         y: value.location.y + globalOrigin.y)
                    DragController.shared.update(location: global)
                    return
                }

                DragController.shared.isMarqueeActive = true
                if start == nil {
                    start = value.startLocation
                    baseSelection = selection
                }
                current = value.location
                updateSelection()
            }
            .onEnded { _ in
                if DragController.shared.payload != nil {
                    DragController.shared.finish()
                }
                DragController.shared.isMarqueeActive = false
                start = nil
                current = nil
            }
    }

    private func updateSelection() {
        guard let start, let current else { return }
        let rect = CGRect(x: min(start.x, current.x),
                          y: min(start.y, current.y),
                          width: abs(start.x - current.x),
                          height: abs(start.y - current.y))
        let hits = Set(frames.filter { $0.value.intersects(rect) }.keys)
        let additive = NSEvent.modifierFlags.contains(.command)
            || NSEvent.modifierFlags.contains(.shift)
        selection = additive ? baseSelection.union(hits) : hits
    }
}

extension View {
    func marqueeSelectable(selection: Binding<Set<UUID>>, space: String) -> some View {
        modifier(MarqueeSelectionModifier(selection: selection, space: space))
    }
}
