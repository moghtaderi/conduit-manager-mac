/// Psiphon Conduit Menu Bar App for macOS
/// A lightweight menu bar app to control the Psiphon Conduit Docker container(s).
/// Supports multi-container configurations (up to 5 containers).

import SwiftUI
import AppKit
import UserNotifications

// MARK: - App Entry Point

@main
struct ConduitMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

// MARK: - Types

enum DockerStatus {
    case notInstalled, notRunning, running
}

enum TerminalApp: String, CaseIterable {
    case terminal = "Terminal"
    case iterm = "iTerm"

    var isInstalled: Bool {
        switch self {
        case .terminal: return true  // Always available on macOS
        case .iterm: return FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    private let version = "2.1.0"
    private var statusItem: NSStatusItem?
    private var manager: ConduitManager?
    private var timer: Timer?
    private var isUpdating = false  // Prevent concurrent updates
    private var dashboardWindow: DashboardWindowController?

    private var preferredTerminal: TerminalApp {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "preferredTerminal"),
                  let app = TerminalApp(rawValue: raw) else { return .terminal }
            return app
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "preferredTerminal") }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        manager = ConduitManager()

        // Set initial icon immediately (before async update)
        setInitialIcon()

        setupMenu()

        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
        updateStatus()
    }

    /// Sets a placeholder icon immediately so the menu bar item is visible
    private func setInitialIcon() {
        guard let button = statusItem?.button else { return }
        if let image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "Conduit") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            if let configured = image.withSymbolConfiguration(config) {
                configured.isTemplate = true
                button.image = configured
            }
        }
    }

    // MARK: Menu Setup

    private func setupMenu() {
        let menu = NSMenu()

        // Status header
        menu.addItem(infoItem("○ Conduit: Checking...", tag: 100))
        menu.addItem(infoItem("", tag: 101, hidden: true))  // Docker helper message
        menu.addItem(.separator())

        // Aggregated stats
        menu.addItem(infoItem("Clients: -", tag: 102))
        menu.addItem(infoItem("Traffic: -", tag: 103))
        menu.addItem(infoItem("Limit: -", tag: 401))
        menu.addItem(.separator())

        // Per-container stats (shown when multiple containers)
        for i in 1...5 {
            menu.addItem(infoItem("", tag: 600 + i, hidden: true))  // Container stats
        }
        let containerSeparator = NSMenuItem.separator()
        containerSeparator.tag = 650
        containerSeparator.isHidden = true
        menu.addItem(containerSeparator)

        // Actions
        menu.addItem(actionItem("Open Dashboard...", action: #selector(openDashboard), key: "d", tag: 310))

        // Terminal submenu
        let terminalItem = NSMenuItem(title: "Open Terminal...", action: nil, keyEquivalent: "t")
        terminalItem.tag = 305
        let terminalMenu = NSMenu()
        for app in TerminalApp.allCases where app.isInstalled {
            let item = NSMenuItem(title: app.rawValue, action: #selector(selectTerminal(_:)), keyEquivalent: "")
            item.representedObject = app
            item.state = (app == preferredTerminal) ? .on : .off
            terminalMenu.addItem(item)
        }
        terminalItem.submenu = terminalMenu
        menu.addItem(terminalItem)

        menu.addItem(actionItem("Download Docker Desktop...", action: #selector(openDockerDownload), tag: 300, hidden: true))
        menu.addItem(.separator())

        // Footer
        let versionItem = NSMenuItem(title: "v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(actionItem("Quit", action: #selector(quitApp), key: "q"))

        statusItem?.menu = menu
    }

    /// Creates a non-interactive info item with custom view (avoids grayed-out appearance)
    private func infoItem(_ title: String, tag: Int, hidden: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = tag
        item.isHidden = hidden

        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 13)
        label.textColor = .labelColor
        label.frame = NSRect(x: 14, y: 0, width: 280, height: 18)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 18))
        container.addSubview(label)
        item.view = container

        return item
    }

    /// Creates a clickable action item
    private func actionItem(_ title: String, action: Selector, key: String = "", tag: Int = 0, hidden: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.tag = tag
        item.isHidden = hidden
        return item
    }

    /// Updates an info item's label text and optional prefix icon color
    private func updateInfo(_ item: NSMenuItem, _ title: String, prefixColor: NSColor? = nil) {
        guard let label = item.view?.subviews.first as? NSTextField else { return }

        if let color = prefixColor, title.count > 1 {
            // Use attributed string for colored prefix (first character)
            let attributed = NSMutableAttributedString(string: title)
            attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1))
            attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 1, length: title.count - 1))
            label.attributedStringValue = attributed
        } else {
            label.stringValue = title
            label.textColor = .labelColor
        }
    }

    // MARK: Status Updates

    private func updateStatus() {
        // Prevent concurrent updates if previous one is still running
        guard !isUpdating else { return }
        isUpdating = true

        // Run Docker commands on background thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let manager = self.manager else {
                DispatchQueue.main.async { self?.isUpdating = false }
                return
            }

            // Gather all data on background thread
            let docker = manager.dockerStatus
            let running = docker == .running && manager.isRunning
            let count = manager.containerCount
            let stats = manager.stats
            let traffic = manager.traffic
            let health = manager.healthStatus
            let containerStats = manager.perContainerStats
            let config = docker == .running ? manager.config : nil

            // Update UI on main thread
            DispatchQueue.main.async { [weak self] in
                self?.applyStatusUpdate(
                    docker: docker,
                    running: running,
                    count: count,
                    stats: stats,
                    traffic: traffic,
                    health: health,
                    containerStats: containerStats,
                    config: config
                )
                self?.isUpdating = false
            }
        }
    }

    private func applyStatusUpdate(
        docker: DockerStatus,
        running: Bool,
        count: (running: Int, total: Int),
        stats: (connected: Int, connecting: Int)?,
        traffic: (up: String, down: String)?,
        health: ConduitManager.HealthStatus,
        containerStats: [ContainerStats],
        config: (maxClients: String, bandwidth: String)?
    ) {
        guard let menu = statusItem?.menu else { return }

        // Update icon
        updateIcon(docker: docker, running: running)

        // Status line (100)
        if let item = menu.item(withTag: 100) {
            switch docker {
            case .notInstalled:
                updateInfo(item, "⚠ Docker Not Installed", prefixColor: .systemOrange)
            case .notRunning:
                updateInfo(item, "⚠ Docker Not Running", prefixColor: .systemOrange)
            case .running:
                if running {
                    if count.total > 1 {
                        updateInfo(item, "● Running (\(count.running)/\(count.total) containers)", prefixColor: .systemGreen)
                    } else {
                        updateInfo(item, "● Running", prefixColor: .systemGreen)
                    }
                } else {
                    updateInfo(item, "○ Stopped")
                }
            }
        }

        // Docker helper (101)
        if let item = menu.item(withTag: 101) {
            switch docker {
            case .notInstalled:
                updateInfo(item, "Install Docker Desktop to use Conduit")
                item.isHidden = false
            case .notRunning:
                updateInfo(item, "Please start Docker Desktop")
                item.isHidden = false
            case .running:
                item.isHidden = true
            }
        }

        // Aggregated stats (102, 103, 401)
        if let item = menu.item(withTag: 102) {
            if running, let s = stats {
                let text = s.connecting > 0
                    ? "\(formatLargeNumber(s.connected)) clients (\(s.connecting) connecting)"
                    : "\(formatLargeNumber(s.connected)) clients"
                updateInfo(item, text)
            } else {
                updateInfo(item, "No clients")
            }
            item.isHidden = docker != .running
        }

        if let item = menu.item(withTag: 103) {
            if running, let t = traffic {
                updateInfo(item, "↑ \(t.up)  ↓ \(t.down)")
            } else {
                updateInfo(item, "No traffic")
            }
            item.isHidden = docker != .running
        }

        if let item = menu.item(withTag: 401) {
            if let c = config {
                updateInfo(item, "Limit: \(c.maxClients) clients / \(c.bandwidth)")
            } else {
                updateInfo(item, "Limit: -")
            }
            item.isHidden = docker != .running
        }

        // Per-container stats (601-605)
        let hasMultiple = containerStats.count > 1
        for i in 1...5 {
            if let item = menu.item(withTag: 600 + i) {
                if hasMultiple && i <= containerStats.count {
                    let stat = containerStats[i - 1]
                    let icon = stat.running ? "●" : "○"
                    let color: NSColor = stat.running ? .systemGreen : .secondaryLabelColor
                    if stat.running {
                        updateInfo(item, "\(icon) \(stat.name): \(stat.connected) clients", prefixColor: color)
                    } else {
                        updateInfo(item, "\(icon) \(stat.name): stopped", prefixColor: color)
                    }
                    item.isHidden = false
                } else {
                    item.isHidden = true
                }
            }
        }
        menu.item(withTag: 650)?.isHidden = !hasMultiple  // Container separator

        // Docker download (300)
        menu.item(withTag: 300)?.isHidden = docker != .notInstalled

        // Dashboard (310) - always enabled
        menu.item(withTag: 310)?.isEnabled = true
    }

    private func updateIcon(docker: DockerStatus, running: Bool) {
        guard let button = statusItem?.button else { return }

        let (symbolName, colored): (String, Bool) = {
            switch docker {
            case .notInstalled, .notRunning: return ("exclamationmark.triangle", false)
            case .running: return running
                ? ("antenna.radiowaves.left.and.right", true)
                : ("antenna.radiowaves.left.and.right.slash", false)
            }
        }()

        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Conduit") else { return }
        var config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        if colored { config = config.applying(.init(paletteColors: [.systemGreen])) }

        if let configured = image.withSymbolConfiguration(config) {
            configured.isTemplate = !colored
            button.image = configured
        }
    }

    /// Formats large numbers: 1234 → "1.2K", 1234567 → "1.2M"
    private func formatLargeNumber(_ num: Int) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000)
        } else if num >= 1_000 {
            return String(format: "%.1fK", Double(num) / 1_000)
        }
        return "\(num)"
    }

    // MARK: Actions

    @objc private func openDashboard() {
        guard let manager = manager else { return }

        if dashboardWindow == nil {
            dashboardWindow = DashboardWindowController(manager: manager, version: version)
        }
        dashboardWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openDockerDownload() {
        NSWorkspace.shared.open(URL(string: "https://www.docker.com/products/docker-desktop/")!)
    }

    @objc private func selectTerminal(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? TerminalApp else { return }
        preferredTerminal = app

        // Update checkmarks in submenu
        if let menu = sender.menu {
            for item in menu.items {
                item.state = (item.representedObject as? TerminalApp == app) ? .on : .off
            }
        }

        // Open the selected terminal
        openTerminal(with: app)
    }

    private func openTerminal(with app: TerminalApp) {
        guard let path = findScript() else {
            notify("Error", "Conduit script not found")
            return
        }

        // Escape the path to prevent AppleScript injection
        // Must escape backslashes first, then double quotes
        let escapedPath = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        switch app {
        case .terminal:
            script = """
                tell application "Terminal"
                    do script "\(escapedPath)"
                    activate
                end tell
                """
        case .iterm:
            script = """
                tell application "iTerm"
                    create window with default profile
                    tell current session of current window
                        write text "\(escapedPath)"
                    end tell
                    activate
                end tell
                """
        }
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: Helpers

    private func findScript() -> String? {
        ["\(NSHomeDirectory())/conduit-manager/conduit-mac.sh",
         "/usr/local/bin/conduit",
         "\(NSHomeDirectory())/conduit-mac.sh"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}

// MARK: - Dashboard Window Controller

class DashboardWindowController: NSWindowController {

    private let manager: ConduitManager
    private let version: String

    init(manager: ConduitManager, version: String = "2.1.0") {
        self.manager = manager
        self.version = version

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Conduit Dashboard"
        window.center()
        window.minSize = NSSize(width: 420, height: 500)
        window.isReleasedWhenClosed = false

        // Force dark appearance
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
        window.titlebarAppearsTransparent = true

        super.init(window: window)

        let dashboardView = DashboardView(manager: manager, version: version)
        window.contentView = NSHostingView(rootView: dashboardView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Dashboard SwiftUI Views

struct DashboardView: View {
    let manager: ConduitManager
    let version: String

    @State private var containerStats: [ContainerStats] = []
    @State private var totalStats: (connected: Int, connecting: Int)?
    @State private var totalTraffic: (up: String, down: String)?
    @State private var healthStatus: ConduitManager.HealthStatus = .unknown
    @State private var isRefreshing = false
    @State private var hasLoaded = false
    @State private var hasFullData = false
    @State private var recentLogs: [String] = []
    @State private var selectedTab = 0  // 0 = Containers, 1 = Logs, 2 = Health

    private let darkBg = Color(red: 0.1, green: 0.1, blue: 0.12)
    private let cardBg = Color(red: 0.15, green: 0.15, blue: 0.18)

    let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            darkBg.ignoresSafeArea()

            VStack(spacing: 0) {
                if !hasLoaded {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Spacer()
                } else {
                    // Header with totals
                    DashboardHeader(
                        totalStats: totalStats,
                        totalTraffic: totalTraffic,
                        containerCount: containerStats.count,
                        runningCount: containerStats.filter { $0.running }.count,
                        isLoading: !hasFullData,
                        version: version
                    )

                    // Tab bar
                    HStack(spacing: 0) {
                        TabButton(title: "Containers", isSelected: selectedTab == 0) { selectedTab = 0 }
                        TabButton(title: "Logs", isSelected: selectedTab == 1) { selectedTab = 1 }
                        TabButton(title: "Health", isSelected: selectedTab == 2) { selectedTab = 2 }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    // Tab content
                    switch selectedTab {
                    case 0:
                        // Container list
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(containerStats, id: \.index) { stat in
                                    ContainerRow(stat: stat, manager: manager, onRefresh: fullRefresh, isLoading: !hasFullData && stat.running)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                    case 1:
                        // Logs view
                        LogsView(logs: recentLogs, isLoading: !hasFullData)

                    case 2:
                        // Health check view
                        HealthCheckView(
                            manager: manager,
                            healthStatus: healthStatus,
                            containerStats: containerStats
                        )

                    default:
                        EmptyView()
                    }

                    // Footer with global controls
                    DashboardFooter(
                        manager: manager,
                        containerStats: containerStats,
                        isRefreshing: isRefreshing,
                        onRefresh: fullRefresh
                    )
                }
            }
        }
        .frame(minWidth: 420, minHeight: 500)
        .preferredColorScheme(.dark)
        .onAppear { quickLoad() }
        .onReceive(timer) { _ in fullRefresh() }
    }

    private func quickLoad() {
        DispatchQueue.global(qos: .userInteractive).async {
            let quickStats = manager.quickContainerList
            let health = manager.healthStatus

            DispatchQueue.main.async {
                containerStats = quickStats
                healthStatus = health
                hasLoaded = true
                fullRefresh()
            }
        }
    }

    private func fullRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        DispatchQueue.global(qos: .userInitiated).async {
            let stats = manager.perContainerStats
            let total = manager.stats
            let traffic = manager.traffic
            let health = manager.healthStatus
            let logs = manager.recentLogs(limit: 30)

            DispatchQueue.main.async {
                containerStats = stats
                totalStats = total
                totalTraffic = traffic
                healthStatus = health
                recentLogs = logs
                isRefreshing = false
                hasFullData = true
            }
        }
    }
}

// MARK: - Tab Button

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    private let accentGreen = Color(red: 0.2, green: 0.8, blue: 0.4)

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? accentGreen : .gray)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(
            VStack {
                Spacer()
                if isSelected {
                    Rectangle()
                        .fill(accentGreen)
                        .frame(height: 2)
                }
            }
        )
    }
}

// MARK: - Logs View

struct LogsView: View {
    let logs: [String]
    let isLoading: Bool

    @State private var showInfo = true
    @State private var showStats = true
    @State private var showErrors = true

    private let cardBg = Color(red: 0.12, green: 0.12, blue: 0.14)
    private let accentGreen = Color(red: 0.2, green: 0.8, blue: 0.4)

    private var filteredLogs: [String] {
        logs.filter { line in
            if line.contains("[INFO]") && !showInfo { return false }
            if line.contains("[STATS]") && !showStats { return false }
            if (line.contains("[ERROR]") || line.contains("[WARN]")) && !showErrors { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Filter toggles
            HStack(spacing: 12) {
                FilterToggle(label: "INFO", isOn: $showInfo, color: .white.opacity(0.7))
                FilterToggle(label: "STATS", isOn: $showStats, color: accentGreen)
                FilterToggle(label: "ERRORS", isOn: $showErrors, color: .red)
                Spacer()
                Text("\(filteredLogs.count) lines")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 16)

            // Log content
            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 2) {
                        if isLoading && logs.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.8)
                                Spacer()
                            }
                            .padding(.vertical, 20)
                        } else if filteredLogs.isEmpty {
                            Text(logs.isEmpty ? "No logs available" : "No matching logs")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                                .padding()
                        } else {
                            ForEach(Array(filteredLogs.enumerated()), id: \.offset) { index, line in
                                LogLine(text: line)
                                    .id(index)
                            }
                        }
                    }
                    .padding(12)
                    .onChange(of: filteredLogs.count) { _ in
                        withAnimation {
                            proxy.scrollTo(filteredLogs.count - 1, anchor: .bottom)
                        }
                    }
                }
            }
            .background(cardBg)
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .padding(.top, 8)
    }
}

struct FilterToggle: View {
    let label: String
    @Binding var isOn: Bool
    var color: Color = .white

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10))
                    .foregroundColor(isOn ? color : .gray)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isOn ? color : .gray)
            }
        }
        .buttonStyle(.plain)
    }
}

struct LogLine: View {
    let text: String

    private var logColor: Color {
        if text.contains("[ERROR]") || text.contains("error") { return .red }
        if text.contains("[WARN]") || text.contains("warning") { return .orange }
        if text.contains("[STATS]") { return Color(red: 0.2, green: 0.8, blue: 0.4) }
        return .white.opacity(0.8)
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(logColor)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - Health Check View

struct HealthCheckView: View {
    let manager: ConduitManager
    let healthStatus: ConduitManager.HealthStatus
    let containerStats: [ContainerStats]

    @State private var dockerInfo: String = ""
    @State private var isChecking = false

    private let cardBg = Color(red: 0.15, green: 0.15, blue: 0.18)
    private let accentGreen = Color(red: 0.2, green: 0.8, blue: 0.4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Overall status
                HStack(spacing: 12) {
                    Circle()
                        .fill(healthColor)
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System Status: \(healthStatus.description)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text(healthMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(cardBg))

                // Check items
                VStack(spacing: 8) {
                    HealthCheckItem(
                        title: "Docker Status",
                        status: manager.dockerStatus == .running,
                        detail: manager.dockerStatus == .running ? "Docker is running" : "Docker not available"
                    )

                    HealthCheckItem(
                        title: "Containers Configured",
                        status: !containerStats.isEmpty,
                        detail: "\(containerStats.count) container(s) configured"
                    )

                    HealthCheckItem(
                        title: "Containers Running",
                        status: containerStats.contains { $0.running },
                        detail: "\(containerStats.filter { $0.running }.count) container(s) running"
                    )

                    HealthCheckItem(
                        title: "Network Connectivity",
                        status: containerStats.filter { $0.running }.contains { $0.connected > 0 },
                        detail: containerStats.filter { $0.running && $0.connected > 0 }.isEmpty
                            ? "No clients connected yet"
                            : "Clients are connecting"
                    )
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(cardBg))

                // Run Health Check button
                Button {
                    runHealthCheck()
                } label: {
                    HStack {
                        if isChecking {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "stethoscope")
                                .font(.system(size: 11))
                        }
                        Text("Run Full Health Check")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(DarkButtonStyle(isPrimary: true))
                .disabled(isChecking)

                // Docker info (if available)
                if !dockerInfo.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Docker Info")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.gray)
                        Text(dockerInfo)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(cardBg))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var healthColor: Color {
        switch healthStatus {
        case .healthy: return accentGreen
        case .unhealthy: return .red
        case .unknown: return .gray
        }
    }

    private var healthMessage: String {
        switch healthStatus {
        case .healthy: return "All systems operational"
        case .unhealthy: return "No containers running"
        case .unknown: return "Unable to determine status"
        }
    }

    private func runHealthCheck() {
        isChecking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let info = manager.dockerInfoSummary
            DispatchQueue.main.async {
                dockerInfo = info
                isChecking = false
            }
        }
    }
}

struct HealthCheckItem: View {
    let title: String
    let status: Bool
    let detail: String

    private let accentGreen = Color(red: 0.2, green: 0.8, blue: 0.4)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(status ? accentGreen : .red.opacity(0.8))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }

            Spacer()
        }
    }
}

struct DashboardHeader: View {
    let totalStats: (connected: Int, connecting: Int)?
    let totalTraffic: (up: String, down: String)?
    let containerCount: Int
    let runningCount: Int
    var isLoading: Bool = false
    var version: String = ""

    private let accentGreen = Color(red: 0.2, green: 0.8, blue: 0.4)

    var body: some View {
        VStack(spacing: 16) {
            // Top bar with version
            HStack {
                Text("Conduit Dashboard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)
                Spacer()
                if !version.isEmpty {
                    Text("v\(version)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))
                }
            }

            // Big stats display
            HStack(alignment: .top, spacing: 20) {
                // Clients (prominent)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(isLoading ? "..." : "\(totalStats?.connected ?? 0)")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        if let connecting = totalStats?.connecting, connecting > 0 && !isLoading {
                            Text("+\(connecting)")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundColor(.yellow)
                        }
                    }
                    Text("connected")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }

                Spacer()

                // Traffic (more prominent)
                VStack(alignment: .trailing, spacing: 8) {
                    // Upload
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(accentGreen)
                            Text(totalTraffic?.up ?? "-")
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(accentGreen)
                        }
                        Text("uploaded")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }

                    // Download
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.orange)
                            Text(totalTraffic?.down ?? "-")
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.orange)
                        }
                        Text("downloaded")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                }
            }

            // Status bar
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(runningCount > 0 ? accentGreen : Color.gray)
                        .frame(width: 8, height: 8)
                    Text("\(runningCount)/\(containerCount) containers running")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                Spacer()
            }
        }
        .padding(20)
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
    }
}

struct ContainerRow: View {
    let stat: ContainerStats
    let manager: ConduitManager
    let onRefresh: () -> Void
    var isLoading: Bool = false

    @State private var showQRCode = false

    private let cardBg = Color(red: 0.15, green: 0.15, blue: 0.18)
    private let accentGreen = Color(red: 0.2, green: 0.8, blue: 0.4)

    /// Truncates Node ID for display (first 8 chars...last 8 chars)
    private var truncatedNodeId: String {
        guard stat.nodeId.count > 20 else { return stat.nodeId }
        let start = stat.nodeId.prefix(8)
        let end = stat.nodeId.suffix(8)
        return "\(start)...\(end)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row: name + stats
            HStack {
                // Left side: status dot + name
                HStack(spacing: 8) {
                    Circle()
                        .fill(stat.running ? accentGreen : Color.gray.opacity(0.5))
                        .frame(width: 8, height: 8)

                    Text(stat.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }

                Spacer()

                if stat.running {
                    // Stats
                    HStack(spacing: 12) {
                        VStack(spacing: 2) {
                            HStack(spacing: 2) {
                                Text(isLoading ? "-" : "\(stat.connected)")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white)
                                if stat.connecting > 0 && !isLoading {
                                    Text("+\(stat.connecting)")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.yellow)
                                }
                            }
                            Text("clients")
                                .font(.system(size: 9))
                                .foregroundColor(.gray)
                        }
                        StatPill(value: isLoading ? "-" : stat.up, label: "up", color: accentGreen)
                        StatPill(value: isLoading ? "-" : stat.down, label: "down", color: .orange)
                    }
                } else {
                    Text("Stopped")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
            }

            // Controls row
            HStack(spacing: 8) {
                if stat.running {
                    // Icon-only Restart button
                    Button {
                        DispatchQueue.global(qos: .userInitiated).async {
                            manager.restartOne(at: stat.index)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { onRefresh() }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Restart")

                    // Icon-only Stop button
                    Button {
                        DispatchQueue.global(qos: .userInitiated).async {
                            manager.stopOne(at: stat.index)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { onRefresh() }
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(IconButtonStyle(isDestructive: true))
                    .help("Stop")
                } else {
                    // Icon-only Start button
                    Button {
                        DispatchQueue.global(qos: .userInitiated).async {
                            manager.restartOne(at: stat.index)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { onRefresh() }
                        }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(IconButtonStyle(isPrimary: true))
                    .help("Start")
                }

                Spacer()

                // Uptime with label
                if stat.running && !isLoading && !stat.uptime.isEmpty && stat.uptime != "-" {
                    Text("uptime: \(stat.uptime)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }

            // Node ID row - bottom center
            if !stat.nodeId.isEmpty {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Text(truncatedNodeId)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.gray)
                            .help(stat.nodeId)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(stat.nodeId, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.gray.opacity(0.7))
                        .help("Copy Node ID")

                        Button {
                            showQRCode.toggle()
                        } label: {
                            Image(systemName: "qrcode")
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.gray.opacity(0.7))
                        .help("Show QR Code")
                        .popover(isPresented: $showQRCode) {
                            QRCodeView(nodeId: stat.nodeId, containerName: stat.name, manager: manager)
                        }
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(cardBg)
        )
    }
}

// MARK: - Icon Button Style

struct IconButtonStyle: ButtonStyle {
    var isPrimary: Bool = false
    var isDestructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isDestructive ? .red : (isPrimary ? .black : .white))
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPrimary ? Color(red: 0.2, green: 0.8, blue: 0.4) : Color.white.opacity(0.1))
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: - QR Code View

struct QRCodeView: View {
    let nodeId: String
    let containerName: String
    let manager: ConduitManager

    @State private var privateKey: String = ""
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 12) {
            Text(containerName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)

            Text("Scan in Ryve App")
                .font(.system(size: 10))
                .foregroundColor(.gray)

            if isLoading {
                ProgressView()
                    .frame(width: 150, height: 150)
            } else if let qrImage = generateQRCode() {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .background(Color.white)
                    .cornerRadius(8)
            } else {
                Text("Could not generate QR code")
                    .foregroundColor(.gray)
            }

            Text("Node ID: \(truncatedNodeId)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray)
                .lineLimit(1)
        }
        .padding(16)
        .background(Color(red: 0.15, green: 0.15, blue: 0.18))
        .preferredColorScheme(.dark)
        .onAppear {
            // Fetch private key on-demand when QR popover opens
            DispatchQueue.global(qos: .userInitiated).async {
                let key = manager.fetchPrivateKey(for: containerName)
                DispatchQueue.main.async {
                    privateKey = key
                    isLoading = false
                }
            }
        }
        .onDisappear {
            // Clear sensitive data when popover closes
            privateKey = ""
        }
    }

    private var truncatedNodeId: String {
        guard nodeId.count > 16 else { return nodeId }
        return "\(nodeId.prefix(8))...\(nodeId.suffix(8))"
    }

    /// Generate the Ryve claim URL matching the CLI format
    private func generateClaimUrl() -> String {
        // JSON format: {"version":1,"data":{"key":"PRIVATE_KEY","name":"NODE_NAME"}}
        let jsonData = "{\"version\":1,\"data\":{\"key\":\"\(privateKey)\",\"name\":\"\(containerName)\"}}"
        let b64Data = Data(jsonData.utf8).base64EncodedString()
            .replacingOccurrences(of: "\n", with: "")
        return "network.ryve.app://(app)/conduits?claim=\(b64Data)"
    }

    private func generateQRCode() -> NSImage? {
        guard !privateKey.isEmpty else { return nil }

        let claimUrl = generateClaimUrl()
        guard let data = claimUrl.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up the QR code
        let scale = 10.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = ciImage.transformed(by: transform)

        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)

        return nsImage
    }
}

struct StatPill: View {
    let value: String
    let label: String
    var color: Color = .white

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.gray)
        }
    }
}

struct DarkButtonStyle: ButtonStyle {
    var isPrimary: Bool = false
    var isDestructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isDestructive ? .red : (isPrimary ? .black : .white))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPrimary ? Color(red: 0.2, green: 0.8, blue: 0.4) : Color.white.opacity(0.1))
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

struct DashboardFooter: View {
    let manager: ConduitManager
    let containerStats: [ContainerStats]
    var isRefreshing: Bool = false
    let onRefresh: () -> Void

    private let accentGreen = Color(red: 0.2, green: 0.8, blue: 0.4)
    private var hasRunning: Bool { containerStats.contains { $0.running } }
    private var hasStopped: Bool { containerStats.contains { !$0.running } }

    var body: some View {
        HStack(spacing: 12) {
            // Start All button
            Button {
                DispatchQueue.global(qos: .userInitiated).async {
                    manager.start()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { onRefresh() }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                    Text("Start All")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(DarkButtonStyle(isPrimary: true))
            .disabled(!hasStopped)
            .opacity(hasStopped ? 1.0 : 0.5)

            // Stop All button
            Button {
                DispatchQueue.global(qos: .userInitiated).async {
                    manager.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { onRefresh() }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                    Text("Stop All")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(DarkButtonStyle(isDestructive: true))
            .disabled(!hasRunning)
            .opacity(hasRunning ? 1.0 : 0.5)

            Spacer()

            // Refresh indicator
            if isRefreshing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
    }
}

// MARK: - Container Stats

struct ContainerStats {
    let index: Int
    let name: String
    let running: Bool
    let connected: Int
    let connecting: Int
    let up: String
    let down: String
    let uptime: String
    let nodeId: String      // Derived Node ID (for display)
    // Note: privateKey is fetched on-demand via ConduitManager.fetchPrivateKey(for:)
    // to minimize time sensitive data is held in memory
}

// MARK: - Conduit Manager

class ConduitManager {

    private let baseContainer = "conduit-mac"
    private let maxContainers = 5

    // MARK: Multi-Container Support

    /// Get container name for index (1 = "conduit-mac", 2 = "conduit-mac-2", etc.)
    private func containerName(at index: Int) -> String {
        index == 1 ? baseContainer : "\(baseContainer)-\(index)"
    }

    /// Public accessor for container name
    func containerNameForIndex(_ index: Int) -> String {
        containerName(at: index)
    }

    /// Find all configured containers (returns indices of existing containers)
    private var configuredContainers: [Int] {
        let allContainers = run("docker", "ps", "-a", "--format", "{{.Names}}")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var indices: [Int] = []
        for i in 1...maxContainers {
            if allContainers.contains(containerName(at: i)) {
                indices.append(i)
            }
        }
        return indices
    }

    /// Find all running containers
    private var runningContainers: [Int] {
        let running = run("docker", "ps", "--format", "{{.Names}}")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var indices: [Int] = []
        for i in 1...maxContainers {
            if running.contains(containerName(at: i)) {
                indices.append(i)
            }
        }
        return indices
    }

    /// Container count info for display
    var containerCount: (running: Int, total: Int) {
        (runningContainers.count, configuredContainers.count)
    }

    // MARK: Status

    var dockerStatus: DockerStatus {
        guard isDockerInstalled else { return .notInstalled }
        guard isDockerRunning else { return .notRunning }
        return .running
    }

    var isRunning: Bool {
        !runningContainers.isEmpty
    }

    private var isDockerInstalled: Bool {
        dockerPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private var isDockerRunning: Bool {
        let out = run("docker", "info").lowercased()
        return !out.isEmpty && !out.contains("error") && !out.contains("cannot connect")
    }

    // MARK: Container Control

    func start() {
        let configured = configuredContainers
        guard !configured.isEmpty else { return }

        for i in configured {
            let name = containerName(at: i)
            let running = runningContainers.contains(i)
            _ = running ? run("docker", "restart", name) : run("docker", "start", name)
        }
    }

    func stop() {
        for i in runningContainers {
            _ = run("docker", "stop", containerName(at: i))
        }
    }

    func restartOne(at index: Int) {
        let name = containerName(at: index)
        let running = runningContainers.contains(index)
        _ = running ? run("docker", "restart", name) : run("docker", "start", name)
    }

    func stopOne(at index: Int) {
        _ = run("docker", "stop", containerName(at: index))
    }

    // MARK: Per-Container Stats

    var perContainerStats: [ContainerStats] {
        let configured = configuredContainers
        let running = runningContainers

        return configured.map { index in
            let name = containerName(at: index)
            let isRunning = running.contains(index)

            var connected = 0
            var connecting = 0
            var up = "-"
            var down = "-"
            var uptime = "-"

            if isRunning {
                if let line = recentStatsLine(for: name) {
                    connected = extractInt(from: line, after: "Connected: ")
                    connecting = extractInt(from: line, after: "Connecting: ")
                    up = extractValue(from: line, after: "Up: ")
                    down = extractValue(from: line, after: "Down: ")
                }

                let status = run("docker", "ps", "--format", "{{.Status}}", "--filter", "name=^\(name)$")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if status.lowercased().hasPrefix("up ") {
                    uptime = formatUptime(String(status.dropFirst(3)))
                }
            }

            // Fetch Node ID from volume (private key fetched on-demand for QR codes)
            let (nodeId, _) = fetchNodeIdAndKey(for: name)

            return ContainerStats(
                index: index,
                name: name,
                running: isRunning,
                connected: connected,
                connecting: connecting,
                up: up,
                down: down,
                uptime: uptime,
                nodeId: nodeId
            )
        }
    }

    /// Fetch private key on-demand for QR code generation (minimizes time in memory)
    func fetchPrivateKey(for container: String) -> String {
        let (_, privateKey) = fetchNodeIdAndKey(for: container)
        return privateKey
    }

    /// Fetch Node ID and private key from conduit_key.json in Docker volume
    /// Returns (nodeId, privateKey) tuple - nodeId is derived, privateKey is the raw base64 for QR codes
    private func fetchNodeIdAndKey(for container: String) -> (nodeId: String, privateKey: String) {
        // Determine volume name based on container name
        let volumeName: String
        if container == baseContainer {
            volumeName = "conduit-data"
        } else if container.hasPrefix("\(baseContainer)-") {
            let suffix = container.dropFirst(baseContainer.count + 1)  // e.g., "2" from "conduit-mac-2"
            volumeName = "conduit-data-\(suffix)"
        } else {
            return ("", "")
        }

        // Read conduit_key.json from the Docker volume using alpine container
        let keyContent = run("docker", "run", "--rm", "-v", "\(volumeName):/data", "alpine", "cat", "/data/conduit_key.json")

        guard !keyContent.isEmpty else { return ("", "") }

        // Extract privateKeyBase64 from JSON
        // Format: {"privateKeyBase64":"BASE64STRING"}
        guard let range = keyContent.range(of: "\"privateKeyBase64\"") else { return ("", "") }
        let afterKey = keyContent[range.upperBound...]

        // Find the value between quotes after the colon
        guard let colonRange = afterKey.range(of: ":") else { return ("", "") }
        let afterColon = afterKey[colonRange.upperBound...]
        guard let openQuote = afterColon.firstIndex(of: "\"") else { return ("", "") }
        let afterOpenQuote = afterColon[afterColon.index(after: openQuote)...]
        guard let closeQuote = afterOpenQuote.firstIndex(of: "\"") else { return ("", "") }

        let privateKey = String(afterOpenQuote[..<closeQuote])

        // Match bash script's lenient base64 decoding behavior:
        // When base64 string lacks padding, bash's `base64 -d` truncates to complete 4-char groups.
        // For an 86-char string (remainder 2), bash decodes only 84 chars (63 bytes).
        // We replicate this by truncating to the nearest multiple of 4.
        let truncatedLength = (privateKey.count / 4) * 4
        let truncatedKey = String(privateKey.prefix(truncatedLength))

        // Decode truncated base64 (no padding needed since length is multiple of 4)
        guard let keyData = Data(base64Encoded: truncatedKey), keyData.count >= 32 else { return ("", privateKey) }

        // Take last 32 bytes, re-encode as base64, remove padding
        let last32Bytes = keyData.suffix(32)
        let nodeId = last32Bytes.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")

        return (nodeId, privateKey)
    }

    // MARK: Fast Initial Query (minimal Docker calls)

    /// Quick query that only gets container names and running status - for fast initial load
    var quickContainerList: [ContainerStats] {
        let configured = configuredContainers
        let running = runningContainers

        return configured.map { index in
            let name = containerName(at: index)
            let isRunning = running.contains(index)
            return ContainerStats(
                index: index,
                name: name,
                running: isRunning,
                connected: 0,
                connecting: 0,
                up: "-",
                down: "-",
                uptime: "-",
                nodeId: ""
            )
        }
    }

    // MARK: Aggregated Stats (from all running containers)

    var stats: (connected: Int, connecting: Int)? {
        let running = runningContainers
        guard !running.isEmpty else { return nil }

        var totalConnected = 0
        var totalConnecting = 0

        for i in running {
            if let line = recentStatsLine(for: containerName(at: i)) {
                totalConnected += extractInt(from: line, after: "Connected: ")
                totalConnecting += extractInt(from: line, after: "Connecting: ")
            }
        }

        return (totalConnected, totalConnecting)
    }

    var traffic: (up: String, down: String)? {
        let running = runningContainers
        guard !running.isEmpty else { return nil }

        var totalUpBytes: Int64 = 0
        var totalDownBytes: Int64 = 0

        for i in running {
            if let line = recentStatsLine(for: containerName(at: i)) {
                totalUpBytes += parseBytes(extractValue(from: line, after: "Up: "))
                totalDownBytes += parseBytes(extractValue(from: line, after: "Down: "))
            }
        }

        guard totalUpBytes > 0 || totalDownBytes > 0 else { return nil }

        return (formatBytes(totalUpBytes), formatBytes(totalDownBytes))
    }

    var uptime: String? {
        let running = runningContainers
        guard !running.isEmpty else { return nil }

        let status = run("docker", "ps", "--format", "{{.Status}}", "--filter", "name=^\(baseContainer)$")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard status.lowercased().hasPrefix("up ") else { return nil }

        return formatUptime(String(status.dropFirst(3)))
    }

    /// Health status for the overall system (simplified: only Healthy/Unhealthy)
    enum HealthStatus {
        case healthy
        case unhealthy
        case unknown

        var icon: String {
            switch self {
            case .healthy: return "●"
            case .unhealthy: return "○"
            case .unknown: return "○"
            }
        }

        var color: NSColor {
            switch self {
            case .healthy: return .systemGreen
            case .unhealthy: return .systemRed
            case .unknown: return .secondaryLabelColor
            }
        }

        var description: String {
            switch self {
            case .healthy: return "Healthy"
            case .unhealthy: return "Unhealthy"
            case .unknown: return "Unknown"
            }
        }
    }

    var healthStatus: HealthStatus {
        let configured = configuredContainers
        let running = runningContainers

        guard !configured.isEmpty else { return .unknown }
        if running.isEmpty { return .unhealthy }

        // At least one container is running = healthy
        return .healthy
    }

    var config: (maxClients: String, bandwidth: String)? {
        let running = runningContainers
        guard !running.isEmpty else { return nil }

        var totalMaxClients = 0
        var totalBandwidth = 0
        var hasUnlimited = false

        for i in running {
            let args = run("docker", "inspect", "--format", "{{.Args}}", containerName(at: i))
            let maxClients = extractInt(from: args, after: "--max-clients ")
            if maxClients > 0 {
                totalMaxClients += maxClients
            }

            let bw = extractInt(from: args, after: "--bandwidth ")
            if bw == -1 {
                hasUnlimited = true
            } else if bw > 0 {
                totalBandwidth += bw
            }
        }

        let bandwidthStr: String
        if hasUnlimited {
            bandwidthStr = "Unlimited"
        } else if totalBandwidth > 0 {
            bandwidthStr = "\(totalBandwidth) Mbps"
        } else {
            bandwidthStr = "-"
        }

        return (totalMaxClients > 0 ? "\(totalMaxClients)" : "-", bandwidthStr)
    }

    // MARK: Logs and Health

    /// Get recent logs from all running containers (combined, sorted by time)
    func recentLogs(limit: Int = 50) -> [String] {
        let running = runningContainers
        guard !running.isEmpty else { return [] }

        // Collect logs with timestamp and container info
        var allLogs: [(timestamp: String, container: String, line: String)] = []

        // Get more logs per container to ensure we have enough after merging
        let perContainerLimit = limit

        for i in running {
            let name = containerName(at: i)
            let logs = run("docker", "logs", "--tail", "\(perContainerLimit)", "--timestamps", name)
            let lines = logs.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

            for line in lines {
                // Extract timestamp (format: 2026-01-29T21:34:03.123456789Z)
                // Timestamp is at the start of the line before the first space
                let parts = line.split(separator: " ", maxSplits: 1)
                let timestamp = parts.count > 0 ? String(parts[0]) : ""
                allLogs.append((timestamp: timestamp, container: name, line: line))
            }
        }

        // Sort by timestamp (ISO format sorts correctly as strings)
        let sorted = allLogs.sorted { $0.timestamp < $1.timestamp }

        // Take the last N entries and format with container prefix
        return sorted.suffix(limit).map { entry in
            "[\(entry.container)] \(entry.line)"
        }
    }

    /// Get Docker system info summary for health check
    var dockerInfoSummary: String {
        let info = run("docker", "info", "--format",
            "Server Version: {{.ServerVersion}}\nContainers: {{.Containers}} (Running: {{.ContainersRunning}})\nImages: {{.Images}}\nMemory: {{.MemTotal}}\nCPUs: {{.NCPU}}")
        return info.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    private func recentStatsLine(for container: String) -> String? {
        run("docker", "logs", "--tail", "50", container)
            .components(separatedBy: "\n")
            .reversed()
            .first { $0.contains("[STATS]") }
    }

    private func extractInt(from text: String, after prefix: String) -> Int {
        guard let range = text.range(of: prefix) else { return 0 }
        var num = ""
        for char in text[range.upperBound...] {
            if char.isNumber || (char == "-" && num.isEmpty) { num.append(char) }
            else { break }
        }
        return Int(num) ?? 0
    }

    private func extractValue(from text: String, after prefix: String) -> String {
        guard let range = text.range(of: prefix) else { return "-" }
        let rest = String(text[range.upperBound...])
        if let pipe = rest.firstIndex(of: "|") {
            return String(rest[..<pipe]).trimmingCharacters(in: .whitespaces)
        }
        let parts = rest.components(separatedBy: " ")
        return parts.count >= 2 ? "\(parts[0]) \(parts[1])" : rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatUptime(_ raw: String) -> String {
        raw.replacingOccurrences(of: "About ", with: "~")
            .replacingOccurrences(of: "an hour", with: "1h")
            .replacingOccurrences(of: "a minute", with: "1m")
            .replacingOccurrences(of: " seconds", with: "s")
            .replacingOccurrences(of: " second", with: "s")
            .replacingOccurrences(of: " minutes", with: "m")
            .replacingOccurrences(of: " minute", with: "m")
            .replacingOccurrences(of: " hours", with: "h")
            .replacingOccurrences(of: " hour", with: "h")
            .replacingOccurrences(of: " days", with: "d")
            .replacingOccurrences(of: " day", with: "d")
            .replacingOccurrences(of: " weeks", with: "w")
            .replacingOccurrences(of: " week", with: "w")
    }

    private func parseBytes(_ str: String) -> Int64 {
        let trimmed = str.trimmingCharacters(in: .whitespaces).uppercased()
        let multipliers: [(String, Int64)] = [
            ("TB", 1024 * 1024 * 1024 * 1024),
            ("GB", 1024 * 1024 * 1024),
            ("MB", 1024 * 1024),
            ("KB", 1024),
            ("B", 1)
        ]

        for (suffix, multiplier) in multipliers {
            if trimmed.hasSuffix(suffix) {
                let numPart = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
                if let num = Double(numPart) {
                    return Int64(num * Double(multiplier))
                }
            }
        }
        return 0
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        } else {
            return String(format: "%.1f %@", value, units[unitIndex])
        }
    }

    private let dockerPaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker"
    ]

    private func run(_ command: String, _ args: String...) -> String {
        let process = Process()
        let pipe = Pipe()

        let path = command == "docker"
            ? dockerPaths.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/local/bin/docker"
            : "/usr/bin/env"

        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = command == "docker" ? Array(args) : [command] + args
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
