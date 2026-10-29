import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private let bundleIdentifier = "com.audia.tracks"

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

private func runningApplication() -> NSRunningApplication {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
        return app
    }
    if let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName == "Tracks" || $0.localizedName == "Audia"
    }) {
        return app
    }
    fail("Tracks is not running")
}

private let runningApp = runningApplication()
private let appPID = runningApp.processIdentifier
private let appElement = AXUIElementCreateApplication(appPID)

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}

private func point(_ element: AXUIElement) -> CGPoint {
    guard let value = attribute(element, kAXPositionAttribute) else { return .zero }
    var point = CGPoint.zero
    AXValueGetValue(value as! AXValue, .cgPoint, &point)
    return point
}

private func size(_ element: AXUIElement) -> CGSize {
    guard let value = attribute(element, kAXSizeAttribute) else { return .zero }
    var size = CGSize.zero
    AXValueGetValue(value as! AXValue, .cgSize, &size)
    return size
}

private func frameString(_ element: AXUIElement) -> String {
    let p = point(element)
    let s = size(element)
    return String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", p.x, p.y, s.width, s.height)
}

private func windows() -> [AXUIElement] {
    attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
}

private func window(named title: String) -> AXUIElement? {
    windows().first { stringAttribute($0, kAXTitleAttribute) == title }
}

private func walk(_ element: AXUIElement,
                  depth: Int = 0,
                  _ body: (AXUIElement, Int) -> Bool) {
    if body(element, depth) { return }
    guard depth < 50,
          let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for child in children {
        walk(child, depth: depth + 1, body)
    }
}

private func focusWindow(named title: String) {
    guard let window = window(named: title) else {
        fail("window not found: \(title)")
    }
    _ = runningApp.activate(options: [.activateAllWindows])
    AXUIElementSetAttributeValue(appElement,
                                 kAXFocusedWindowAttribute as CFString,
                                 window)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(80_000)
}

private func clearModifiers() {
    let source = CGEventSource(stateID: .hidSystemState)
    for key: CGKeyCode in [55, 56, 58, 59, 60, 61, 62] {
        if let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
            down.type = .flagsChanged
            down.flags = []
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            up.type = .flagsChanged
            up.flags = []
            up.post(tap: .cghidEventTap)
        }
    }
}

private func sendKey(_ keyCode: CGKeyCode, modifiers: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
        down.flags = modifiers
        down.post(tap: .cghidEventTap)
    }
    usleep(25_000)
    if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
        up.flags = modifiers
        up.post(tap: .cghidEventTap)
    }
    usleep(25_000)
    clearModifiers()
}

private func findButton(in window: AXUIElement,
                        label: String,
                        exact: Bool = true) -> AXUIElement? {
    var result: AXUIElement?
    walk(window) { element, _ in
        guard result == nil else { return true }
        let role = stringAttribute(element, kAXRoleAttribute)
        guard role == "AXButton" || role == "AXMenuButton" else { return false }
        let fields = [
            stringAttribute(element, kAXTitleAttribute),
            stringAttribute(element, kAXDescriptionAttribute),
            stringAttribute(element, kAXHelpAttribute)
        ]
        if fields.contains(where: { exact ? $0 == label : $0.localizedCaseInsensitiveContains(label) }) {
            result = element
            return true
        }
        return false
    }
    return result
}

private func findTextField(in window: AXUIElement) -> AXUIElement? {
    var result: AXUIElement?
    walk(window) { element, _ in
        guard result == nil else { return true }
        let role = stringAttribute(element, kAXRoleAttribute)
        if role == "AXTextField" || role == "AXTextArea" {
            result = element
            return true
        }
        return false
    }
    return result
}

private func typeText(_ text: String, into field: AXUIElement) {
    AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFTypeRef)
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(80_000)

    let source = CGEventSource(stateID: .hidSystemState)
    for codeUnit in text.utf16 {
        var unit = codeUnit
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up.post(tap: .cghidEventTap)
        }
        usleep(4_000)
    }
}

private struct TextNode {
    let depth: Int
    let value: String
}

private let sectionTitles: Set<String> = [
    "Album Locator", "AlbumGrid", "SongTable", "Browser", "AlbumDetail",
    "Sidebar", "Playback"
]

private let metricLabels: Set<String> = [
    "status", "album", "index", "columns", "card", "row height",
    "computed", "cached", "cache delta", "cache delta min", "cache delta max",
    "offset at request", "target offset", "viewport / content",
    "albums", "selected", "selected id", "grid width", "first album gap",
    "cached selected", "model selected", "reveal source", "reveal target",
    "offset before", "scroll id", "scroll point", "scroll edge",
    "user positioned", "offset", "viewport", "content", "context", "rows",
    "title", "items", "songs selected", "pane offset", "pane viewport",
    "pane content", "list offset", "list viewport", "list content",
    "songs", "selection", "playlists", "focus", "last arrow", "last scroll",
    "state", "artist", "elapsed", "queue", "current index", "volume",
    "system volume", "volume locked", "muted", "shuffle", "repeat",
    "missing", "history", "queue entry"
]

private func textNodes(in window: AXUIElement) -> [TextNode] {
    var nodes: [TextNode] = []
    walk(window) { element, depth in
        guard stringAttribute(element, kAXRoleAttribute) == "AXStaticText" else { return false }
        let value = stringAttribute(element, kAXValueAttribute)
        if !value.isEmpty {
            nodes.append(TextNode(depth: depth, value: value))
        }
        return false
    }
    return nodes
}

private func printMetrics(section: String?) {
    openDebugWindowIfNeeded()
    guard let debugWindow = window(named: "Debug") else {
        fail("Debug window not found")
    }

    let nodes = textNodes(in: debugWindow).map(\.value)
    var currentSection = "General"
    var currentFiltered = section == nil || section == "General"
    var printedSection: String?
    var i = 0

    while i < nodes.count {
        let value = nodes[i]

        if sectionTitles.contains(value) {
            currentSection = value
            currentFiltered = section == nil || section == value
            if currentFiltered && section == nil && printedSection != value {
                print("\n[\(value)]")
                printedSection = value
            }
            i += 1
            continue
        }

        guard metricLabels.contains(value) else {
            i += 1
            continue
        }

        // SwiftUI accessibility exposes duplicated label nodes. Skip all
        // leading copies of the label before collecting its value nodes.
        var next = i + 1
        while next < nodes.count, nodes[next] == value {
            next += 1
        }

        guard next < nodes.count,
              !sectionTitles.contains(nodes[next]),
              !metricLabels.contains(nodes[next]) else {
            i = next
            continue
        }

        // A metric can also be exposed twice (stale and current). The last
        // value is the one currently rendered.
        var lastValue = nodes[next]
        var end = next + 1
        while end < nodes.count,
              !sectionTitles.contains(nodes[end]),
              !metricLabels.contains(nodes[end]) {
            lastValue = nodes[end]
            end += 1
        }

        if currentFiltered {
            print("\(currentSection).\(value) = \(lastValue)")
        }
        i = end
    }
}

private func printRawMetrics() {
    openDebugWindowIfNeeded()
    guard let debugWindow = window(named: "Debug") else {
        fail("Debug window not found")
    }
    for node in textNodes(in: debugWindow) {
        print("\(node.depth)\t\(node.value)")
    }
}

private func pressMenuItem(_ title: String) -> Bool {
    guard let menuBar = attribute(appElement, kAXMenuBarAttribute) else { return false }
    var pressed = false
    walk(menuBar as! AXUIElement) { element, _ in
        guard !pressed else { return true }
        let role = stringAttribute(element, kAXRoleAttribute)
        guard role == "AXMenuItem" else { return false }
        let label = stringAttribute(element, kAXTitleAttribute)
        guard label == title else { return false }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        pressed = result == .success
        return pressed
    }
    return pressed
}

private func openDebugWindowIfNeeded() {
    if window(named: "Debug") != nil { return }

    _ = runningApp.activate(options: [.activateAllWindows])
    if pressMenuItem("Debug Panel") {
        usleep(500_000)
        if window(named: "Debug") != nil { return }
    }

    focusWindow(named: "Tracks")
    sendKey(2, modifiers: [.maskCommand, .maskAlternate, .maskControl])
    usleep(500_000)
    if window(named: "Debug") == nil {
        fail("could not open Debug window")
    }
}

private func locateAlbum(_ identifier: String) {
    openDebugWindowIfNeeded()
    focusWindow(named: "Debug")

    if findButton(in: window(named: "Debug")!, label: "Hide Input") == nil {
        guard let reveal = findButton(in: window(named: "Debug")!, label: "Locate Album…") else {
            fail("Locate Album… button not found")
        }
        AXUIElementPerformAction(reveal, kAXPressAction as CFString)
        usleep(200_000)
    }

    guard let debugWindow = window(named: "Debug"),
          let field = findTextField(in: debugWindow) else {
        fail("locator text field not found")
    }
    focusWindow(named: "Debug")
    typeText(identifier, into: field)
    usleep(150_000)

    guard let locate = findButton(in: debugWindow, label: "Locate") else {
        fail("Locate button not found")
    }
    AXUIElementPerformAction(locate, kAXPressAction as CFString)
    usleep(1_000_000)
    print("located \(identifier)")
    printMetrics(section: "Album Locator")
}

private func moveMouse(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left)?.post(tap: .cghidEventTap)
}

private func drag(from start: CGPoint, to end: CGPoint) {
    focusWindow(named: "Tracks")
    moveMouse(.mouseMoved, start)
    usleep(80_000)
    moveMouse(.leftMouseDown, start)
    usleep(40_000)
    let steps = 30
    for step in 1...steps {
        let t = CGFloat(step) / CGFloat(steps)
        moveMouse(.leftMouseDragged,
                  CGPoint(x: start.x + (end.x - start.x) * t,
                          y: start.y + (end.y - start.y) * t))
        usleep(12_000)
    }
    moveMouse(.leftMouseUp, end)
    usleep(100_000)
}

private func defaultLibraryPath() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [
        home.appendingPathComponent("Music/Tracks/library.sqlite").path,
        home.appendingPathComponent("Library/Application Support/Tracks/library.sqlite").path
    ]
    return candidates.first { path in
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return size > 0
    }
}

private func albums(from database: String) -> [(id: UUID, title: String)] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [
        "-separator", "\t", database,
        "select id, title from albums where exists (select 1 from songs where songs.album_id = albums.id);"
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.standardError
    do {
        try process.run()
    } catch {
        fail("could not run sqlite3: \(error.localizedDescription)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fail("sqlite3 failed")
    }
    let output = String(data: data, encoding: .utf8) ?? ""
    var result: [(UUID, String)] = []
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])) else { continue }
        result.append((id, String(parts[1])))
    }
    result.sort { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    return result
}

private func parseDatabaseArgument(_ arguments: [String]) -> (String, [String]) {
    var args = arguments
    var database: String?
    if let index = args.firstIndex(of: "--db"), index + 1 < args.count {
        database = args[index + 1]
        args.removeSubrange(index...(index + 1))
    }
    guard let path = database ?? defaultLibraryPath() else {
        fail("library.sqlite not found; pass --db /path/to/library.sqlite")
    }
    return (path, args)
}

private func usage() -> Never {
    print("""
    usage: audiactl <command> [arguments]

      metrics [section]              Print Debug-window metrics; optionally one section.
      raw-metrics                    Print all Debug-window static texts with depth.
      locate <album-uuid>            Focus the Debug locator, enter the UUID and locate it.
      focus [Tracks|Debug]           Activate and focus a window (default Tracks).
      press <window> <label>         Press an exact AX button label.
      type <window> <text>           Type into the first text field in a window.
      key <keycode> [cmd|shift|option|control]
                                     Send a key to Tracks and clear modifier state.
      clear-flags                    Release synthetic modifier keys.
      resize <width> <height>        Resize the Tracks window.
      windows                        Print all window titles and frames.
      drag <x1> <y1> <x2> <y2>       Drag with the left mouse button.
      album-at-index <index> [--db path]
      album-index <uuid> [--db path]
    """)
    exit(2)
}

private let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
let rest = Array(arguments.dropFirst())

switch command {
case "metrics":
    printMetrics(section: rest.first)
case "raw-metrics":
    printRawMetrics()
case "locate":
    guard let id = rest.first else { usage() }
    locateAlbum(id)
case "focus":
    focusWindow(named: rest.first ?? "Tracks")
    print("focused \(rest.first ?? "Tracks")")
case "press":
    guard rest.count >= 2 else { usage() }
    let title = rest[0]
    let label = rest.dropFirst().joined(separator: " ")
    focusWindow(named: title)
    guard let target = window(named: title),
          let button = findButton(in: target, label: label) else {
        fail("button not found: \(label)")
    }
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    print("pressed \(label) (\(result.rawValue))")
case "type":
    guard rest.count >= 2 else { usage() }
    let title = rest[0]
    let text = rest.dropFirst().joined(separator: " ")
    focusWindow(named: title)
    guard let target = window(named: title),
          let field = findTextField(in: target) else {
        fail("text field not found in \(title)")
    }
    typeText(text, into: field)
    print("typed into \(title)")
case "key":
    guard let rawCode = rest.first, let code = UInt16(rawCode) else { usage() }
    var flags: CGEventFlags = []
    for modifier in rest.dropFirst() {
        switch modifier {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "option", "alt": flags.insert(.maskAlternate)
        case "control", "ctrl": flags.insert(.maskControl)
        default: fail("unknown modifier: \(modifier)")
        }
    }
    focusWindow(named: "Tracks")
    sendKey(code, modifiers: flags)
    print("key \(code)")
case "clear-flags":
    clearModifiers()
    print("cleared modifiers")
case "resize":
    guard rest.count == 2,
          let width = Double(rest[0]),
          let height = Double(rest[1]) else { usage() }
    focusWindow(named: "Tracks")
    guard let tracks = window(named: "Tracks") else { fail("Tracks window not found") }
    var newSize = CGSize(width: width, height: height)
    let value = AXValueCreate(.cgSize, &newSize)!
    let result = AXUIElementSetAttributeValue(tracks, kAXSizeAttribute as CFString, value)
    print("resize \(Int(width))x\(Int(height)) (\(result.rawValue))")
case "windows":
    for window in windows() {
        print("\(stringAttribute(window, kAXTitleAttribute)) \(frameString(window))")
    }
case "drag":
    guard rest.count == 4,
          let x1 = Double(rest[0]), let y1 = Double(rest[1]),
          let x2 = Double(rest[2]), let y2 = Double(rest[3]) else { usage() }
    drag(from: CGPoint(x: x1, y: y1), to: CGPoint(x: x2, y: y2))
    print("dragged")
case "album-at-index":
    let (database, args) = parseDatabaseArgument(rest)
    guard let rawIndex = args.first, let index = Int(rawIndex) else { usage() }
    let rows = albums(from: database)
    guard rows.indices.contains(index) else { fail("index out of range (0...\(rows.count - 1))") }
    print("\(index)\t\(rows[index].id.uuidString)\t\(rows[index].title)")
case "album-index":
    let (database, args) = parseDatabaseArgument(rest)
    guard let rawID = args.first, let id = UUID(uuidString: rawID) else { usage() }
    let rows = albums(from: database)
    guard let index = rows.firstIndex(where: { $0.id == id }) else { fail("album not found") }
    print("\(index)\t\(rows[index].id.uuidString)\t\(rows[index].title)")
default:
    usage()
}
