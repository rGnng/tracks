import Foundation
import os

/// Unified logging channels. Messages go to the system log, so they can be
/// viewed in Console.app without keeping an in-memory copy (Window > Log opens
/// it). Categories keep unrelated subsystems filterable.
enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.audia.tracks"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let database = Logger(subsystem: subsystem, category: "database")
    static let metadata = Logger(subsystem: subsystem, category: "metadata")
    static let artwork = Logger(subsystem: subsystem, category: "artwork")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let importer = Logger(subsystem: subsystem, category: "import")
    static let mpd = Logger(subsystem: subsystem, category: "mpd")
    static let shortcuts = Logger(subsystem: subsystem, category: "shortcuts")
}
