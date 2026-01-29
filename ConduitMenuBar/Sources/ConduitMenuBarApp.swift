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

    private let version = "2.0.5"
    private var statusItem: NSStatusItem?
    private var manager: ConduitManager?
    private var timer: Timer?
    private var isUpdating = false  // Prevent concurrent updates

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
        setupMenu()

        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
        updateStatus()
    }

    // MARK: Menu Setup

    private func setupMenu() {
        let menu = NSMenu()

        // Status section
        menu.addItem(infoItem("○ Conduit: Checking...", tag: 100))
        menu.addItem(infoItem("", tag: 101, hidden: true))  // Docker helper message
        menu.addItem(infoItem("Clients: -", tag: 102))
        menu.addItem(infoItem("Traffic: -", tag: 103))
        // Uptime removed from main view - shown per-container in submenu only
        menu.addItem(.separator())

        // Per-container stats section (hidden by default, shown when multiple containers)
        // Tag 500-504 reserved for container stats items (dynamically created)
        let containerStatsItem = NSMenuItem(title: "Per-Container Stats", action: nil, keyEquivalent: "")
        containerStatsItem.tag = 500
        containerStatsItem.isHidden = true
        let containerStatsSubmenu = NSMenu()
        containerStatsItem.submenu = containerStatsSubmenu
        menu.addItem(containerStatsItem)
        menu.addItem(NSMenuItem.separator())

        // Controls
        menu.addItem(actionItem("▶ Start All", action: #selector(startConduit), key: "s", tag: 200))
        menu.addItem(actionItem("■ Stop All", action: #selector(stopConduit), key: "x", tag: 201))

        // Per-container control submenu (hidden when single container)
        let restartOneItem = NSMenuItem(title: "↻ Restart One...", action: nil, keyEquivalent: "")
        restartOneItem.tag = 210
        restartOneItem.isHidden = true
        restartOneItem.submenu = NSMenu()
        menu.addItem(restartOneItem)

        let stopOneItem = NSMenuItem(title: "■ Stop One...", action: nil, keyEquivalent: "")
        stopOneItem.tag = 211
        stopOneItem.isHidden = true
        stopOneItem.submenu = NSMenu()
        menu.addItem(stopOneItem)

        menu.addItem(.separator())

        // Utilities
        menu.addItem(actionItem("Download Docker Desktop...", action: #selector(openDockerDownload), tag: 300, hidden: true))

        // Main terminal action - opens in default terminal
        menu.addItem(actionItem("Open Terminal Manager...", action: #selector(openTerminalDefault), key: "t", tag: 305))

        // Terminal preference submenu
        let terminalPrefItem = NSMenuItem(title: "Terminal App", action: nil, keyEquivalent: "")
        let terminalSubmenu = NSMenu()
        for app in TerminalApp.allCases where app.isInstalled {
            let item = NSMenuItem(title: app.rawValue, action: #selector(setTerminalPreference(_:)), keyEquivalent: "")
            item.representedObject = app
            item.state = (app == preferredTerminal) ? .on : .off
            terminalSubmenu.addItem(item)
        }
        terminalPrefItem.submenu = terminalSubmenu
        terminalPrefItem.tag = 306
        menu.addItem(terminalPrefItem)

        let scriptPath = findScript() ?? "~/conduit-manager/conduit-mac.sh"
        menu.addItem(actionItem("Path: \(scriptPath)", action: #selector(copyPath), tag: 301))
        menu.addItem(.separator())

        // Config info
        menu.addItem(infoItem("Max Clients: -", tag: 401))
        menu.addItem(infoItem("Bandwidth: -", tag: 402))
        menu.addItem(.separator())

        // Footer
        let versionItem = NSMenuItem(title: "Version \(version)", action: nil, keyEquivalent: "")
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

    /// Updates an info item's label text and color
    private func updateInfo(_ item: NSMenuItem, _ title: String, _ color: NSColor = .labelColor) {
        guard let label = item.view?.subviews.first as? NSTextField else { return }
        label.stringValue = title
        label.textColor = color
    }

    // MARK: Status Updates

    private func updateStatus() {
        // Prevent concurrent updates if previous one is still running
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        guard let manager = manager, let menu = statusItem?.menu else { return }

        let docker = manager.dockerStatus
        let running = docker == .running && manager.isRunning
        let count = manager.containerCount

        // Update icon
        updateIcon(docker: docker, running: running)

        // Status line (100)
        if let item = menu.item(withTag: 100) {
            switch docker {
            case .notInstalled: updateInfo(item, "⚠ Docker Not Installed", .systemOrange)
            case .notRunning:   updateInfo(item, "⚠ Docker Not Running", .systemOrange)
            case .running:
                if running {
                    if count.total > 1 {
                        updateInfo(item, "● Conduit: Running (\(count.running)/\(count.total))", .systemGreen)
                    } else {
                        updateInfo(item, "● Conduit: Running", .systemGreen)
                    }
                } else {
                    updateInfo(item, "○ Conduit: Stopped", .secondaryLabelColor)
                }
            }
        }

        // Docker helper (101)
        if let item = menu.item(withTag: 101) {
            switch docker {
            case .notInstalled:
                updateInfo(item, "   Install Docker Desktop to use Conduit", .secondaryLabelColor)
                item.isHidden = false
            case .notRunning:
                updateInfo(item, "   Please start Docker Desktop", .secondaryLabelColor)
                item.isHidden = false
            case .running:
                item.isHidden = true
            }
        }

        // Stats (102-104) - show aggregated totals
        updateStatsItems(menu: menu, running: running, docker: docker)

        // Per-container stats submenu (500)
        updatePerContainerStats(menu: menu, docker: docker)

        // Per-container controls (210, 211)
        updatePerContainerControls(menu: menu, docker: docker)

        // Controls (200-201)
        menu.item(withTag: 200)?.title = running ? "↻ Restart All" : "▶ Start All"
        menu.item(withTag: 200)?.isEnabled = docker == .running

        // Update button titles based on container count
        if count.total > 1 {
            menu.item(withTag: 200)?.title = running ? "↻ Restart All" : "▶ Start All"
            menu.item(withTag: 201)?.title = "■ Stop All"
        } else {
            menu.item(withTag: 200)?.title = running ? "↻ Restart" : "▶ Start"
            menu.item(withTag: 201)?.title = "■ Stop"
        }

        menu.item(withTag: 201)?.isEnabled = running

        // Docker download (300)
        menu.item(withTag: 300)?.isHidden = docker != .notInstalled

        // Config (401-402)
        updateConfigItems(menu: menu, docker: docker)
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

    private func updateStatsItems(menu: NSMenu, running: Bool, docker: DockerStatus) {
        // Clients (102) - aggregated total
        if let item = menu.item(withTag: 102) {
            if running, let stats = manager?.stats {
                let text = stats.connecting > 0
                    ? "Clients: \(stats.connected) connected (\(stats.connecting) connecting)"
                    : "Clients: \(stats.connected) connected"
                updateInfo(item, text)
            } else {
                updateInfo(item, "Clients: -")
            }
            item.isHidden = docker != .running
        }

        // Traffic (103) - aggregated total
        if let item = menu.item(withTag: 103) {
            if running, let traffic = manager?.traffic {
                updateInfo(item, "Traffic: ↑ \(traffic.up)  ↓ \(traffic.down)")
            } else {
                updateInfo(item, "Traffic: -")
            }
            item.isHidden = docker != .running
        }
        // Uptime removed from main view - shown per-container in submenu only
    }

    private func updatePerContainerStats(menu: NSMenu, docker: DockerStatus) {
        guard let manager = manager, let item = menu.item(withTag: 500) else { return }

        let count = manager.containerCount
        let hasMultiple = count.total > 1

        item.isHidden = !hasMultiple || docker != .running

        guard hasMultiple, docker == .running, let submenu = item.submenu else { return }

        // Rebuild submenu with current stats
        submenu.removeAllItems()

        let containerStats = manager.perContainerStats

        for stat in containerStats {
            let statusIcon = stat.running ? "●" : "○"
            let statusText = stat.running ? "Running" : "Stopped"
            let statusColor: NSColor = stat.running ? .systemGreen : .secondaryLabelColor

            // Container header with custom view to avoid grey appearance
            let headerItem = submenuInfoItem("\(statusIcon) \(stat.name) (\(statusText))", color: statusColor, bold: true)
            submenu.addItem(headerItem)

            if stat.running {
                // Stats for this container
                let clientText = stat.connecting > 0
                    ? "Clients: \(stat.connected) (\(stat.connecting) connecting)"
                    : "Clients: \(stat.connected)"
                submenu.addItem(submenuInfoItem(clientText))
                submenu.addItem(submenuInfoItem("Traffic: ↑ \(stat.up)  ↓ \(stat.down)"))
                submenu.addItem(submenuInfoItem("Uptime: \(stat.uptime)"))
            }

            submenu.addItem(.separator())
        }

        // Remove trailing separator if present
        if submenu.items.last?.isSeparatorItem == true {
            submenu.removeItem(at: submenu.items.count - 1)
        }
    }

    /// Creates a non-clickable submenu item with custom view (not greyed out)
    private func submenuInfoItem(_ title: String, color: NSColor = .labelColor, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()

        let label = NSTextField(labelWithString: title)
        label.font = bold ? .boldSystemFont(ofSize: 13) : .menuFont(ofSize: 13)
        label.textColor = color
        label.frame = NSRect(x: 8, y: 0, width: 260, height: 18)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 18))
        container.addSubview(label)
        item.view = container

        return item
    }

    private func updatePerContainerControls(menu: NSMenu, docker: DockerStatus) {
        guard let manager = manager else { return }

        let count = manager.containerCount
        let hasMultiple = count.total > 1

        // Restart One submenu (210)
        if let restartItem = menu.item(withTag: 210) {
            restartItem.isHidden = !hasMultiple || docker != .running

            if hasMultiple, docker == .running, let submenu = restartItem.submenu {
                submenu.removeAllItems()

                for stat in manager.perContainerStats {
                    let statusIcon = stat.running ? "●" : "○"
                    let item = NSMenuItem(
                        title: "\(statusIcon) \(stat.name)",
                        action: #selector(restartContainer(_:)),
                        keyEquivalent: ""
                    )
                    item.representedObject = stat.index
                    item.target = self
                    submenu.addItem(item)
                }
            }
        }

        // Stop One submenu (211)
        if let stopItem = menu.item(withTag: 211) {
            let anyRunning = manager.perContainerStats.contains { $0.running }
            stopItem.isHidden = !hasMultiple || docker != .running || !anyRunning

            if hasMultiple, docker == .running, let submenu = stopItem.submenu {
                submenu.removeAllItems()

                for stat in manager.perContainerStats where stat.running {
                    let item = NSMenuItem(
                        title: "● \(stat.name)",
                        action: #selector(stopContainer(_:)),
                        keyEquivalent: ""
                    )
                    item.representedObject = stat.index
                    item.target = self
                    submenu.addItem(item)
                }
            }
        }
    }

    private func updateConfigItems(menu: NSMenu, docker: DockerStatus) {
        let config = docker == .running ? manager?.config : nil

        if let item = menu.item(withTag: 401) {
            updateInfo(item, "Max Clients: \(config?.maxClients ?? "-")")
            item.isHidden = docker != .running
        }
        if let item = menu.item(withTag: 402) {
            updateInfo(item, "Bandwidth: \(config?.bandwidth ?? "-")")
            item.isHidden = docker != .running
        }
    }

    // MARK: Actions

    @objc private func startConduit() {
        guard let manager = manager else { return }
        guard manager.dockerStatus == .running else {
            notify("Conduit", "Please start Docker Desktop first")
            return
        }
        manager.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.updateStatus() }
        notify("Conduit", "Starting Conduit service...")
    }

    @objc private func stopConduit() {
        manager?.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.updateStatus() }
        notify("Conduit", "Conduit service stopped")
    }

    @objc private func restartContainer(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, let manager = manager else { return }
        let name = manager.containerNameForIndex(index)
        manager.restartOne(at: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.updateStatus() }
        notify("Conduit", "Restarting \(name)...")
    }

    @objc private func stopContainer(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, let manager = manager else { return }
        let name = manager.containerNameForIndex(index)
        manager.stopOne(at: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.updateStatus() }
        notify("Conduit", "\(name) stopped")
    }

    @objc private func openDockerDownload() {
        NSWorkspace.shared.open(URL(string: "https://www.docker.com/products/docker-desktop/")!)
    }

    @objc private func copyPath() {
        let path = findScript() ?? "~/conduit-manager/conduit-mac.sh"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        notify("Copied", "Script path copied to clipboard")
    }

    @objc private func openTerminalDefault() {
        openInTerminal(preferredTerminal)
    }

    @objc private func setTerminalPreference(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? TerminalApp else { return }
        preferredTerminal = app
        updateTerminalMenu()
    }

    private func openInTerminal(_ app: TerminalApp) {
        guard let path = findScript() else {
            notify("Error", "Conduit script not found")
            return
        }

        let script: String
        switch app {
        case .terminal:
            // Always open new window for clean state
            script = """
                tell application "Terminal"
                    do script "\(path)"
                    activate
                end tell
                """
        case .iterm:
            // Always open new window
            script = """
                tell application "iTerm"
                    create window with default profile
                    tell current window
                        tell current session to write text "\(path)"
                    end tell
                    activate
                end tell
                """
        }
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    private func updateTerminalMenu() {
        guard let menu = statusItem?.menu,
              let terminalPrefItem = menu.item(withTag: 306),
              let submenu = terminalPrefItem.submenu else { return }

        // Update checkmarks
        for item in submenu.items {
            if let app = item.representedObject as? TerminalApp {
                item.state = (app == preferredTerminal) ? .on : .off
            }
        }
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
            // Use exact match to avoid "conduit-mac" matching "conduit-mac-2"
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
            // Use exact match to avoid "conduit-mac" matching "conduit-mac-2"
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

            return ContainerStats(
                index: index,
                name: name,
                running: isRunning,
                connected: connected,
                connecting: connecting,
                up: up,
                down: down,
                uptime: uptime
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

        // Aggregate traffic from all running containers
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
        // Show oldest container's uptime (the one that's been running longest)
        let running = runningContainers
        guard !running.isEmpty else { return nil }

        // Use primary container's uptime for simplicity
        let status = run("docker", "ps", "--format", "{{.Status}}", "--filter", "name=^\(baseContainer)$")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard status.lowercased().hasPrefix("up ") else { return nil }

        return formatUptime(String(status.dropFirst(3)))
    }

    var config: (maxClients: String, bandwidth: String)? {
        // Aggregate max clients and bandwidth from all containers
        let configured = configuredContainers
        guard !configured.isEmpty else { return nil }

        var totalMaxClients = 0
        var totalBandwidth = 0
        var hasUnlimited = false

        for i in configured {
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
