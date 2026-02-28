import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: MonitorLogLevel
    let message: String
}

@MainActor
final class OverseerViewModel: ObservableObject {
    @Published var configPath: String = defaultConfigPath
    @Published var configSummary: String = "Not loaded"
    @Published var isMonitoring = false
    @Published var verboseLogging = true
    @Published var serviceStatus: String = "Unknown"
    @Published var logs: [LogEntry] = []
    @Published var lastError: String?

    private var monitorTask: Task<Void, Never>?

    func loadConfigSummary() {
        do {
            let config = try loadConfig(from: configPath)
            let summary = "Rules: \(config.rules.count) | Poll: \(config.pollIntervalSeconds)s | Tree roots: \(config.onlyTreeRoots ? "yes" : "no")"
            configSummary = summary
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            configSummary = "Invalid config"
            appendLog(level: .warning, message: "config error: \(error.localizedDescription)")
        }
    }

    func chooseConfigFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.json]
        } else {
            panel.allowedFileTypes = ["json"]
        }
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            configPath = url.path
            loadConfigSummary()
        }
    }

    func openConfigInFinder() {
        let resolved = resolveAbsolutePath(configPath)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: resolved)])
    }

    func startMonitoring() {
        guard monitorTask == nil else {
            return
        }

        lastError = nil
        let path = configPath
        let verbose = verboseLogging

        isMonitoring = true
        appendLog(level: .info, message: "starting monitor with config \(path)")

        let appendLog: @Sendable (MonitorLogLevel, String) -> Void = { [weak self] level, message in
            Task { @MainActor in
                self?.appendLog(level: level, message: message)
            }
        }
        let reportError: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in
                self?.lastError = message
                self?.appendLog(level: .warning, message: "monitor stopped: \(message)")
            }
        }
        let finishMonitoring: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.isMonitoring = false
                self?.monitorTask = nil
            }
        }

        monitorTask = Task.detached(priority: .background) {
            do {
                let config = try loadConfig(from: path)
                let runtime = MonitorRuntime(
                    config: config,
                    verbose: verbose,
                    logHandler: { level, message in
                        appendLog(level, message)
                    }
                )
                try await runtime.run()
            } catch is CancellationError {
                appendLog(.info, "monitor cancelled")
            } catch {
                reportError(error.localizedDescription)
            }

            finishMonitoring()
        }
    }

    func stopMonitoring() {
        guard let monitorTask else {
            return
        }
        monitorTask.cancel()
        self.monitorTask = nil
        isMonitoring = false
        appendLog(level: .info, message: "monitor stopped")
    }

    func refreshServiceStatus() {
        performServiceAction(label: "status") { manager in
            try manager.status()
        }
    }

    func installService() {
        performServiceAction(label: "install") { manager in
            try manager.install(configPath: self.configPath)
            return nil
        }
    }

    func uninstallService() {
        performServiceAction(label: "uninstall") { manager in
            try manager.uninstall()
            return nil
        }
    }

    func startService() {
        performServiceAction(label: "start") { manager in
            try manager.start()
            return nil
        }
    }

    func stopService() {
        performServiceAction(label: "stop") { manager in
            try manager.stop()
            return nil
        }
    }

    func restartService() {
        performServiceAction(label: "restart") { manager in
            try manager.restart()
            return nil
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func performServiceAction(label: String, action: @escaping (ServiceManager) throws -> String?) {
        let verbose = verboseLogging
        let appendLog: @Sendable (MonitorLogLevel, String) -> Void = { [weak self] level, message in
            Task { @MainActor in
                self?.appendLog(level: level, message: message)
            }
        }
        let updateStatus: @Sendable (String?) -> Void = { [weak self] status in
            Task { @MainActor in
                if let status {
                    self?.serviceStatus = status
                }
            }
        }
        let reportError: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in
                self?.lastError = message
                self?.appendLog(level: .warning, message: "service \(label) failed: \(message)")
            }
        }

        Task.detached(priority: .background) {
            do {
                let manager = ServiceManager(commandRunner: CommandRunner(), verbose: verbose)
                let status = try action(manager)
                updateStatus(status)
                appendLog(.info, "service \(label) succeeded")

                if label != "status" {
                    let updated = try manager.status()
                    updateStatus(updated)
                }
            } catch {
                reportError(error.localizedDescription)
            }
        }
    }

    private func appendLog(level: MonitorLogLevel, message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        logs.append(entry)
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }
}
