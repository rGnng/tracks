import AppKit

@MainActor
enum LogViewer {
    /// Opens Console.app, macOS's built-in unified-log viewer. The app logs
    /// under the `com.audia.tracks` subsystem; Console's search field and
    /// process sidebar can narrow the stream to Tracks.
    static func openConsole() {
        let candidates = [
            "/System/Applications/Utilities/Console.app",
            "/Applications/Utilities/Console.app",
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            AppLog.app.error("Console.app was not found; cannot open the log viewer")
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
