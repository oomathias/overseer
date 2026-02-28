import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = OverseerViewModel()
    @State private var isFollowingLogs = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Overseer Agent")
                .font(.system(size: 28, weight: .semibold, design: .rounded))

            GroupBox("Config") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Config path", text: $viewModel.configPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose") {
                            viewModel.chooseConfigFile()
                        }
                        Button("Open") {
                            viewModel.openConfigInFinder()
                        }
                        Button("Validate") {
                            viewModel.loadConfigSummary()
                        }
                    }

                    Text(viewModel.configSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let lastError = viewModel.lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("Monitor") {
                HStack(spacing: 12) {
                    Button(viewModel.isMonitoring ? "Monitoring" : "Start Monitor") {
                        viewModel.startMonitoring()
                    }
                    .disabled(viewModel.isMonitoring)

                    Button("Stop Monitor") {
                        viewModel.stopMonitoring()
                    }
                    .disabled(!viewModel.isMonitoring)

                    Toggle("Verbose logs", isOn: $viewModel.verboseLogging)
                        .toggleStyle(.switch)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Service") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Install") {
                            viewModel.installService()
                        }
                        Button("Uninstall") {
                            viewModel.uninstallService()
                        }
                        Button("Start") {
                            viewModel.startService()
                        }
                        Button("Stop") {
                            viewModel.stopService()
                        }
                        Button("Restart") {
                            viewModel.restartService()
                        }
                        Button("Status") {
                            viewModel.refreshServiceStatus()
                        }
                    }

                    Text("Status: \(viewModel.serviceStatus)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Logs") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.badge")
                            .foregroundColor(.secondary)
                        Text("For persistent alerts, set Alert Style to Persistent in System Settings → Notifications.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(viewModel.logs) { entry in
                                    Text("[\(entry.timestamp, format: Date.FormatStyle(date: .omitted, time: .standard))] \(entry.level.rawValue): \(entry.message)")
                                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                                        .foregroundColor(entry.level == .warning ? .red : .primary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id("log-bottom")
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(minHeight: 200)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    if isFollowingLogs {
                                        isFollowingLogs = false
                                    }
                                }
                        )
                        .onChange(of: viewModel.logs.count) { _, _ in
                            guard isFollowingLogs else {
                                return
                            }
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("log-bottom", anchor: .bottom)
                            }
                        }

                        HStack(spacing: 12) {
                            Spacer()
                            Button(isFollowingLogs ? "Following" : "Follow Logs") {
                                isFollowingLogs = true
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("log-bottom", anchor: .bottom)
                                }
                            }
                            Button("Clear Logs") {
                                viewModel.clearLogs()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 680)
        .onAppear {
            viewModel.loadConfigSummary()
            viewModel.refreshServiceStatus()
        }
    }
}

#Preview {
    ContentView()
}
