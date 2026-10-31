import SwiftUI

enum RekeyLogLevel {
    case info
    case error
}

struct RekeyLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let level: RekeyLogLevel
    let message: String
}

struct RekeyProgressReporter {
    let info: @MainActor (String) -> Void
    let error: @MainActor (String) -> Void
    let phase: @MainActor (String, Double?) -> Void

    init(info: @escaping @MainActor (String) -> Void = { _ in },
         error: @escaping @MainActor (String) -> Void = { _ in },
         phase: @escaping @MainActor (String, Double?) -> Void = { _, _ in }) {
        self.info = info
        self.error = error
        self.phase = phase
    }
}

@MainActor
final class RekeyProgressCenter: ObservableObject {
    static let shared = RekeyProgressCenter()

    @Published private(set) var isRunning = false
    @Published private(set) var isFinished = false
    @Published private(set) var hasError = false
    @Published private(set) var phase = ""
    @Published private(set) var progress: Double?
    @Published private(set) var entries: [RekeyLogEntry] = []

    private init() {}

    var reporter: RekeyProgressReporter {
        RekeyProgressReporter(
            info: { [weak self] message in self?.log(message) },
            error: { [weak self] message in self?.log(message, level: .error) },
            phase: { [weak self] phase, progress in
                self?.setPhase(phase, progress: progress)
            }
        )
    }

    func begin() {
        isRunning = true
        isFinished = false
        hasError = false
        phase = "Preparing"
        progress = nil
        entries = []
        log("ReKey started")
    }

    func log(_ message: String, level: RekeyLogLevel = .info) {
        entries.append(RekeyLogEntry(level: level, message: message))
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }
    }

    func setPhase(_ phase: String, progress: Double? = nil) {
        self.phase = phase
        self.progress = progress
    }

    func finish(summary: String) {
        phase = "Complete"
        progress = 1
        isRunning = false
        isFinished = true
        hasError = false
        log(summary)
    }

    func fail(_ message: String) {
        phase = "Failed"
        progress = nil
        isRunning = false
        isFinished = true
        hasError = true
        log(message, level: .error)
    }
}

struct RekeyProgressView: View {
    @ObservedObject private var progress = RekeyProgressCenter.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.highlight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ReKey Database")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.primaryText)
                        Text(progress.phase.isEmpty ? "Idle" : progress.phase)
                            .font(.system(size: 12))
                            .foregroundColor(progress.hasError ? .red : Theme.secondaryText)
                    }
                    Spacer()
                    if progress.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let value = progress.progress {
                    ProgressView(value: value)
                        .progressViewStyle(.linear)
                } else if progress.isRunning {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .padding(18)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(progress.entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.secondaryText)
                                    .frame(width: 62, alignment: .leading)
                                Text(entry.level == .error ? "ERROR" : "INFO")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(entry.level == .error ? .red : Theme.secondaryText)
                                    .frame(width: 38, alignment: .leading)
                                Text(entry.message)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(entry.level == .error ? .red : Theme.primaryText)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: progress.entries.count) { _, _ in
                    if let last = progress.entries.last {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(progress.hasError ? .red : Theme.secondaryText)
                Spacer()
                Button("Close") { dismissWindow(id: "rekey-progress") }
                    .keyboardShortcut(.cancelAction)
                    .disabled(progress.isRunning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.toolbarBottom)
        }
        .frame(width: 680, height: 460)
        .background(Theme.contentBackground)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var statusText: String {
        if progress.hasError {
            return "ReKey failed. Review the error above."
        }
        if progress.isFinished {
            return "ReKey complete. Tracks will restart automatically."
        }
        if progress.isRunning {
            return "ReKey in progress. Do not quit Tracks."
        }
        return "No ReKey is running. Start it from Settings > Library > Danger Zone."
    }
}
