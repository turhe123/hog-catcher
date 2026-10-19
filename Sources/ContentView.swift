import AppKit
import SwiftUI

/// The menu bar popover: live top consumers, recent incidents and footer actions.
struct ContentView: View {
    @EnvironmentObject private var monitor: HogMonitor
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            section("Now") { nowList }
            Divider()
            section("Incidents") { incidentList }
            if let message = monitor.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Image(systemName: "flame.fill")
                .foregroundStyle(monitor.activeHogs.isEmpty ? Color.secondary : Color.orange)
            Text("HogCatcher").font(.headline)
            Spacer()
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var status: String {
        if monitor.isPaused { return "Paused on AC power" }
        let count = monitor.activeHogs.count
        return count == 0 ? "Everything looks calm" : "\(count) hog\(count == 1 ? "" : "s") active"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder private var nowList: some View {
        if !monitor.hasSample {
            Text("Measuring…").foregroundStyle(.secondary)
        } else if monitor.top.isEmpty {
            Text("Everything looks calm").foregroundStyle(.secondary)
        } else {
            let scale = max(100, monitor.top.first?.cpu ?? 100)
            ForEach(monitor.top) { app in
                UsageRow(app: app, scale: scale, isHog: monitor.activeHogs.contains(app.id))
            }
        }
    }

    @ViewBuilder private var incidentList: some View {
        if monitor.incidents.isEmpty {
            Text("Everything looks calm").foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(monitor.incidents.prefix(20)) { incident in
                        HStack {
                            Text(incident.name).lineLimit(1)
                            Spacer()
                            Text("\(Int(incident.averageCPU.rounded()))% · \(Int(incident.minutes.rounded())) min")
                                .foregroundStyle(.orange)
                            Text(incident.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    private var footer: some View {
        HStack {
            Button("Support / Donate ❤️") {
                NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
            }
            Spacer()
            Button("Settings") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

/// One live row: icon, name, CPU bar and a context menu with Quit / Force Quit.
private struct UsageRow: View {
    @EnvironmentObject private var monitor: HogMonitor
    let app: AppUsage
    let scale: Double
    let isHog: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSRunningApplication(processIdentifier: app.pid)?.icon
                  ?? NSWorkspace.shared.icon(for: .unixExecutable))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(app.name).lineLimit(1)
                    if app.isSystem { Text("system").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Text("\(Int(app.cpu.rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(isHog ? Color.orange : Color.accentColor)
                            .frame(width: geo.size.width * min(app.cpu / scale, 1))
                    }
                }
                .frame(height: 4)
                .animation(.easeOut(duration: 0.4), value: app.cpu)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if monitor.canQuit(app) {
                Button("Quit \(app.name)") { monitor.quit(pid: app.pid, name: app.name) }
                Button("Force Quit \(app.name)…") { monitor.confirmForceQuit(app) }
                Divider()
                Button("Add to Allow List") { monitor.allow(key: app.id, name: app.name) }
            } else {
                Text(app.isSystem ? "System process (informational)" : "This app can't be quit from here")
            }
        }
    }
}
