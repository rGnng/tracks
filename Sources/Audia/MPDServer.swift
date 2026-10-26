import Foundation
import Darwin
import Combine

struct MPDResponse: Sendable {
    var text: String = ""
    var binary: Data? = nil
    var close: Bool = false
    var authenticated: Bool? = nil
    var idle: Bool = false
}

@MainActor
final class MPDServer: ObservableObject, @unchecked Sendable {
    static let shared = MPDServer()

    @Published private(set) var isRunning = false
    @Published private(set) var status = "Disabled"
    @Published private(set) var listeningSummary = ""

    private var listeners: [MPDListener] = []
    private var sessions: [ObjectIdentifier: MPDClientSession] = [:]
    private var idleSessions: [ObjectIdentifier: MPDClientSession] = [:]
    private var password = ""
    /// URI -> album ID cache. Artwork normally arrives in several chunks; the
    /// album lookup scans the whole library and must not run for every chunk.
    private var albumIDCache: [String: UUID] = [:]
    private var playlistVersion: UInt32 = 1
    private var singleMode = false
    private var consumeMode = false
    private var startedAt = Date()

    private init() {
        NotificationCenter.default.addObserver(
            forName: .libraryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.albumIDCache.removeAll() }
        }
    }

    // MARK: Configuration

    func startFromPreferences() {
        applyPreferences()
    }

    func applyPreferences() {
        stopServer()
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "mpd.enabled") else {
            status = "Disabled"
            return
        }

        let portValue = defaults.integer(forKey: "mpd.port")
        let port = UInt16(exactly: portValue).flatMap { $0 > 0 ? $0 : nil } ?? 6600
        password = defaults.string(forKey: "mpd.password") ?? ""

        let all = defaults.bool(forKey: "mpd.allInterfaces")
        let addresses: [String]
        if all {
            addresses = ["0.0.0.0", "::"]
        } else {
            let raw = defaults.string(forKey: "mpd.addresses") ?? "127.0.0.1"
            let parsed = raw.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            addresses = parsed.isEmpty ? ["127.0.0.1"] : parsed
        }

        var started: [String] = []
        var failures: [String] = []
        for address in addresses {
            if let listener = MPDListener(host: address, port: port, server: self) {
                listeners.append(listener)
                started.append(listener.displayAddress)
            } else {
                failures.append(address)
            }
        }

        startedAt = Date()
        isRunning = !listeners.isEmpty
        listeningSummary = started.joined(separator: ", ")
        if listeners.isEmpty {
            status = "Could not listen on \(failures.joined(separator: ", ")) :\(port)"
        } else if failures.isEmpty {
            status = "Listening on \(listeningSummary):\(port)"
        } else {
            status = "Listening on \(listeningSummary):\(port) (failed: \(failures.joined(separator: ", ")))"
        }
    }

    private func stopServer() {
        for listener in listeners { listener.stop() }
        listeners.removeAll()
        for session in sessions.values { session.close() }
        sessions.removeAll()
        idleSessions.removeAll()
        isRunning = false
        listeningSummary = ""
    }

    func addSession(_ session: MPDClientSession) {
        sessions[ObjectIdentifier(session)] = session
    }

    func removeSession(_ session: MPDClientSession) {
        sessions.removeValue(forKey: ObjectIdentifier(session))
        idleSessions.removeValue(forKey: ObjectIdentifier(session))
    }

    func registerIdle(_ session: MPDClientSession) {
        idleSessions[ObjectIdentifier(session)] = session
    }

    func unregisterIdle(_ session: MPDClientSession) {
        idleSessions.removeValue(forKey: ObjectIdentifier(session))
    }

    private func broadcastIdle(_ subsystem: String) {
        // Notify every connection, not just the ones currently blocked in
        // `idle`. libmpdclient/ncmpcpp calls `noidle` before a command such as
        // `volume`, then re-enters idle afterwards; queueing the event for that
        // short gap is what makes the client's volume display update.
        let sessions = Array(self.sessions.values)
        idleSessions.removeAll()
        for session in sessions { session.sendChanged(subsystem) }
    }

    // MARK: Protocol

    func execute(line: String, authenticated: Bool, session: MPDClientSession?) -> MPDResponse {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ok() }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let command = String(parts[0]).lowercased()
        let remainder = parts.count > 1 ? String(parts[1]) : ""
        let args = tokenize(remainder)

        if !password.isEmpty, !authenticated {
            let allowed = ["password", "close", "commands", "notcommands", "ping"]
            guard allowed.contains(command) else {
                return ack(4, command, "you must not send this command")
            }
        }

        switch command {
        case "password":
            guard let supplied = args.first else {
                return ack(2, command, "wrong number of arguments")
            }
            if password.isEmpty || supplied == password {
                return MPDResponse(text: "OK\n", authenticated: true)
            }
            return ack(3, command, "incorrect password")

        case "ping":
            return ok()
        case "close":
            return MPDResponse(text: "OK\n", close: true)
        case "commands":
            return lines(commandsList.map { "command: \($0)" })
        case "notcommands":
            return ok()
        case "tagtypes":
            return lines(["Artist", "Album", "AlbumArtist", "Title", "Track", "Disc", "Genre", "Date", "Comment"].map { "tagtype: \($0)" })
        case "urlhandlers":
            return ok()
        case "decoders":
            return lines(["plugin: flac", "plugin: mad", "plugin: ffmpeg", "plugin: oggflac"])
        case "outputs":
            return lines(outputLines())

        case "enableoutput", "disableoutput", "toggleoutput":
            guard let id = args.first.flatMap(Int.init) else {
                return ack(2, command, "wrong number of arguments")
            }
            let devices = AudioDevices.shared.devices
            guard devices.indices.contains(id) else {
                return ack(2, command, "No such audio output")
            }
            let wasEnabled = outputEnabled(id, in: devices)
            switch command {
            case "enableoutput":
                AudioDevices.shared.select(devices[id])
            case "disableoutput":
                if wasEnabled, let systemDefault = devices.first(where: { $0.isSystemDefault }) {
                    AudioDevices.shared.select(systemDefault)
                }
            default:
                if wasEnabled {
                    if let systemDefault = devices.first(where: { $0.isSystemDefault }) {
                        AudioDevices.shared.select(systemDefault)
                    }
                } else {
                    AudioDevices.shared.select(devices[id])
                }
            }
            broadcastIdle("output")
            return ok()
        case "replay_gain_status":
            return lines(["replay_gain_mode: off"])
        case "idle":
            if let session { registerIdle(session) }
            return MPDResponse(idle: true)
        case "noidle":
            if let session { unregisterIdle(session) }
            return ok()

        case "status":
            return lines(statusLines())
        case "stats":
            return lines(statsLines())
        case "currentsong":
            return lines(currentSongLines())
        case "playlistinfo":
            return lines(playlistLines(range: parseRange(args.first)))
        case "playlistid":
            let id = args.first.flatMap { Int($0) }
            if let id, id > 0 {
                return lines(playlistLines(ids: [id - 1]))
            }
            return lines(playlistLines(range: nil))
        case "plchanges", "plchangesposid":
            if command == "plchangesposid" {
                return lines(queueChangesPosIDLines())
            }
            return lines(playlistLines(range: nil))

        case "add":
            guard let path = args.first else { return ack(2, command, "wrong number of arguments") }
            let songs = librarySongs(forPath: path)
            guard !songs.isEmpty else { return ack(50, command, "No such directory") }
            PlayerState.shared.appendToQueue(songs)
            bumpPlaylist()
            return ok()
        case "addid":
            guard let path = args.first else { return ack(2, command, "wrong number of arguments") }
            let songs = librarySongs(forPath: path)
            guard !songs.isEmpty else { return ack(50, command, "No such directory") }
            let position = args.count > 1 ? Int(args[1]) : nil
            let id: Int
            if let position, position >= 0 {
                PlayerState.shared.insertIntoQueue(songs, at: position)
                id = position + 1
            } else {
                id = PlayerState.shared.queue.count + 1
                PlayerState.shared.appendToQueue(songs)
            }
            bumpPlaylist()
            return lines(["Id: \(id)"])
        case "clear":
            PlayerState.shared.clearQueue()
            bumpPlaylist()
            return ok()
        case "delete", "deleteid":
            if command == "deleteid", let id = args.first.flatMap(Int.init), id > 0 {
                PlayerState.shared.removeQueue(at: IndexSet(integer: id - 1))
            } else if let range = parseRange(args.first) {
                PlayerState.shared.removeQueue(at: IndexSet(integersIn: range))
            } else {
                return ack(2, command, "wrong number of arguments")
            }
            bumpPlaylist()
            return ok()
        case "move", "moveid":
            var from: Int?
            var to: Int?
            if command == "moveid" {
                if let id = args.first.flatMap(Int.init), id > 0 { from = id - 1 }
                to = args.dropFirst().first.flatMap(Int.init)
            } else {
                from = args.first.flatMap(Int.init)
                to = args.dropFirst().first.flatMap(Int.init)
            }
            guard let from, let to else { return ack(2, command, "wrong number of arguments") }
            PlayerState.shared.moveQueue(from: from, to: to)
            bumpPlaylist()
            return ok()
        case "shuffle":
            PlayerState.shared.shuffleQueue()
            bumpPlaylist()
            return ok()

        case "play", "playid":
            if command == "playid", let id = args.first.flatMap(Int.init) {
                guard id > 0 else { return ack(2, command, "wrong number of arguments") }
                let position = id - 1
                let queue = PlayerState.shared.queue
                guard queue.indices.contains(position) else { return ack(2, command, "Bad song index") }
                PlayerState.shared.playQueue(at: position)
            } else if let raw = args.first, let position = Int(raw) {
                let queue = PlayerState.shared.queue
                guard queue.indices.contains(position) else { return ack(2, command, "Bad song index") }
                PlayerState.shared.playQueue(at: position)
            } else {
                let player = PlayerState.shared
                switch playbackState {
                case .stop:
                    if !player.queue.isEmpty {
                        player.playQueue(at: player.currentIndex ?? 0)
                    }
                case .pause:
                    player.setPaused(false)
                case .play:
                    break
                }
            }
            bumpPlaylist()
            return ok()
        case "pause":
            let player = PlayerState.shared
            let requested: Bool?
            if let arg = args.first {
                requested = arg == "0" ? false : true
            } else {
                requested = nil
            }
            if requested == nil {
                if player.currentSong != nil {
                    player.setPaused(player.isPlaying)
                }
            } else if let requested {
                if requested {
                    if player.currentSong == nil, !player.queue.isEmpty {
                        player.playQueue(at: 0)
                    }
                    player.setPaused(true)
                } else {
                    if player.currentSong == nil, !player.queue.isEmpty {
                        player.playQueue(at: 0)
                    } else {
                        player.setPaused(false)
                    }
                }
            }
            return ok()
        case "stop":
            PlayerState.shared.stopPlayback()
            broadcastIdle("player")
            return ok()
        case "next":
            PlayerState.shared.next()
            broadcastIdle("player")
            return ok()
        case "previous":
            PlayerState.shared.previous()
            broadcastIdle("player")
            return ok()
        case "seek", "seekid":
            guard args.count >= 2, let time = parseTime(args[1]) else {
                return ack(2, command, "wrong number of arguments")
            }
            if command == "seekid", let id = Int(args[0]), id > 0 {
                PlayerState.shared.playQueue(at: id - 1)
            } else if let position = Int(args[0]) {
                let player = PlayerState.shared
                if player.currentIndex != position {
                    player.playQueue(at: position)
                }
            }
            PlayerState.shared.seek(toSeconds: time)
            broadcastIdle("player")
            return ok()
        case "seekcur":
            guard let raw = args.first, let time = parseTime(raw) else {
                return ack(2, command, "wrong number of arguments")
            }
            let player = PlayerState.shared
            if raw.hasPrefix("+") || raw.hasPrefix("-") {
                player.seek(toSeconds: player.elapsed + time)
            } else {
                player.seek(toSeconds: time)
            }
            broadcastIdle("player")
            return ok()
        case "getvol":
            return lines(["volume: \(reportedVolume)"])

        case "setvol", "volume":
            guard let rawValue = args.first, let value = Int(rawValue) else {
                if command == "volume" {
                    return lines(["volume: \(reportedVolume)"])
                }
                return ack(2, command, "wrong number of arguments")
            }
            // MPD's `volume` command is relative, while `setvol` is absolute.
            // libmpdclient (used by ncmpcpp) formats positive relative values
            // as plain numbers ("volume 2"), so the command name matters just
            // as much as a leading sign.
            // A literal `volume 0` is commonly used by remote mute buttons as
            // an absolute mute, while non-zero `volume` values are relative.
            let isMuteRequest = command == "volume" && value == 0
            let isRelative = !isMuteRequest && (command == "volume"
                || rawValue.hasPrefix("+")
                || rawValue.hasPrefix("-"))
            let target = isMuteRequest ? 0 : (isRelative ? reportedVolume + value : value)
            let percent = min(max(target, 0), 100)
            let fraction = Double(percent) / 100
            if PlayerState.shared.isVolumeLocked {
                PlayerState.shared.setSystemVolume(fraction)
            } else {
                PlayerState.shared.setVolume(fraction)
            }
            broadcastIdle("mixer")
            return ok()
        case "repeat":
            guard let value = args.first else { return ack(2, command, "wrong number of arguments") }
            let player = PlayerState.shared
            if value == "0" {
                player.setRepeatMode(.off)
            } else {
                player.setRepeatMode(singleMode ? .one : .all)
            }
            broadcastIdle("options")
            return ok()
        case "random":
            guard let value = args.first else { return ack(2, command, "wrong number of arguments") }
            PlayerState.shared.setShuffle(value != "0")
            broadcastIdle("options")
            return ok()
        case "single":
            guard let value = args.first else { return ack(2, command, "wrong number of arguments") }
            let player = PlayerState.shared
            singleMode = value != "0"
            if singleMode {
                // MPD's "repeat one" is repeat=1 plus single=1/oneshot.
                if player.repeatMode != .off {
                    player.setRepeatMode(.one)
                }
            } else if player.repeatMode == .one {
                // Turning single off while repeat stays on falls back to All.
                player.setRepeatMode(.all)
            }
            broadcastIdle("options")
            return ok()
        case "consume":
            guard let value = args.first else { return ack(2, command, "wrong number of arguments") }
            consumeMode = value != "0"
            broadcastIdle("options")
            return ok()
        case "toggle":
            let player = PlayerState.shared
            if player.currentSong != nil {
                player.togglePlayPause()
            }
            broadcastIdle("player")
            return ok()

        case "albumart", "readpicture":
            guard let uri = args.first else { return ack(2, command, "wrong number of arguments") }
            let offset = args.count > 1 ? Int(args[1]) ?? 0 : 0
            return artworkResponse(uri: uri, offset: offset, session: session)
        case "binarylimit":
            guard let raw = args.first, let value = Int(raw), value > 0 else {
                return ack(2, command, "wrong number of arguments")
            }
            session?.binaryLimit = min(max(value, 1024), 4 * 1024 * 1024)
            return ok()
        case "update", "rescan":
            Library.shared.rescanAll()
            return lines(["updating_db: 1"])
        case "listall":
            let songs = args.first.map { librarySongs(forPath: $0) } ?? librarySongs()
            return lines(songs.map { "file: \($0.fileURL?.path ?? $0.title)" })
        case "listallinfo":
            let songs = args.first.map { librarySongs(forPath: $0) } ?? librarySongs()
            return lines(songs.flatMap { songInfoLines($0) })
        case "lsinfo":
            let directory = args.first ?? "/"
            return lines(lsinfoLines(directory: directory))
        case "find", "search":
            let filters = parseFilters(raw: remainder)
            let matches = filteredSongs(filters: filters, substring: command == "search")
            return lines(matches.flatMap { songInfoLines($0) })
        case "findadd", "searchadd":
            let filters = parseFilters(raw: remainder)
            let matches = filteredSongs(filters: filters, substring: command == "searchadd")
            if !matches.isEmpty {
                PlayerState.shared.appendToQueue(matches)
                bumpPlaylist()
            }
            return ok()
        case "list":
            guard let tag = args.first else { return ack(2, command, "wrong number of arguments") }
            let filters = Array(args.dropFirst())
            let values: [String]
            if filters.isEmpty || filters.count % 2 == 0 {
                let parsed = filters.count % 2 == 0 ? pairs(filters) : []
                values = filteredSongs(filters: parsed, substring: false).compactMap { songValue($0, tag: tag) }
            } else {
                values = filteredSongs(filters: [], substring: false).compactMap { songValue($0, tag: tag) }
            }
            let unique = Array(Set(values)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return lines(unique.map { "\(canonicalTag(tag)): \($0)" })
        case "count":
            let filters = pairs(args)
            let matches = filteredSongs(filters: filters, substring: false)
            let playtime = Int(matches.reduce(0) { $0 + $1.duration }.rounded())
            return lines(["songs: \(matches.count)", "playtime: \(playtime)"])
        case "playlistfind":
            let filters = pairs(args)
            let matches = filteredSongs(filters: filters, substring: false)
            var output: [String] = []
            for song in matches {
                if let index = PlayerState.shared.queue.firstIndex(where: { $0.id == song.id }) {
                    output.append(contentsOf: playlistSongLines(song, position: index))
                }
            }
            return lines(output)
        case "listplaylists":
            var values: [String] = []
            for playlist in mpdPlaylists {
                values.append("playlist: \(playlist.name)")
                values.append("Last-Modified: \(playlistModifiedString(playlist))")
            }
            return lines(values)
        case "listplaylist", "listplaylistinfo":
            guard let name = args.first else { return ack(2, command, "wrong number of arguments") }
            guard let playlist = Library.shared.playlist(named: name) else {
                return ack(50, command, "No such playlist")
            }
            if command == "listplaylist" {
                return lines(playlist.songs.map { "file: \($0.fileURL?.path ?? $0.title)" })
            }
            return lines(playlist.songs.flatMap { songInfoLines($0) })
        case "load":
            guard let name = args.first else { return ack(2, command, "wrong number of arguments") }
            guard let playlist = Library.shared.playlist(named: name) else {
                return ack(50, command, "No such playlist")
            }
            var songs = playlist.songs
            if args.count > 1 {
                guard let range = parseRange(args[1]),
                      range.lowerBound >= 0,
                      range.upperBound < songs.count else {
                    return ack(2, command, "Bad song index")
                }
                songs = Array(songs[range])
            }
            if !songs.isEmpty {
                PlayerState.shared.appendToQueue(songs)
                bumpPlaylist()
            }
            return ok()
        case "save":
            guard let name = args.first, !name.isEmpty else {
                return ack(2, command, "wrong number of arguments")
            }
            if name.caseInsensitiveCompare(Library.starredPlaylistName) == .orderedSame {
                return ack(4, command, "Playlist cannot be overwritten")
            }
            let mode = args.count > 1 ? args[1].lowercased() : ""
            guard mode.isEmpty || mode == "create" || mode == "append" || mode == "replace" else {
                return ack(2, command, "Bad save mode")
            }
            let existing = Library.shared.playlist(named: name)
            if existing != nil {
                if mode == "create" {
                    return ack(56, command, "Playlist already exists")
                }
                if mode == "append", let existing {
                    Library.shared.addToPlaylist(existing.id, songs: PlayerState.shared.queue)
                    bumpStoredPlaylist()
                    return ok()
                }
            } else if mode == "append" || mode == "replace" {
                return ack(50, command, "No such playlist")
            }
            Library.shared.createOrReplacePlaylist(named: name, songs: PlayerState.shared.queue)
            bumpStoredPlaylist()
            return ok()
        case "rm":
            guard let name = args.first else { return ack(2, command, "wrong number of arguments") }
            guard let playlist = Library.shared.playlist(named: name) else {
                return ack(50, command, "No such playlist")
            }
            if playlist.id == Library.starredPlaylistID {
                return ack(4, command, "Playlist cannot be removed")
            }
            Library.shared.deletePlaylist(playlist.id)
            bumpStoredPlaylist()
            return ok()
        case "playlistadd":
            guard args.count >= 2 else { return ack(2, command, "wrong number of arguments") }
            guard let playlist = Library.shared.playlist(named: args[0]) else {
                return ack(50, command, "No such playlist")
            }
            let songs = librarySongs(forPath: args[1])
            guard !songs.isEmpty else { return ack(50, command, "No such song or directory") }
            if playlist.id == Library.starredPlaylistID {
                Library.shared.setStarred(songs.map(\.id), starred: true)
                bumpStoredPlaylist()
                return ok()
            }
            if args.count > 2 {
                guard let position = Int(args[2]), position >= 0,
                      position <= playlist.songs.count else {
                    return ack(2, command, "Bad song index")
                }
                Library.shared.insertIntoPlaylist(playlist.id, songs: songs, at: position)
            } else {
                Library.shared.addToPlaylist(playlist.id, songs: songs)
            }
            bumpStoredPlaylist()
            return ok()
        case "playlistdelete":
            guard args.count >= 2 else { return ack(2, command, "wrong number of arguments") }
            guard let playlist = Library.shared.playlist(named: args[0]) else {
                return ack(50, command, "No such playlist")
            }
            guard let range = parseRange(args[1]),
                  range.lowerBound >= 0,
                  range.upperBound < playlist.songs.count else {
                return ack(2, command, "Bad song index")
            }
            if playlist.id == Library.starredPlaylistID {
                Library.shared.setStarred(Array(playlist.songs[range]).map(\.id), starred: false)
                bumpStoredPlaylist()
                return ok()
            }
            Library.shared.removeFromPlaylist(playlist.id, at: IndexSet(integersIn: range))
            bumpStoredPlaylist()
            return ok()
        case "playlistmove":
            guard args.count >= 3,
                  let from = Int(args[1]),
                  let to = Int(args[2]) else {
                return ack(2, command, "wrong number of arguments")
            }
            guard let playlist = Library.shared.playlist(named: args[0]) else {
                return ack(50, command, "No such playlist")
            }
            if playlist.id == Library.starredPlaylistID {
                return ack(4, command, "Playlist order is fixed")
            }
            guard playlist.songs.indices.contains(from),
                  to >= 0,
                  to < playlist.songs.count else {
                return ack(2, command, "Bad song index")
            }
            Library.shared.moveInPlaylist(playlist.id, from: from, to: to)
            bumpStoredPlaylist()
            return ok()
        case "playlistclear":
            guard let name = args.first else { return ack(2, command, "wrong number of arguments") }
            guard let playlist = Library.shared.playlist(named: name) else {
                return ack(50, command, "No such playlist")
            }
            if playlist.id == Library.starredPlaylistID {
                Library.shared.setStarred(playlist.songs.map(\.id), starred: false)
                bumpStoredPlaylist()
                return ok()
            }
            Library.shared.clearPlaylist(playlist.id)
            bumpStoredPlaylist()
            return ok()
        case "rename":
            guard args.count >= 2 else { return ack(2, command, "wrong number of arguments") }
            guard let playlist = Library.shared.playlist(named: args[0]) else {
                return ack(50, command, "No such playlist")
            }
            if playlist.id == Library.starredPlaylistID {
                return ack(4, command, "Playlist cannot be renamed")
            }
            if let existing = Library.shared.playlist(named: args[1]), existing.id != playlist.id {
                return ack(56, command, "Playlist already exists")
            }
            Library.shared.renamePlaylist(playlist.id, to: args[1])
            bumpStoredPlaylist()
            return ok()
        case "channels":
            return ok()
        case "subscribe", "unsubscribe", "sendmessage", "readmessages":
            return ok()
        case "mount", "unmount", "listmounts":
            return ok()
        case "partition":
            return ok()

        default:
            return ack(5, command, "unknown command")
        }
    }

    // MARK: Status and tags

    private var commandsList: [String] {
        ["status", "stats", "currentsong", "playlistinfo", "playlistid", "plchanges", "plchangesposid",
         "add", "addid", "clear", "delete", "deleteid", "move", "moveid", "shuffle",
         "play", "playid", "pause", "stop", "next", "previous", "seek", "seekid", "seekcur",
         "getvol", "setvol", "volume", "repeat", "random", "single", "consume", "toggle",
         "update", "rescan", "listall", "listallinfo", "lsinfo", "find", "search", "findadd", "searchadd",
         "list", "count", "playlistfind", "albumart", "readpicture", "binarylimit",
         "idle", "noidle", "password", "ping", "close",
         "commands", "notcommands", "tagtypes", "urlhandlers", "decoders", "outputs",
         "enableoutput", "disableoutput", "toggleoutput",
         "replay_gain_status", "listplaylists", "listplaylist", "listplaylistinfo",
         "load", "save", "rm", "playlistadd", "playlistdelete", "playlistmove",
         "playlistclear", "rename", "channels", "subscribe",
         "unsubscribe", "sendmessage", "readmessages"]
    }

    /// Derive the MPD state from the live player instead of keeping a local
    /// flag. The old flag was reset to "stopped" when the MPD server restarted,
    /// which made a running player appear stopped until another MPD command.
    private enum PlaybackState: String {
        case stop
        case play
        case pause
    }

    private var playbackState: PlaybackState {
        let player = PlayerState.shared
        guard player.currentSong != nil else { return .stop }
        if player.isPlaying { return .play }
        if player.isDecodingAudio || player.elapsed > 0 { return .pause }
        return .stop
    }

    private var reportedVolume: Int {
        let player = PlayerState.shared
        let value = player.isVolumeLocked
            ? (SystemVolume.current(deviceID: AudioDevices.shared.effectiveDeviceID) ?? 1)
            : player.volume
        return Int((min(max(value, 0), 1) * 100).rounded())
    }

    private func outputEnabled(_ id: Int, in devices: [AudioOutputDevice]) -> Bool {
        guard devices.indices.contains(id) else { return false }
        let selected = AudioDevices.shared.selectedUID
        let device = devices[id]
        return selected == device.uid || (selected == nil && device.isSystemDefault)
    }

    private func outputLines() -> [String] {
        let devices = AudioDevices.shared.devices
        var lines: [String] = []
        for (index, device) in devices.enumerated() {
            let name = device.name
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            lines.append("outputid: \(index)")
            lines.append("outputname: \(name)")
            lines.append("plugin: coreaudio")
            lines.append("outputenabled: \(outputEnabled(index, in: devices) ? 1 : 0)")
        }
        return lines
    }

    private func statusLines() -> [String] {
        let player = PlayerState.shared
        let state = playbackState.rawValue
        let duration = player.duration > 0 ? player.duration : (player.currentSong?.duration ?? 0)
        let singleValue: Int
        if player.repeatMode == .one {
            singleValue = 1
        } else if player.repeatMode == .all {
            singleValue = 0
        } else {
            singleValue = singleMode ? 1 : 0
        }
        var lines = [
            "volume: \(reportedVolume)",
            "repeat: \(player.repeatMode != .off ? 1 : 0)",
            "random: \(player.isShuffleOn ? 1 : 0)",
            "single: \(singleValue)",
            "consume: \(consumeMode ? 1 : 0)",
            "playlist: \(playlistVersion)",
            "playlistlength: \(player.queue.count)",
            "mixrampdb: 0.000000",
            "state: \(state)",
            "audio: 44100:16:2",
            "bitrate: 0",
            "elapsed: \(String(format: "%.3f", player.elapsed))",
            "duration: \(String(format: "%.3f", duration))",
            "time: \(Int(player.elapsed)):\(Int(duration))",
        ]
        if let index = player.currentIndex, player.queue.indices.contains(index) {
            lines.append("song: \(index)")
            lines.append("songid: \(index + 1)")
            if index + 1 < player.queue.count {
                lines.append("nextsong: \(index + 1)")
                lines.append("nextsongid: \(index + 2)")
            }
        }
        if Library.shared.isScanning {
            lines.append("updating_db: 1")
        }
        return lines
    }

    private func statsLines() -> [String] {
        let library = Library.shared
        let songs = library.allSongs
        return [
            "uptime: \(Int(Date().timeIntervalSince(startedAt)))",
            "playtime: 0",
            "artists: \(Set(songs.map(\.artist)).count)",
            "albums: \(library.albums.count)",
            "songs: \(songs.count)",
            "db_playtime: \(Int(songs.reduce(0) { $0 + $1.duration }.rounded()))",
            "db_update: \(Int(Date().timeIntervalSince1970))",
        ]
    }

    private func currentSongLines() -> [String] {
        let player = PlayerState.shared
        guard let song = player.currentSong, let index = player.currentIndex else { return [] }
        return playlistSongLines(song, position: index)
    }

    private func playlistLines(range: ClosedRange<Int>?) -> [String] {
        let queue = PlayerState.shared.queue
        let indices: [Int]
        if let range {
            indices = range.filter { queue.indices.contains($0) }
        } else {
            indices = Array(queue.indices)
        }
        var lines: [String] = []
        for index in indices {
            lines.append(contentsOf: playlistSongLines(queue[index], position: index))
        }
        return lines
    }

    private func playlistLines(ids: [Int]) -> [String] {
        let queue = PlayerState.shared.queue
        var lines: [String] = []
        for position in ids where queue.indices.contains(position) {
            lines.append(contentsOf: playlistSongLines(queue[position], position: position))
        }
        return lines
    }

    private func queueChangesPosIDLines() -> [String] {
        PlayerState.shared.queue.indices.flatMap { index in
            ["cpos: \(index)", "Id: \(index + 1)"]
        }
    }

    private func playlistSongLines(_ song: Song, position: Int) -> [String] {
        songInfoLines(song) + [
            "Pos: \(position)",
            "Id: \(position + 1)",
        ]
    }

    private func songInfoLines(_ song: Song) -> [String] {
        var lines = ["file: \(song.fileURL?.path ?? song.title)"]
        if !song.title.isEmpty { lines.append("Title: \(song.title)") }
        if !song.artist.isEmpty { lines.append("Artist: \(song.artist)") }
        if !song.albumArtist.isEmpty { lines.append("AlbumArtist: \(song.albumArtist)") }
        if !song.album.isEmpty { lines.append("Album: \(song.album)") }
        if !song.genre.isEmpty { lines.append("Genre: \(song.genre)") }
        if !song.year.isEmpty { lines.append("Date: \(song.year)") }
        // MPD's Track/Disc tags are decimal numbers. Some remote controllers
        // parse them strictly as integers, so do not append "/total" here.
        if song.trackNumber > 0 {
            lines.append("Track: \(song.trackNumber)")
        }
        if song.discNumber > 0 {
            lines.append("Disc: \(song.discNumber)")
        }
        if !song.comments.isEmpty { lines.append("Comment: \(song.comments)") }
        if song.dateAdded > 0 {
            // Tracks has no separate file-mtime value in Song; for MPD
            // compatibility this mirrors date_added.
            lines.append("Last-Modified: \(addedString(for: song))")
        }
        lines.append("added: \(addedString(for: song))")
        lines.append("Time: \(Int(song.duration.rounded()))")
        lines.append("duration: \(String(format: "%.3f", song.duration))")
        return lines
    }

    private func lsinfoLines(directory: String) -> [String] {
        let songs = librarySongs()
        if directory.isEmpty || directory == "/" {
            var values = songs.map { "file: \($0.fileURL?.path ?? $0.title)" }
            // MPD clients (including mpc lsplaylists) discover stored
            // playlists through lsinfo at the virtual root.
            values.append(contentsOf: mpdPlaylists.map { "playlist: \($0.name)" })
            return values
        }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return songs
            .filter { ($0.fileURL?.path ?? "").hasPrefix(prefix) }
            .flatMap { songInfoLines($0) }
    }

    // MARK: Library filtering

    private func librarySongs() -> [Song] {
        Library.shared.allSongs
    }

    private func librarySongs(forPath path: String) -> [Song] {
        let songs = librarySongs()
        let exact = songs.filter { $0.fileURL?.path == path }
        if !exact.isEmpty { return exact }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return songs.filter { ($0.fileURL?.path ?? "").hasPrefix(prefix) }
    }

    private func filteredSongs(filters: [(String, String)], substring: Bool) -> [Song] {
        guard !filters.isEmpty else { return librarySongs() }
        return librarySongs().filter { song in
            filters.allSatisfy { tag, value in
                let candidate = songValue(song, tag: tag) ?? ""
                if tag.lowercased() == "any" {
                    let haystacks = [song.title, song.artist, song.albumArtist, song.album, song.genre, song.comments, song.fileURL?.path ?? ""]
                    return haystacks.contains { substring ? $0.localizedCaseInsensitiveContains(value) : $0.localizedCaseInsensitiveCompare(value) == .orderedSame }
                }
                return substring
                    ? candidate.localizedCaseInsensitiveContains(value)
                    : candidate.localizedCaseInsensitiveCompare(value) == .orderedSame
            }
        }
    }

    private func songValue(_ song: Song, tag: String) -> String? {
        switch tag.lowercased() {
        case "file", "path": return song.fileURL?.path
        case "title": return song.title
        case "artist": return song.artist
        case "albumartist", "album_artist": return song.albumArtist
        case "album": return song.album
        case "genre": return song.genre
        case "date", "year": return song.year.isEmpty ? nil : song.year
        case "track": return song.trackNumber > 0 ? String(song.trackNumber) : nil
        case "disc": return song.discNumber > 0 ? String(song.discNumber) : nil
        case "comment": return song.comments
        default: return nil
        }
    }

    private func canonicalTag(_ tag: String) -> String {
        switch tag.lowercased() {
        case "albumartist": return "AlbumArtist"
        case "date": return "Date"
        default:
            return tag.prefix(1).uppercased() + tag.dropFirst().lowercased()
        }
    }

    private func pairs(_ args: [String]) -> [(String, String)] {
        guard args.count >= 2 else { return [] }
        var result: [(String, String)] = []
        var index = 0
        while index + 1 < args.count {
            let tag = args[index].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            if tag.lowercased() == "and" {
                index += 1
                continue
            }
            if tag == "==" {
                index += 1
                continue
            }
            var value = args[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            if value == "==", index + 2 < args.count {
                value = args[index + 2].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                index += 3
            } else {
                index += 2
            }
            result.append((tag, value))
        }
        return result
    }

    private func parseFilters(raw: String) -> [(String, String)] {
        if raw.contains("==") {
            let pattern = #"([A-Za-z_]+)\s*==\s*(?:"([^"]*)"|([^)\s]+))"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
                let matches = regex.matches(in: raw, range: range)
                var result: [(String, String)] = []
                for match in matches {
                    let tagRange = Range(match.range(at: 1), in: raw)
                    let quotedRange = Range(match.range(at: 2), in: raw)
                    let bareRange = Range(match.range(at: 3), in: raw)
                    if let tagRange, let valueRange = quotedRange ?? bareRange {
                        result.append((String(raw[tagRange]), String(raw[valueRange])))
                    }
                }
                if !result.isEmpty { return result }
            }
        }
        return pairs(tokenize(raw))
    }

    private func albumID(forURI uri: String) -> UUID? {
        if let cached = albumIDCache[uri] { return cached }
        let songs = librarySongs()
        let exact = songs.first { $0.fileURL?.path == uri }
        let prefixed = songs.first { ($0.fileURL?.path ?? "").hasPrefix(uri.hasSuffix("/") ? uri : uri + "/") }
        let suffixed = songs.first { ($0.fileURL?.path ?? "").hasSuffix(uri) }
        guard let song = exact ?? prefixed ?? suffixed else { return nil }
        guard let albumID = Library.shared.albums.first(where: { album in
            album.songs.contains { $0.id == song.id }
        })?.id else { return nil }
        albumIDCache[uri] = albumID
        return albumID
    }

    private func artworkResponse(uri: String,
                                 offset: Int,
                                 session: MPDClientSession?) -> MPDResponse {
        guard let albumID = albumID(forURI: uri),
              let data = ArtworkCache.shared.cachedData(forAlbumID: albumID),
              !data.isEmpty else {
            return ok()
        }
        let total = data.count
        let safeOffset = min(max(offset, 0), total)
        guard safeOffset < total else {
            return lines(["size: \(total)", "type: image/jpeg"])
        }
        let limit = max(1, session?.binaryLimit ?? 262_144)
        let end = min(safeOffset + limit, total)
        let chunk = data.subdata(in: safeOffset..<end)
        return MPDResponse(
            text: "size: \(total)\ntype: image/jpeg\nbinary: \(chunk.count)\n",
            binary: chunk
        )
    }

    private func parseRange(_ raw: String?) -> ClosedRange<Int>? {
        guard let raw else { return nil }
        if raw.contains(":") {
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let start = Int(parts[0]), let end = Int(parts[1]),
                  end > start else { return nil }
            return start...(end - 1)
        }
        guard let value = Int(raw) else { return nil }
        return value...value
    }

    private func parseTime(_ raw: String) -> TimeInterval? {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        if cleaned.contains(":") {
            let parts = cleaned.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            let value = parts[0] * 60 + parts[1]
            return raw.hasPrefix("-") ? -value : value
        }
        guard let value = Double(cleaned) else { return nil }
        return raw.hasPrefix("-") ? -value : value
    }

    private func bumpPlaylist() {
        playlistVersion &+= 1
        broadcastIdle("playlist")
        broadcastIdle("player")
    }

    private func bumpStoredPlaylist() {
        broadcastIdle("stored_playlist")
    }

    /// Stored playlists plus the virtual Stared playlist. A user-created
    /// playlist with the same name is hidden in favour of the built-in one.
    private var mpdPlaylists: [Playlist] {
        var values = Library.shared.playlists.filter {
            $0.name.caseInsensitiveCompare(Library.starredPlaylistName) != .orderedSame
        }
        values.append(Library.shared.starredPlaylist)
        return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private func playlistModifiedString(_ playlist: Playlist) -> String {
        let timestamp = playlist.dateModified > 0 ? playlist.dateModified : Date().timeIntervalSince1970
        return Self.iso8601Formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    /// MPD 0.24's `added` field. Older clients commonly use `Last-Modified`
    /// for the same purpose, so both are emitted from Tracks' date_added.
    private func addedString(for song: Song) -> String {
        guard song.dateAdded > 0 else { return "-1" }
        return Self.iso8601Formatter.string(from: Date(timeIntervalSince1970: song.dateAdded))
    }

    private func ok() -> MPDResponse { MPDResponse(text: "OK\n") }

    private func lines(_ values: [String]) -> MPDResponse {
        MPDResponse(text: values.map { "\($0)\n" }.joined() + "OK\n")
    }

    private func ack(_ code: Int, _ command: String, _ message: String) -> MPDResponse {
        MPDResponse(text: "ACK [\(code)@0] {\(command)} \(message)\n")
    }

    private func tokenize(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var escaping = false
        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\", inQuotes {
                escaping = true
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if character == " ", !inQuotes {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

// MARK: - TCP listener

final class MPDListener: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private weak var server: MPDServer?
    private var source: DispatchSourceRead?
    let displayAddress: String

    init?(host: String, port: UInt16, server: MPDServer) {
        self.server = server
        self.displayAddress = host
        self.queue = DispatchQueue(label: "tracks.mpd.listener.\(host)")

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_PASSIVE
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }

        var bound: Int32 = -1
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let address = cursor {
            let candidate = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            if candidate >= 0 {
                var one: Int32 = 1
                setsockopt(candidate, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                if address.pointee.ai_family == AF_INET6 {
                    var v6Only: Int32 = 1
                    setsockopt(candidate, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
                }
                if bind(candidate, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0,
                   listen(candidate, 16) == 0 {
                    bound = candidate
                    break
                }
                close(candidate)
            }
            cursor = address.pointee.ai_next
        }
        guard bound >= 0 else { return nil }
        fd = bound
        start()
    }

    private func start() {
        let handle = fcntl(fd, F_GETFL, 0)
        if handle >= 0 { _ = fcntl(fd, F_SETFL, handle | O_NONBLOCK) }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.resume()
        self.source = source
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.source?.cancel()
            self.source = nil
        }
    }

    private func acceptConnections() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(client, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(client, F_SETFL, flags | O_NONBLOCK) }
            let session = MPDClientSession(fd: client, server: server)
            if let server {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { server.addSession(session) }
                }
            }
            session.start()
        }
    }

    deinit {
        source?.cancel()
        close(fd)
    }
}

// MARK: - Client session

final class MPDClientSession: @unchecked Sendable {
    private let fd: Int32
    private weak var server: MPDServer?
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var authenticated = false
    private var isClosed = false
    private var isIdle = false
    private var pendingChanges = Set<String>()
    private var listBuffer: [String]?
    private var listOK = false
    var binaryLimit = 262_144

    init(fd: Int32, server: MPDServer?) {
        self.fd = fd
        self.server = server
        self.queue = DispatchQueue(label: "tracks.mpd.client.\(fd)")
    }

    func start() {
        send("OK MPD 0.24.0\n")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        self.source = source
    }

    func close() {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.isClosed = true
            self.source?.cancel()
            self.source = nil
            Darwin.close(self.fd)
            if let server = self.server {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { server.removeSession(self) }
                }
            }
        }
    }

    func sendChanged(_ subsystem: String) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            if self.isIdle {
                self.isIdle = false
                self.send("changed: \(subsystem)\nOK\n")
            } else {
                self.pendingChanges.insert(subsystem)
            }
        }
    }

    private func sendPendingChanges() {
        guard !pendingChanges.isEmpty else { return }
        let changes = pendingChanges
        pendingChanges.removeAll()
        isIdle = false
        let text = changes.map { "changed: \($0)\n" }.joined() + "OK\n"
        send(text)
    }

    private func readAvailable() {
        guard !isClosed else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = recv(fd, &bytes, bytes.count, 0)
        if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            close()
            return
        }
        if count == 0 {
            close()
            return
        }
        buffer.append(contentsOf: bytes[0..<count])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            handleLine(line)
            if isClosed { return }
        }
    }

    private func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let command = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""

        if command == "command_list_begin" || command == "command_list_ok_begin" {
            listBuffer = []
            listOK = command == "command_list_ok_begin"
            return
        }
        if command == "command_list_end" {
            let commands = listBuffer ?? []
            listBuffer = nil
            executeList(commands)
            return
        }
        if listBuffer != nil {
            listBuffer?.append(trimmed)
            return
        }

        let response = executeOnMain(trimmed)
        if let auth = response.authenticated { authenticated = auth }
        if response.idle {
            isIdle = true
            sendPendingChanges()
            return
        }
        isIdle = false
        sendResponse(response)
        if response.close { close() }
    }

    private func executeList(_ commands: [String]) {
        var output = ""
        for command in commands {
            let response = executeOnMain(command)
            if let auth = response.authenticated { authenticated = auth }
            if response.text.hasPrefix("ACK") {
                output += response.text
                send(output)
                return
            }
            var text = response.text
            if text.hasSuffix("OK\n") { text.removeLast(3) }
            output += text
            if listOK { output += "list_OK\n" }
        }
        output += "OK\n"
        send(output)
    }

    private func executeOnMain(_ line: String) -> MPDResponse {
        guard let server else { return MPDResponse(text: "OK\n") }
        var response = MPDResponse(text: "OK\n")
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                response = server.execute(line: line, authenticated: authenticated, session: self)
            }
        }
        return response
    }

    private func sendResponse(_ response: MPDResponse) {
        guard !response.text.isEmpty || response.binary != nil else { return }
        send(response.text)
        if let binary = response.binary {
            sendData(binary)
            send("\nOK\n")
        }
    }

    private func send(_ text: String) {
        guard !isClosed, !text.isEmpty else { return }
        sendData(Data(text.utf8))
    }

    private func sendData(_ data: Data) {
        guard !isClosed, !data.isEmpty else { return }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if Darwin.poll(&descriptor, 1, 1000) >= 0 { continue }
            }
            close()
            return
        }
    }
}
