/// Psiphon Conduit Menu Bar App for macOS
/// A lightweight menu bar app to control the Psiphon Conduit Docker container.

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

    private let version = "1.6.1"
    private var statusItem: NSStatusItem?
    private var manager: ConduitManager?
    private var timer: Timer?

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
        menu.addItem(infoItem("Uptime: -", tag: 104))
        menu.addItem(.separator())

        // Controls
        menu.addItem(actionItem("▶ Start", action: #selector(startConduit), key: "s", tag: 200))
        menu.addItem(actionItem("■ Stop", action: #selector(stopConduit), key: "x", tag: 201))
        menu.addItem(.separator())

        // Utilities
        menu.addItem(actionItem("Download Docker Desktop...", action: #selector(openDockerDownload), tag: 300, hidden: true))

        // Terminal submenu
        let terminalItem = NSMenuItem(title: "Open Terminal Manager", action: nil, keyEquivalent: "t")
        let terminalSubmenu = NSMenu()
        for app in TerminalApp.allCases where app.isInstalled {
            let item = NSMenuItem(title: "Open in \(app.rawValue)", action: #selector(openInTerminal(_:)), keyEquivalent: "")
            item.representedObject = app
            item.state = (app == preferredTerminal) ? .on : .off
            terminalSubmenu.addItem(item)
        }
        terminalSubmenu.addItem(.separator())
        let defaultItem = NSMenuItem(title: "Default: \(preferredTerminal.rawValue)", action: nil, keyEquivalent: "")
        defaultItem.isEnabled = false
        defaultItem.tag = 310
        terminalSubmenu.addItem(defaultItem)
        terminalItem.submenu = terminalSubmenu
        terminalItem.tag = 305
        menu.addItem(terminalItem)

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
        guard let manager = manager, let menu = statusItem?.menu else { return }

        let docker = manager.dockerStatus
        let running = docker == .running && manager.isRunning

        // Update icon
        updateIcon(docker: docker, running: running)

        // Status line (100)
        if let item = menu.item(withTag: 100) {
            switch docker {
            case .notInstalled: updateInfo(item, "⚠ Docker Not Installed", .systemOrange)
            case .notRunning:   updateInfo(item, "⚠ Docker Not Running", .systemOrange)
            case .running:      updateInfo(item, running ? "● Conduit: Running" : "○ Conduit: Stopped",
                                           running ? .systemGreen : .secondaryLabelColor)
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

        // Stats (102-104)
        updateStatsItems(menu: menu, running: running, docker: docker)

        // Controls (200-201)
        menu.item(withTag: 200)?.title = running ? "↻ Restart" : "▶ Start"
        menu.item(withTag: 200)?.isEnabled = docker == .running
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
        // Clients (102)
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

        // Traffic (103)
        if let item = menu.item(withTag: 103) {
            if running, let traffic = manager?.traffic {
                updateInfo(item, "Traffic: ↑ \(traffic.up)  ↓ \(traffic.down)")
            } else {
                updateInfo(item, "Traffic: -")
            }
            item.isHidden = docker != .running
        }

        // Uptime (104)
        if let item = menu.item(withTag: 104) {
            if running, let uptime = manager?.uptime {
                updateInfo(item, "Uptime: \(uptime)")
            } else {
                updateInfo(item, "Uptime: -")
            }
            item.isHidden = docker != .running
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

    @objc private func openDockerDownload() {
        NSWorkspace.shared.open(URL(string: "https://www.docker.com/products/docker-desktop/")!)
    }

    @objc private func copyPath() {
        let path = findScript() ?? "~/conduit-manager/conduit-mac.sh"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        notify("Copied", "Script path copied to clipboard")
    }

    @objc private func openInTerminal(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? TerminalApp else { return }
        guard let path = findScript() else {
            notify("Error", "Conduit script not found")
            return
        }

        // Save as new default
        preferredTerminal = app
        updateTerminalMenu()

        let script: String
        switch app {
        case .terminal:
            // Reuse existing window if possible, otherwise create new
            script = """
                tell application "Terminal"
                    if (count of windows) > 0 then
                        do script "\(path)" in front window
                    else
                        do script "\(path)"
                    end if
                    activate
                end tell
                """
        case .iterm:
            script = """
                tell application "iTerm"
                    activate
                    if (count of windows) > 0 then
                        tell current window
                            create tab with default profile
                            tell current session to write text "\(path)"
                        end tell
                    else
                        create window with default profile
                        tell current window
                            tell current session to write text "\(path)"
                        end tell
                    end if
                end tell
                """
        }
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    private func updateTerminalMenu() {
        guard let menu = statusItem?.menu,
              let terminalItem = menu.item(withTag: 305),
              let submenu = terminalItem.submenu else { return }

        // Update checkmarks
        for item in submenu.items {
            if let app = item.representedObject as? TerminalApp {
                item.state = (app == preferredTerminal) ? .on : .off
            }
        }
        // Update default label
        if let defaultItem = submenu.item(withTag: 310) {
            defaultItem.title = "Default: \(preferredTerminal.rawValue)"
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

// MARK: - Conduit Manager

class ConduitManager {

    private let container = "conduit-mac"

    // MARK: Status

    var dockerStatus: DockerStatus {
        guard isDockerInstalled else { return .notInstalled }
        guard isDockerRunning else { return .notRunning }
        return .running
    }

    var isRunning: Bool {
        run("docker", "ps", "--format", "{{.Names}}").contains(container)
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
        let all = run("docker", "ps", "-a", "--format", "{{.Names}}")
        if all.contains(container) {
            _ = isRunning ? run("docker", "restart", container) : run("docker", "start", container)
        }
    }

    func stop() { _ = run("docker", "stop", container) }

    // MARK: Stats

    var stats: (connected: Int, connecting: Int)? {
        guard let line = recentStatsLine else { return nil }
        return (extractInt(from: line, after: "Connected: "),
                extractInt(from: line, after: "Connecting: "))
    }

    var traffic: (up: String, down: String)? {
        guard let line = recentStatsLine else { return nil }
        let up = extractValue(from: line, after: "Up: ")
        let down = extractValue(from: line, after: "Down: ")
        guard up != "-" || down != "-" else { return nil }
        return (up, down)
    }

    var uptime: String? {
        let status = run("docker", "ps", "--format", "{{.Status}}", "--filter", "name=\(container)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard status.lowercased().hasPrefix("up ") else { return nil }

        return String(status.dropFirst(3))
            .replacingOccurrences(of: "About ", with: "~")
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

    var config: (maxClients: String, bandwidth: String)? {
        let args = run("docker", "inspect", "--format", "{{.Args}}", container)
        let maxClients = extractInt(from: args, after: "--max-clients ")
        let bw = extractInt(from: args, after: "--bandwidth ")
        return (maxClients > 0 ? "\(maxClients)" : "-",
                bw == -1 ? "Unlimited" : bw > 0 ? "\(bw) Mbps" : "-")
    }

    // MARK: Helpers

    private var recentStatsLine: String? {
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
