import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Copies user-selected audio files into the Internal Library's `Music`
/// folder, organizing them by tag metadata:
///
///     Music/<Album Artist or Artist>/<Album>/<Track>.<Title>-<Artist>.<ext>
///
/// Source files are never modified. The library is rescanned after the copy
/// completes, so imported tracks flow through the normal metadata pipeline.
@MainActor
final class MediaImporter: ObservableObject {
    static let shared = MediaImporter()

    @Published private(set) var isImporting = false
    @Published private(set) var importCompleted = 0
    @Published private(set) var importTotal = 0
    @Published private(set) var importProgress: Double = 0

    private init() {}

    func chooseAndImport() {
        guard !isImporting else { return }
        NSApp.activate(ignoringOtherApps: true)

        guard let library = Library.shared.internalLibrary else {
            presentMissingInternalLibrary()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Import Media"
        panel.message = "Choose audio files or folders to import into the Internal Library."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        var types = LibraryScanner.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        types.append(.audio)
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        Task { await importMedia(urls, into: library) }
    }

    private func importMedia(_ urls: [URL], into library: MusicLibrary) async {
        isImporting = true
        importCompleted = 0
        importTotal = 0
        importProgress = 0

        let musicRoot = URL(fileURLWithPath: library.musicPath)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: musicRoot, withIntermediateDirectories: true)

        let files = await Task.detached(priority: .userInitiated) {
            Self.collectAudioFiles(from: urls, excluding: musicRoot.path)
        }.value

        guard !files.isEmpty else {
            isImporting = false
            presentAlert(
                title: "No Audio Files Found",
                message: "The selection did not contain any supported audio files.",
                style: .informational
            )
            return
        }

        importTotal = files.count
        var imported = 0
        var skipped: [String] = []
        var errors: [String] = []

        for (index, source) in files.enumerated() {
            defer {
                importCompleted = index + 1
                importProgress = Double(importCompleted) / Double(files.count)
            }

            guard let track = await readTrack(source) else {
                errors.append("\(source.lastPathComponent): unreadable audio")
                continue
            }

            var destination = LibraryOrganizer.destination(for: track,
                                                           source: source,
                                                           musicRoot: musicRoot)
            if let duplicate = duplicateReason(source: track, destination: destination) {
                skipped.append("\(source.lastPathComponent): \(duplicate)")
                continue
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = LibraryOrganizer.uniqueDestination(destination)
            }

            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: source, to: destination)
                }.value
                imported += 1
            } catch {
                errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        isImporting = false
        if imported > 0 {
            Library.shared.rescan(library)
        }
        presentImportSummary(imported: imported,
                             skipped: skipped,
                             errors: errors)
    }

    // MARK: Metadata

    private func readTrack(_ url: URL) async -> ScannedTrack? {
        if url.pathExtension.lowercased() == "flac" {
            return await Task.detached(priority: .userInitiated) {
                FLACMetadataReader.read(url: url)
            }.value
        }
        return await AVAssetMetadataReader.read(url: url)
    }

    // MARK: Naming

    private func duplicateReason(source: ScannedTrack, destination: URL) -> String? {
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
        guard let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              Int64(values.fileSize ?? 0) == source.fileSize else { return nil }
        let destinationMTime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        if source.mtime > 0, abs(destinationMTime - source.mtime) >= 1 {
            return nil
        }
        return "already imported"
    }

    // MARK: File collection

    private nonisolated static func collectAudioFiles(from urls: [URL],
                                                       excluding root: String) -> [URL] {
        let fileManager = FileManager.default
        let standardizedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        var result: [URL] = []
        var seen: Set<String> = []

        func add(_ url: URL) {
            guard LibraryScanner.supportedExtensions.contains(url.pathExtension.lowercased()) else { return }
            let canonical = URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
            let path = canonical.path
            guard !path.hasPrefix(standardizedRoot + "/") else { return }
            if seen.insert(path).inserted {
                result.append(canonical)
            }
        }

        for url in urls {
            let canonical = URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
            let isDirectory = (try? canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
                guard let enumerator = fileManager.enumerator(
                    at: canonical,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let fileURL as URL in enumerator {
                    let values = try? fileURL.resourceValues(forKeys: Set(keys))
                    guard values?.isRegularFile == true else { continue }
                    add(fileURL)
                }
            } else {
                add(canonical)
            }
        }

        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: Alerts

    private func presentMissingInternalLibrary() {
        let alert = NSAlert()
        alert.messageText = "No Internal Library"
        alert.informativeText = "Set up an Internal Library before importing media. Imported files are copied into its Music folder."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Set Up…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NotificationCenter.default.post(name: .openSetupWindow, object: nil)
        }
    }

    private func presentImportSummary(imported: Int,
                                      skipped: [String],
                                      errors: [String]) {
        var lines: [String] = []
        if imported > 0 {
            lines.append("Imported \(imported) file\(imported == 1 ? "" : "s") into the Internal Library.")
        } else {
            lines.append("No files were imported.")
        }

        func appendList(_ title: String, _ values: [String]) {
            guard !values.isEmpty else { return }
            lines.append("")
            lines.append(title)
            for value in values.prefix(6) {
                lines.append("• \(value)")
            }
            if values.count > 6 {
                lines.append("…and \(values.count - 6) more")
            }
        }

        appendList("Skipped:", skipped)
        appendList("Could not import:", errors)

        let style: NSAlert.Style = errors.isEmpty ? .informational : .warning
        let alert = NSAlert()
        alert.messageText = "Import Media"
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        // Show the summary as a sheet so the MainActor stays free to finish
        // the library scan started above.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func presentAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension Notification.Name {
    static let openSetupWindow = Notification.Name("audia.openSetupWindow")
}
