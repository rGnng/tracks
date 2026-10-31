import SwiftUI
import AppKit

@MainActor
final class InfoCenter: ObservableObject {
    static let shared = InfoCenter()

    enum Target: Equatable {
        case album(UUID)
        case song(UUID)
    }

    @Published var target: Target?
}

/// Borderless AppKit text field used by the Details tab. Unlike a disabled
/// SwiftUI TextField, a non-editable field remains selectable so values can be
/// copied from read-only libraries.
private struct GetInfoTextField: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let prompt: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SelectableTextField {
        let field = SelectableTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.isSelectable = true
        field.isEditable = isEditable
        field.focusRingType = .default
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.stringValue = text
        applyPrompt(to: field)
        return field
    }

    func updateNSView(_ field: SelectableTextField, context: Context) {
        context.coordinator.parent = self
        if text != context.coordinator.lastText {
            field.stringValue = text
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = text
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
            context.coordinator.lastText = text
        } else if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        field.isEditable = isEditable
        field.isSelectable = true
        applyPrompt(to: field)
    }

    private func applyPrompt(to field: NSTextField) {
        guard !prompt.isEmpty else {
            field.placeholderAttributedString = nil
            return
        }
        let font = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        field.placeholderAttributedString = NSAttributedString(
            string: prompt,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: GetInfoTextField
        var lastText: String

        init(_ parent: GetInfoTextField) {
            self.parent = parent
            self.lastText = parent.text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            lastText = field.stringValue
            parent.text = field.stringValue
        }
    }
}

private final class SelectableTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // A borderless, non-editable NSTextField only starts a selection when
        // the click lands on the text itself. Make the whole box interactive:
        // clicking empty space focuses the field and selects its value.
        guard !isEditable else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let textRect = cell?.titleRect(forBounds: bounds) ?? bounds
        if textRect.contains(point) {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        if let editor = currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: 0, length: (stringValue as NSString).length))
        }
    }
}

/// Get Info window with the three tabs used by the player: Details, Artwork, File.
struct GetInfoView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case details = "Details"
        case artwork = "Artwork"
        case file = "File"
        var id: String { rawValue }
    }

    private enum DetailField: Hashable {
        case name, artist, albumArtist, album, genre, year
        case track, trackTotal, disc, discTotal, comments
    }

    @ObservedObject private var info = InfoCenter.shared
    @ObservedObject private var library = Library.shared
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var tab: Tab = .details

    @State private var title = ""
    @State private var artist = ""
    @State private var albumArtist = ""
    @State private var albumTitle = ""
    @State private var genre = ""
    @State private var year = ""
    @State private var track = ""
    @State private var trackTotal = ""
    @State private var disc = ""
    @State private var discTotal = ""
    @State private var comments = ""
    @State private var mixedFields: Set<DetailField> = []

    @State private var headerTitle = ""
    @State private var headerArtist = ""
    @State private var headerAlbum = ""

    @State private var artworkData: Data?
    @State private var artworkPreview: NSImage?
    @State private var duration: TimeInterval = 0
    @State private var plays = 0
    @State private var targetAlbumID: UUID?
    @State private var artworkRequestID = UUID()

    @State private var locationPath = ""
    @State private var revealTarget: URL?
    @State private var revealIsFolder = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            AccentSegmentedControl(
                segments: Tab.allCases.map {
                    AccentSegment(value: $0, title: $0.rawValue)
                },
                selection: $tab
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch tab {
                case .details: detailsTab
                case .artwork: artworkTab
                case .file: fileTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.toolbarBottom)
        }
        .frame(minWidth: 520, idealWidth: 540, maxWidth: .infinity,
               minHeight: 560, idealHeight: 620, maxHeight: .infinity)
        .background(Theme.contentBackground)
        .onAppear(perform: load)
        .onChange(of: info.target) { _, _ in load() }
        .task(id: artworkRequestID) {
            guard let id = targetAlbumID else { return }
            let data = await ArtworkCache.shared.fullData(albumID: id)
            guard !Task.isCancelled, targetAlbumID == id else { return }
            artworkData = data
            artworkPreview = data.flatMap(NSImage.init(data:))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let artworkPreview {
                    Image(nsImage: artworkPreview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color(white: 0.60))
                }
            }
            .frame(width: 64, height: 64)
            .background(Theme.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle.isEmpty ? " " : headerTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
                    .lineLimit(1)
                Text(headerArtist)
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.primaryText)
                    .lineLimit(1)
                Text(headerAlbum)
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: Details

    private var detailsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                infoRow("Name") { detailTextField($title, field: .name) }
                infoRow("Artist") { detailTextField($artist, field: .artist) }
                infoRow("Album Artist") { detailTextField($albumArtist, field: .albumArtist) }
                infoRow("Album") { detailTextField($albumTitle, field: .album) }
                infoRow("Genre") { detailTextField($genre, field: .genre) }

                infoRow("Year") {
                    detailTextField($year, field: .year)
                        .frame(width: 80)
                }

                infoRow("Track") {
                    HStack(spacing: 6) {
                        detailTextField($track, field: .track)
                            .frame(width: 52)
                        Text("of")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.secondaryText)
                        detailTextField($trackTotal, field: .trackTotal)
                            .frame(width: 52)
                    }
                }

                infoRow("Disc") {
                    HStack(spacing: 6) {
                        detailTextField($disc, field: .disc)
                            .frame(width: 52)
                        Text("of")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.secondaryText)
                        detailTextField($discTotal, field: .discTotal)
                            .frame(width: 52)
                    }
                }

                infoRow("Comments") {
                    detailTextField($comments, field: .comments)
                }

                infoRow("Play count") {
                    Text("\(plays)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryText)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private func detailTextField(_ text: Binding<String>, field: DetailField) -> some View {
        let prompt = mixedFields.contains(field) ? "Mixed" : ""
        return GetInfoTextField(text: text, isEditable: false, prompt: prompt)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .padding(.horizontal, 6)
            .background(Theme.controlBackground)
            .overlay(
                Rectangle()
                    .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
    }

    private func infoRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.secondaryText)
                .frame(width: 84, alignment: .trailing)
            content()
        }
    }

    // MARK: Artwork

    private var artworkTab: some View {
        VStack {
            Spacer(minLength: 0)
            Group {
                if let artworkPreview {
                    Image(nsImage: artworkPreview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color(white: 0.60))
                }
            }
            .frame(width: 300, height: 300)
            .background(Theme.controlBackground)
            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: File

    private var fileTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                fileRow("Kind", "Tracks Audio File")
                fileRow("Duration", formatDuration(duration))
                fileRow("Track", trackSummary)
                fileRow("Disc", discSummary)
                fileRow("Play count", "\(plays)")
                fileRow("Artist", displayed(artist, field: .artist))
                fileRow("Album Artist", displayed(albumArtist, field: .albumArtist))
                fileRow("Album", displayed(albumTitle, field: .album))
                fileRow("Genre", displayed(genre, field: .genre))
                locationRow
                    .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private var trackSummary: String {
        let number = mixedFields.contains(.track) && track.isEmpty ? "Mixed" : track
        let total = mixedFields.contains(.trackTotal) && trackTotal.isEmpty ? "Mixed" : trackTotal
        if number.isEmpty, total.isEmpty { return "—" }
        if total.isEmpty { return number }
        if number.isEmpty { return "of \(total)" }
        return "\(number) of \(total)"
    }

    private var discSummary: String {
        let number = mixedFields.contains(.disc) && disc.isEmpty ? "Mixed" : disc
        let total = mixedFields.contains(.discTotal) && discTotal.isEmpty ? "Mixed" : discTotal
        if number.isEmpty, total.isEmpty { return "—" }
        if total.isEmpty { return number }
        if number.isEmpty { return "of \(total)" }
        return "\(number) of \(total)"
    }

    private func displayed(_ value: String, field: DetailField) -> String {
        mixedFields.contains(field) && value.isEmpty ? "Mixed" : value
    }

    private var locationRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Location")
                .font(.system(size: 12))
                .foregroundColor(Theme.secondaryText)
                .frame(width: 84, alignment: .trailing)
            Text(locationPath.isEmpty ? "—" : locationPath)
                .font(.system(size: 12))
                .foregroundColor(Theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reveal in Finder") { revealLocation() }
                .fixedSize()
                .disabled(revealTarget == nil)
            Spacer(minLength: 0)
        }
    }

    private func fileRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.secondaryText)
                .frame(width: 84, alignment: .trailing)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(Theme.primaryText)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func revealLocation() {
        guard let revealTarget else { return }
        if revealIsFolder {
            NSWorkspace.shared.open(revealTarget)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([revealTarget])
        }
    }

    // MARK: Load / save

    private func load() {
        guard let target = info.target else { return }
        artworkData = nil
        artworkPreview = nil
        mixedFields = []
        locationPath = ""
        revealTarget = nil
        revealIsFolder = false

        switch target {
        case .album(let id):
            guard let album = library.album(withID: id) else { return }
            let songs = album.songs
            headerTitle = album.title
            headerArtist = album.artist
            headerAlbum = album.title

            title = uniform(.name, songs.map(\.title))
            artist = uniform(.artist, songs.map(\.artist))
            albumArtist = uniform(.albumArtist, songs.map(\.albumArtist))
            albumTitle = uniform(.album, songs.map(\.album))
            genre = uniform(.genre, songs.map(\.genre))
            year = uniform(.year, songs.map(\.year))
            track = uniform(.track, songs.map(\.trackNumberLabel))
            trackTotal = uniform(.trackTotal,
                                 songs.map { $0.trackTotal > 0 ? String($0.trackTotal) : "" })
            disc = uniform(.disc, songs.map { $0.discNumber > 0 ? String($0.discNumber) : "" })
            discTotal = uniform(.discTotal, songs.map { $0.discTotal > 0 ? String($0.discTotal) : "" })
            comments = uniform(.comments, songs.map(\.comments))

            plays = songs.reduce(0) { $0 + $1.plays }
            duration = songs.reduce(0) { $0 + $1.duration }
            targetAlbumID = album.id
            if let first = songs.first?.fileURL {
                let folder = first.deletingLastPathComponent()
                locationPath = folder.path
                revealTarget = folder
                revealIsFolder = true
            }
            artworkRequestID = UUID()

        case .song(let id):
            guard let result = library.song(withID: id) else { return }
            let song = result.song
            headerTitle = song.title
            headerArtist = song.artist
            headerAlbum = song.album

            title = song.title
            artist = song.artist
            albumArtist = song.albumArtist
            albumTitle = song.album
            genre = song.genre
            year = song.year
            track = song.trackNumberLabel
            trackTotal = song.trackTotal > 0 ? String(song.trackTotal) : ""
            disc = song.discNumber > 0 ? String(song.discNumber) : ""
            discTotal = song.discTotal > 0 ? String(song.discTotal) : ""
            comments = song.comments

            plays = song.plays
            duration = song.duration
            targetAlbumID = result.album.id
            locationPath = song.fileURL?.path ?? ""
            revealTarget = song.fileURL
            revealIsFolder = false
            artworkRequestID = UUID()
        }
    }

    private func uniform(_ field: DetailField, _ values: [String]) -> String {
        let unique = Set(values)
        guard unique.count == 1 else {
            mixedFields.insert(field)
            return ""
        }
        return unique.first ?? ""
    }

    private func close() {
        dismissWindow(id: "get-info")
    }
}
