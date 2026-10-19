import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Settings window: detection thresholds, power and notification options, allow list, launch at login.
struct SettingsView: View {
    @EnvironmentObject private var monitor: HogMonitor
    @AppStorage(Prefs.threshold) private var threshold = 60.0
    @AppStorage(Prefs.duration) private var duration = 3
    @AppStorage(Prefs.batteryOnly) private var batteryOnly = false
    @AppStorage(Prefs.notifications) private var notifications = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var selection = Set<AllowedApp.ID>()

    var body: some View {
        Form {
            Section("Detection") {
                LabeledContent("CPU threshold: \(Int(threshold))% of one core") {
                    Slider(value: $threshold, in: 20...200, step: 5)
                }
                Stepper("Sustained for \(duration) minute\(duration == 1 ? "" : "s")", value: $duration, in: 1...30)
                Toggle("Only watch while on battery", isOn: $batteryOnly)
            }

            Section("Allow list") {
                Table(monitor.allowList, selection: $selection) {
                    TableColumn("App", value: \.name)
                    TableColumn("Identifier", value: \.key)
                }
                .frame(minHeight: 110)
                HStack {
                    Menu("Add") {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? "App") {
                                if let id = app.bundleIdentifier { monitor.allow(key: id, name: app.localizedName ?? id) }
                            }
                        }
                        Divider()
                        Button("Choose App…", action: chooseApp)
                    }
                    .fixedSize()
                    Button("Remove") {
                        monitor.allowList.removeAll { selection.contains($0.id) }
                        selection = []
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                    Text("Apps expected to be busy, such as video editors or compilers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Show notifications", isOn: $notifications)
                    .onChange(of: notifications) { _, on in if on { monitor.requestNotificationPermission() } }
                if notifications && monitor.notificationsDenied {
                    HStack {
                        Text("Notifications are turned off for HogCatcher in System Settings.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Button("Clear Incident History") { monitor.clearIncidents() }
            }

            Section {
                Button("Support / Donate ❤️") {
                    NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 600)
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            monitor.allow(key: id, name: name)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
