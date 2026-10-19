import AppKit
import UserNotifications

/// A recorded hog event shown in the Incidents list.
struct Incident: Codable, Identifiable {
    var id = UUID()
    let key: String
    let name: String
    let date: Date
    let minutes: Double
    let averageCPU: Double
}

/// An app that is expected to be busy and is never reported.
struct AllowedApp: Codable, Identifiable, Hashable {
    let key: String
    let name: String
    var id: String { key }
}

/// UserDefaults keys shared by the monitor and the Settings window.
enum Prefs {
    static let threshold = "cpuThreshold"
    static let duration = "durationMinutes"
    static let batteryOnly = "batteryOnly"
    static let notifications = "notificationsEnabled"
    static let allowList = "allowList"
    static let ignoredToday = "ignoredToday"
}

/// Samples CPU every five seconds, tracks how long each app stays over the threshold,
/// records incidents, posts notifications and performs Quit / Force Quit.
@MainActor
final class HogMonitor: ObservableObject {
    static let shared = HogMonitor()
    static let category = "HOG"
    static let infoCategory = "HOG_INFO"

    @Published private(set) var top: [AppUsage] = []
    @Published private(set) var incidents: [Incident] = []
    @Published private(set) var activeHogs: Set<String> = []
    @Published private(set) var isPaused = false
    @Published private(set) var hasSample = false
    @Published private(set) var message: String?
    @Published var notificationsDenied = false
    @Published var allowList: [AllowedApp] = [] {
        didSet { save(allowList, key: Prefs.allowList) }
    }

    private struct Streak { var seconds = 0.0; var cpuSum = 0.0; var samples = 0 }

    private let sampler = ProcessSampler()
    private let interval: TimeInterval = 5
    private let snooze: TimeInterval = 30 * 60
    private var timer: Timer?
    private var streaks: [String: Streak] = [:]
    private var lastWarned: [String: Date] = [:]
    private var ignoredToday: [String: Date] = [:]
    private var lastTick: Date?
    private var messageTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    /// Bundle IDs and process names that must never be offered for quitting.
    private let protectedIDs: Set<String> = ["com.apple.finder", "WindowServer", "loginwindow", "kernel_task"]

    private var incidentsURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base.appendingPathComponent("HogCatcher", isDirectory: true).appendingPathComponent("incidents.json")
    }

    private init() {
        defaults.register(defaults: [Prefs.threshold: 60.0, Prefs.duration: 3, Prefs.notifications: true])
        allowList = load([AllowedApp].self, key: Prefs.allowList) ?? []
        ignoredToday = load([String: Date].self, key: Prefs.ignoredToday) ?? [:]
        if let url = incidentsURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Incident].self, from: data) {
            incidents = saved
        }
    }

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in HogMonitor.shared.tick() }
        }
        // Discard the first sample after wake so sleep time doesn't look like a spike.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in HogMonitor.shared.resetBaseline() }
        }
    }

    private func resetBaseline() {
        sampler.reset()
        lastTick = nil
    }

    // MARK: Sampling

    private func tick() {
        let now = Date()
        let elapsed = lastTick.map { now.timeIntervalSince($0) } ?? interval
        lastTick = now
        guard let usage = sampler.sample() else { return }
        // A long gap means we were suspended; start over rather than count it.
        if elapsed > interval * 3 { streaks = [:] }
        hasSample = true
        top = Array(usage.filter { $0.cpu >= 0.1 }.sorted { $0.cpu > $1.cpu }.prefix(5))

        isPaused = defaults.bool(forKey: Prefs.batteryOnly) && !PowerSource.isOnBattery
        guard !isPaused else {
            streaks = [:]
            activeHogs = []
            return
        }

        let threshold = defaults.double(forKey: Prefs.threshold)
        let limit = Double(max(defaults.integer(forKey: Prefs.duration), 1)) * 60
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let allowed = Set(allowList.map(\.key))
        var over: [String: Streak] = [:]
        var active = Set<String>()

        for app in usage where app.cpu > threshold && app.pid != frontPID
            && app.pid != getpid() && !allowed.contains(app.id) {
            var streak = streaks[app.id] ?? Streak()
            streak.seconds += min(elapsed, interval * 3)
            streak.cpuSum += app.cpu
            streak.samples += 1
            over[app.id] = streak
            if streak.seconds >= limit && !isIgnoredToday(app.id) {
                active.insert(app.id)
                warnIfNeeded(app, streak: streak)
            }
        }
        streaks = over
        activeHogs = active
    }

    private func warnIfNeeded(_ app: AppUsage, streak: Streak) {
        let now = Date()
        if let last = lastWarned[app.id], now.timeIntervalSince(last) < snooze { return }
        lastWarned[app.id] = now

        let incident = Incident(key: app.id, name: app.name, date: now, minutes: streak.seconds / 60,
                                averageCPU: streak.cpuSum / Double(max(streak.samples, 1)))
        incidents.insert(incident, at: 0)
        if incidents.count > 100 { incidents.removeLast(incidents.count - 100) }
        saveIncidents()
        notify(app, incident: incident)
    }

    private func isIgnoredToday(_ key: String) -> Bool {
        ignoredToday[key].map { Calendar.current.isDateInToday($0) } ?? false
    }

    // MARK: Notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in HogMonitor.shared.notificationsDenied = !granted }
        }
    }

    private func notify(_ app: AppUsage, incident: Incident) {
        guard defaults.bool(forKey: Prefs.notifications) else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(app.name) is burning CPU"
        content.body = "Used \(Int(incident.averageCPU.rounded()))% of a core for "
            + "\(Int(incident.minutes.rounded())) min while in the background."
        content.sound = .default
        content.categoryIdentifier = canQuit(app) ? Self.category : Self.infoCategory
        content.userInfo = ["key": app.id, "name": app.name, "pid": Int(app.pid)]
        let request = UNNotificationRequest(identifier: "hog-\(app.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if error != nil { Task { @MainActor in HogMonitor.shared.notificationsDenied = true } }
        }
    }

    // MARK: Actions

    func canQuit(_ app: AppUsage) -> Bool {
        !app.isSystem && app.pid != getpid() && !protectedIDs.contains(app.bundleID ?? app.name)
    }

    func quit(pid: pid_t, name: String, force: Bool = false) {
        if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            if !(force ? app.forceTerminate() : app.terminate()) { flash("\(name) refused to quit.") }
        } else if kill(pid, 0) == 0 {
            if kill(pid, force ? SIGKILL : SIGTERM) != 0 { flash("Couldn't quit \(name).") }
        } else {
            flash("\(name) is no longer running.")
        }
    }

    func confirmForceQuit(_ app: AppUsage) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Force quit \(app.name)?"
        alert.informativeText = "Unsaved changes in \(app.name) will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { quit(pid: app.pid, name: app.name, force: true) }
    }

    func ignoreToday(key: String) {
        ignoredToday = ignoredToday.filter { Calendar.current.isDateInToday($0.value) }
        ignoredToday[key] = Date()
        save(ignoredToday, key: Prefs.ignoredToday)
        activeHogs.remove(key)
    }

    func allow(key: String, name: String) {
        guard !allowList.contains(where: { $0.key == key }) else { return }
        allowList.append(AllowedApp(key: key, name: name))
        streaks[key] = nil
        activeHogs.remove(key)
    }

    func clearIncidents() {
        incidents = []
        saveIncidents()
    }

    func flash(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { HogMonitor.shared.message = nil }
        }
    }

    // MARK: Persistence

    private func saveIncidents() {
        guard let url = incidentsURL, let data = try? JSONEncoder().encode(incidents) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
