// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║                    PSIPHON CONDUIT MENU BAR APP                           ║
// ║                         For macOS                                         ║
// ╠═══════════════════════════════════════════════════════════════════════════╣
// ║  A lightweight menu bar app to control the Psiphon Conduit Docker         ║
// ║  container. Provides quick access to start/stop the service, view         ║
// ║  connection stats, and monitor traffic.                                   ║
// ║                                                                           ║
// ║  Features:                                                                ║
// ║    - Real-time status monitoring (updates every 5 seconds)                ║
// ║    - Docker Desktop detection with helpful messages                       ║
// ║    - Start/Stop/Restart container controls                                ║
// ║    - Live client connection count                                         ║
// ║    - Upload/Download traffic statistics                                   ║
// ║    - Quick access to terminal manager                                     ║
// ║    - Modern UserNotifications for alerts                                  ║
// ║                                                                           ║
// ║  Requirements:                                                            ║
// ║    - macOS 11.0+ (Big Sur or later)                                       ║
// ║    - Docker Desktop installed and running                                 ║
// ║    - Conduit container created via conduit-mac.sh                         ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

import SwiftUI
import AppKit
import UserNotifications

// MARK: - Main App Entry Point

/// The main SwiftUI app structure.
/// Uses NSApplicationDelegateAdaptor to bridge to AppKit for menu bar functionality.
@main
struct ConduitMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty scene - this is a menu bar-only app with no main window
        Settings {
            EmptyView()
        }
    }
}

// MARK: - Docker Status Enum

/// Represents the three possible states of Docker on the system.
/// Used to determine what UI elements to show and what actions are available.
enum DockerStatus {
    case notInstalled  // Docker CLI binary not found
    case notRunning    // Docker installed but daemon not responding
    case running       // Docker fully operational
}

// MARK: - App Delegate

/// Main controller for the menu bar app.
/// Handles menu setup, status updates, and user interactions.
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Properties

    /// App version - displayed in menu
    let appVersion = "1.5.8"

    /// The status bar item that appears in the macOS menu bar
    var statusItem: NSStatusItem?

    /// Manager class that handles Docker and container operations
    var conduitManager: ConduitManager?

    /// Timer for periodic status updates (every 5 seconds)
    var updateTimer: Timer?

    // MARK: App Lifecycle

    /// Called when the app finishes launching.
    /// Sets up the menu bar item, initializes the manager, and starts the update timer.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon - this is a menu bar-only app
        NSApp.setActivationPolicy(.accessory)

        // Request notification permissions for alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Create the status bar item with variable width to accommodate different icon sizes
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Initialize the Docker/container manager
        conduitManager = ConduitManager()

        // Build the dropdown menu
        setupMenu()

        // Start polling for status updates every 5 seconds
        updateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }

        // Perform initial status check immediately
        updateStatus()
    }

    // MARK: Menu Setup

    /// Helper to create a non-interactive menu item that doesn't appear grayed out
    func createInfoMenuItem(title: String, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ])
        item.tag = tag
        return item
    }

    /// Helper to update an info menu item's attributed title
    func updateInfoMenuItem(_ item: NSMenuItem, title: String, color: NSColor = .labelColor) {
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: color
        ])
    }

    /// Builds the dropdown menu with all items.
    /// Menu items are tagged with IDs for later updates.
    func setupMenu() {
        let menu = NSMenu()

        // --- Status Section ---

        // Main status line (tag 100)
        let statusItem = createInfoMenuItem(title: "○ Conduit: Checking...", tag: 100)
        menu.addItem(statusItem)

        // Docker status message - hidden unless Docker has issues (tag 101)
        let dockerItem = createInfoMenuItem(title: "", tag: 101)
        dockerItem.isHidden = true
        menu.addItem(dockerItem)

        // Client connection count (tag 102)
        let statsItem = createInfoMenuItem(title: "Clients: -", tag: 102)
        menu.addItem(statsItem)

        // Traffic statistics (tag 103)
        let trafficItem = createInfoMenuItem(title: "Traffic: -", tag: 103)
        menu.addItem(trafficItem)

        // Uptime (tag 104)
        let uptimeItem = createInfoMenuItem(title: "Uptime: -", tag: 104)
        menu.addItem(uptimeItem)

        menu.addItem(NSMenuItem.separator())

        // --- Control Section ---

        // Start/Restart button (tag 200) - keyboard shortcut: Cmd+S
        let startItem = NSMenuItem(title: "▶ Start", action: #selector(startConduit), keyEquivalent: "s")
        startItem.tag = 200
        menu.addItem(startItem)

        // Stop button (tag 201) - keyboard shortcut: Cmd+X
        let stopItem = NSMenuItem(title: "■ Stop", action: #selector(stopConduit), keyEquivalent: "x")
        stopItem.tag = 201
        menu.addItem(stopItem)

        menu.addItem(NSMenuItem.separator())

        // --- Utilities Section ---

        // Docker Desktop download link - hidden unless Docker not installed (tag 300)
        let downloadDockerItem = NSMenuItem(title: "Download Docker Desktop...", action: #selector(openDockerDownload), keyEquivalent: "")
        downloadDockerItem.tag = 300
        downloadDockerItem.isHidden = true
        menu.addItem(downloadDockerItem)

        // Open terminal manager - keyboard shortcut: Cmd+T
        menu.addItem(NSMenuItem(title: "Open Terminal Manager...", action: #selector(openTerminal), keyEquivalent: "t"))

        // Script path display - click to copy (tag 301)
        let scriptPath = findConduitScript() ?? "~/conduit-manager/conduit-mac.sh"
        let pathItem = NSMenuItem(title: "Path: \(scriptPath)", action: #selector(copyScriptPath), keyEquivalent: "")
        pathItem.tag = 301
        menu.addItem(pathItem)

        menu.addItem(NSMenuItem.separator())

        // Node ID - click to copy (tag 400)
        let nodeIdItem = NSMenuItem(title: "Node ID: -", action: #selector(copyNodeId), keyEquivalent: "")
        nodeIdItem.tag = 400
        menu.addItem(nodeIdItem)

        // Max clients (tag 401)
        let maxClientsItem = createInfoMenuItem(title: "Max Clients: -", tag: 401)
        menu.addItem(maxClientsItem)

        // Bandwidth limit (tag 402)
        let bandwidthItem = createInfoMenuItem(title: "Bandwidth: -", tag: 402)
        menu.addItem(bandwidthItem)

        menu.addItem(NSMenuItem.separator())

        // Version display
        let versionItem = NSMenuItem(title: "Version \(appVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        // Quit button - keyboard shortcut: Cmd+Q
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        self.statusItem?.menu = menu
    }

    // MARK: Status Updates

    /// Updates all menu items based on current Docker and container status.
    /// Called every 5 seconds by the timer and immediately after user actions.
    func updateStatus() {
        guard let manager = conduitManager else { return }

        // Get current states
        let dockerStatus = manager.getDockerStatus()
        let isRunning = dockerStatus == .running && manager.isContainerRunning()

        // --- Update Menu Bar Icon ---
        if let button = statusItem?.button {
            // Icon selection:
            // - exclamationmark.triangle: Docker issues (template, adapts to light/dark)
            // - antenna.radiowaves.left.and.right: Running (with green accent)
            // - antenna.radiowaves.left.and.right.slash: Stopped (template, adapts to light/dark)
            let symbolName: String
            var useMulticolor = false

            switch dockerStatus {
            case .notInstalled, .notRunning:
                symbolName = "exclamationmark.triangle"
            case .running:
                if isRunning {
                    symbolName = "antenna.radiowaves.left.and.right"
                    useMulticolor = true
                } else {
                    symbolName = "antenna.radiowaves.left.and.right.slash"
                }
            }

            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Conduit") {
                var config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)

                if useMulticolor {
                    // Use hierarchical rendering with green for the "active" state
                    let colorConfig = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
                    config = config.applying(colorConfig)
                }

                if let configuredImage = image.withSymbolConfiguration(config) {
                    // Template mode for proper light/dark adaptation (except multicolor)
                    configuredImage.isTemplate = !useMulticolor
                    button.image = configuredImage
                }
            }
        }

        // --- Update Menu Items ---
        if let menu = statusItem?.menu {

            // Status text (tag 100)
            if let statusMenuItem = menu.item(withTag: 100) {
                switch dockerStatus {
                case .notInstalled:
                    updateInfoMenuItem(statusMenuItem, title: "⚠ Docker Not Installed", color: .systemOrange)
                case .notRunning:
                    updateInfoMenuItem(statusMenuItem, title: "⚠ Docker Not Running", color: .systemOrange)
                case .running:
                    if isRunning {
                        updateInfoMenuItem(statusMenuItem, title: "● Conduit: Running", color: .systemGreen)
                    } else {
                        updateInfoMenuItem(statusMenuItem, title: "○ Conduit: Stopped", color: .secondaryLabelColor)
                    }
                }
            }

            // Docker status helper message (tag 101)
            if let dockerItem = menu.item(withTag: 101) {
                switch dockerStatus {
                case .notInstalled:
                    updateInfoMenuItem(dockerItem, title: "   Install Docker Desktop to use Conduit", color: .secondaryLabelColor)
                    dockerItem.isHidden = false
                case .notRunning:
                    updateInfoMenuItem(dockerItem, title: "   Please start Docker Desktop", color: .secondaryLabelColor)
                    dockerItem.isHidden = false
                case .running:
                    dockerItem.isHidden = true
                }
            }

            // Client stats (tag 102)
            if let statsItem = menu.item(withTag: 102) {
                if isRunning, let stats = manager.getStats() {
                    if stats.connecting > 0 {
                        updateInfoMenuItem(statsItem, title: "Clients: \(stats.connected) connected (\(stats.connecting) connecting)")
                    } else {
                        updateInfoMenuItem(statsItem, title: "Clients: \(stats.connected) connected")
                    }
                    statsItem.isHidden = false
                } else {
                    updateInfoMenuItem(statsItem, title: "Clients: -")
                    statsItem.isHidden = dockerStatus != .running
                }
            }

            // Traffic stats (tag 103)
            if let trafficItem = menu.item(withTag: 103) {
                if isRunning, let traffic = manager.getTraffic() {
                    updateInfoMenuItem(trafficItem, title: "Traffic: ↑ \(traffic.upload)  ↓ \(traffic.download)")
                    trafficItem.isHidden = false
                } else {
                    updateInfoMenuItem(trafficItem, title: "Traffic: -")
                    trafficItem.isHidden = dockerStatus != .running
                }
            }

            // Uptime (tag 104)
            if let uptimeItem = menu.item(withTag: 104) {
                if isRunning, let uptime = manager.getUptime() {
                    updateInfoMenuItem(uptimeItem, title: "Uptime: \(uptime)")
                    uptimeItem.isHidden = false
                } else {
                    updateInfoMenuItem(uptimeItem, title: "Uptime: -")
                    uptimeItem.isHidden = dockerStatus != .running
                }
            }

            // Start/Restart button (tag 200)
            if let startItem = menu.item(withTag: 200) {
                startItem.title = isRunning ? "↻ Restart" : "▶ Start"
                startItem.isEnabled = dockerStatus == .running
            }

            // Stop button (tag 201)
            if let stopItem = menu.item(withTag: 201) {
                stopItem.isEnabled = isRunning
            }

            // Docker download link (tag 300)
            if let downloadItem = menu.item(withTag: 300) {
                downloadItem.isHidden = dockerStatus != .notInstalled
            }

            // Node ID (tag 400)
            if let nodeIdItem = menu.item(withTag: 400) {
                if dockerStatus == .running, let nodeId = manager.getNodeId() {
                    // Truncate for display but store full ID
                    let displayId = nodeId.count > 20 ? String(nodeId.prefix(20)) + "..." : nodeId
                    nodeIdItem.title = "Node ID: \(displayId)"
                    nodeIdItem.isHidden = false
                    nodeIdItem.isEnabled = true
                } else {
                    nodeIdItem.title = "Node ID: -"
                    nodeIdItem.isHidden = dockerStatus != .running
                }
            }

            // Max clients (tag 401)
            if let maxClientsItem = menu.item(withTag: 401) {
                if dockerStatus == .running, let config = manager.getContainerConfig() {
                    updateInfoMenuItem(maxClientsItem, title: "Max Clients: \(config.maxClients)")
                    maxClientsItem.isHidden = false
                } else {
                    updateInfoMenuItem(maxClientsItem, title: "Max Clients: -")
                    maxClientsItem.isHidden = dockerStatus != .running
                }
            }

            // Bandwidth (tag 402)
            if let bandwidthItem = menu.item(withTag: 402) {
                if dockerStatus == .running, let config = manager.getContainerConfig() {
                    updateInfoMenuItem(bandwidthItem, title: "Bandwidth: \(config.bandwidth)")
                    bandwidthItem.isHidden = false
                } else {
                    updateInfoMenuItem(bandwidthItem, title: "Bandwidth: -")
                    bandwidthItem.isHidden = dockerStatus != .running
                }
            }
        }
    }

    // MARK: User Actions

    /// Starts or restarts the Conduit container.
    /// Shows a notification and updates status after a short delay.
    @objc func startConduit() {
        guard let manager = conduitManager else { return }

        // Prevent action if Docker isn't running
        if manager.getDockerStatus() != .running {
            showNotification(title: "Conduit", body: "Please start Docker Desktop first")
            return
        }

        manager.startContainer()

        // Update status after container has time to start
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.updateStatus()
        }
        showNotification(title: "Conduit", body: "Starting Conduit service...")
    }

    /// Stops the Conduit container.
    @objc func stopConduit() {
        conduitManager?.stopContainer()

        // Update status after container stops
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.updateStatus()
        }
        showNotification(title: "Conduit", body: "Conduit service stopped")
    }

    /// Opens the Docker Desktop download page in the default browser.
    @objc func openDockerDownload() {
        if let url = URL(string: "https://www.docker.com/products/docker-desktop/") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Copies the script path to the clipboard.
    @objc func copyScriptPath() {
        let scriptPath = findConduitScript() ?? "~/conduit-manager/conduit-mac.sh"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(scriptPath, forType: .string)
        showNotification(title: "Copied", body: "Script path copied to clipboard")
    }

    /// Copies the Node ID to the clipboard.
    @objc func copyNodeId() {
        if let nodeId = conduitManager?.getNodeId(), !nodeId.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(nodeId, forType: .string)
            showNotification(title: "Copied", body: "Node ID copied to clipboard")
        } else {
            showNotification(title: "Error", body: "Node ID not available")
        }
    }

    /// Opens Terminal and runs the conduit-mac.sh script.
    /// Uses AppleScript to control Terminal.app.
    @objc func openTerminal() {
        let scriptPath = findConduitScript()
        if let path = scriptPath {
            let script = """
            tell application "Terminal"
                activate
                do script "\(path)"
            end tell
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        } else {
            showNotification(title: "Error", body: "Conduit script not found")
        }
    }

    // MARK: Helper Methods

    /// Searches common locations for the conduit-mac.sh script.
    /// Returns the first path found, or nil if not installed.
    func findConduitScript() -> String? {
        let possiblePaths = [
            "\(NSHomeDirectory())/conduit-manager/conduit-mac.sh",  // Default install location
            "/usr/local/bin/conduit",                               // Symlink location
            "\(NSHomeDirectory())/conduit-mac.sh"                   // Legacy location
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Shows a macOS notification using the modern UserNotifications framework.
    /// This ensures the app icon appears correctly in notifications.
    func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // nil trigger = deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Terminates the application.
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Conduit Manager

/// Handles all Docker and container operations.
/// Encapsulates the logic for checking status, starting/stopping containers,
/// and parsing container logs for statistics.
class ConduitManager {

    /// The Docker container name used by conduit-mac.sh
    let containerName = "conduit-mac"

    // MARK: Docker Status

    /// Determines the current Docker status by checking installation and daemon state.
    func getDockerStatus() -> DockerStatus {
        // First check if Docker CLI binary exists
        if !isDockerInstalled() {
            return .notInstalled
        }

        // Then check if Docker daemon is responding
        if !isDockerRunning() {
            return .notRunning
        }

        return .running
    }

    /// Checks if Docker CLI is installed by looking for the binary in common locations.
    func isDockerInstalled() -> Bool {
        let dockerPaths = [
            "/usr/local/bin/docker",                              // Intel Mac default
            "/opt/homebrew/bin/docker",                           // Apple Silicon Homebrew
            "/Applications/Docker.app/Contents/Resources/bin/docker"  // Docker.app bundled
        ]
        return dockerPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Checks if Docker daemon is running by executing `docker info`.
    func isDockerRunning() -> Bool {
        let output = runCommand("docker", arguments: ["info"])
        // Docker info returns error text when daemon isn't running
        return !output.isEmpty &&
               !output.lowercased().contains("error") &&
               !output.lowercased().contains("cannot connect")
    }

    // MARK: Container Operations

    /// Checks if the Conduit container is currently running.
    func isContainerRunning() -> Bool {
        let output = runCommand("docker", arguments: ["ps", "--format", "{{.Names}}"])
        return output.contains(containerName)
    }

    /// Starts the Conduit container if it exists, or restarts it if already running.
    /// Note: If the container doesn't exist, the user must use the terminal script to create it.
    func startContainer() {
        if !isContainerRunning() {
            // Check if container exists but is stopped
            let allContainers = runCommand("docker", arguments: ["ps", "-a", "--format", "{{.Names}}"])
            if allContainers.contains(containerName) {
                _ = runCommand("docker", arguments: ["start", containerName])
            }
            // If container doesn't exist, user needs to use the terminal script to create it
        } else {
            // Container is running - restart it
            _ = runCommand("docker", arguments: ["restart", containerName])
        }
    }

    /// Stops the Conduit container.
    func stopContainer() {
        _ = runCommand("docker", arguments: ["stop", containerName])
    }

    // MARK: Stats Parsing

    /// Parses container logs to extract client connection statistics.
    /// Looks for [STATS] lines in the format: "Connected: X | Connecting: Y"
    func getStats() -> (connected: Int, connecting: Int)? {
        let output = runCommand("docker", arguments: ["logs", "--tail", "50", containerName])

        // Search from most recent log entries
        let lines = output.components(separatedBy: "\n")
        for line in lines.reversed() {
            if line.contains("[STATS]") {
                var connected = 0
                var connecting = 0

                // Extract "Connected: X" value
                if let connRange = line.range(of: "Connected: ") {
                    let start = connRange.upperBound
                    var numStr = ""
                    for char in line[start...] {
                        if char.isNumber {
                            numStr.append(char)
                        } else {
                            break
                        }
                    }
                    connected = Int(numStr) ?? 0
                }

                // Extract "Connecting: X" value
                if let connRange = line.range(of: "Connecting: ") {
                    let start = connRange.upperBound
                    var numStr = ""
                    for char in line[start...] {
                        if char.isNumber {
                            numStr.append(char)
                        } else {
                            break
                        }
                    }
                    connecting = Int(numStr) ?? 0
                }

                return (connected, connecting)
            }
        }
        return nil
    }

    /// Gets container uptime from Docker.
    /// Returns a human-readable string like "2h 15m" or "3d 4h".
    func getUptime() -> String? {
        let output = runCommand("docker", arguments: ["ps", "--format", "{{.Status}}", "--filter", "name=\(containerName)"])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Docker status format: "Up 2 hours" or "Up 3 days" or "Up About an hour"
        guard trimmed.lowercased().hasPrefix("up ") else { return nil }

        // Remove "Up " prefix and clean up
        var uptime = String(trimmed.dropFirst(3))

        // Handle "About an hour" -> "~1h"
        if uptime.lowercased().contains("about") {
            uptime = uptime.replacingOccurrences(of: "About ", with: "~", options: .caseInsensitive)
            uptime = uptime.replacingOccurrences(of: "an hour", with: "1h", options: .caseInsensitive)
            uptime = uptime.replacingOccurrences(of: "a minute", with: "1m", options: .caseInsensitive)
        }

        // Shorten common units for cleaner display
        uptime = uptime.replacingOccurrences(of: " seconds", with: "s")
        uptime = uptime.replacingOccurrences(of: " second", with: "s")
        uptime = uptime.replacingOccurrences(of: " minutes", with: "m")
        uptime = uptime.replacingOccurrences(of: " minute", with: "m")
        uptime = uptime.replacingOccurrences(of: " hours", with: "h")
        uptime = uptime.replacingOccurrences(of: " hour", with: "h")
        uptime = uptime.replacingOccurrences(of: " days", with: "d")
        uptime = uptime.replacingOccurrences(of: " day", with: "d")
        uptime = uptime.replacingOccurrences(of: " weeks", with: "w")
        uptime = uptime.replacingOccurrences(of: " week", with: "w")

        return uptime.isEmpty ? nil : uptime
    }

    /// Parses container logs to extract traffic statistics.
    /// Looks for [STATS] lines in the format: "Up: 1.2 GB | Down: 3.4 GB"
    func getTraffic() -> (upload: String, download: String)? {
        let output = runCommand("docker", arguments: ["logs", "--tail", "50", containerName])

        let lines = output.components(separatedBy: "\n")
        for line in lines.reversed() {
            if line.contains("[STATS]") {
                var upload = "-"
                var download = "-"

                // Extract "Up: X.X GB" value
                if let upRange = line.range(of: "Up: ") {
                    let start = upRange.upperBound
                    let remaining = String(line[start...])
                    if let pipeIndex = remaining.firstIndex(of: "|") {
                        upload = String(remaining[..<pipeIndex]).trimmingCharacters(in: .whitespaces)
                    } else {
                        let parts = remaining.components(separatedBy: " ")
                        if parts.count >= 2 {
                            upload = "\(parts[0]) \(parts[1])"
                        }
                    }
                }

                // Extract "Down: X.X GB" value
                if let downRange = line.range(of: "Down: ") {
                    let start = downRange.upperBound
                    let remaining = String(line[start...])
                    if let pipeIndex = remaining.firstIndex(of: "|") {
                        download = String(remaining[..<pipeIndex]).trimmingCharacters(in: .whitespaces)
                    } else {
                        let parts = remaining.components(separatedBy: " ")
                        if parts.count >= 2 {
                            download = "\(parts[0]) \(parts[1])"
                        } else {
                            download = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }

                if upload != "-" || download != "-" {
                    return (upload, download)
                }
            }
        }
        return nil
    }

    /// Gets the Node ID from the container's key file.
    func getNodeId() -> String? {
        let output = runCommand("docker", arguments: [
            "run", "--rm", "-v", "conduit-data:/data", "alpine",
            "cat", "/data/conduit_key.json"
        ])

        // Extract privateKeyBase64 and derive node ID
        guard let range = output.range(of: "\"privateKeyBase64\":\"") else { return nil }
        let start = range.upperBound
        guard let endRange = output[start...].range(of: "\"") else { return nil }
        let base64Key = String(output[start..<endRange.lowerBound])

        // Decode base64, take last 32 bytes, re-encode
        guard let keyData = Data(base64Encoded: base64Key) else { return nil }
        guard keyData.count >= 32 else { return nil }
        let last32 = keyData.suffix(32)
        return last32.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Gets container configuration (max-clients and bandwidth).
    func getContainerConfig() -> (maxClients: String, bandwidth: String)? {
        let output = runCommand("docker", arguments: ["inspect", "--format", "{{.Args}}", containerName])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        var maxClients = "-"
        var bandwidth = "-"

        // Extract --max-clients value
        if let range = trimmed.range(of: "--max-clients ") {
            let start = range.upperBound
            var numStr = ""
            for char in trimmed[start...] {
                if char.isNumber {
                    numStr.append(char)
                } else {
                    break
                }
            }
            if !numStr.isEmpty {
                maxClients = numStr
            }
        }

        // Extract --bandwidth value
        if let range = trimmed.range(of: "--bandwidth ") {
            let start = range.upperBound
            var numStr = ""
            for char in trimmed[start...] {
                if char.isNumber || char == "-" {
                    numStr.append(char)
                } else {
                    break
                }
            }
            if numStr == "-1" {
                bandwidth = "Unlimited"
            } else if !numStr.isEmpty {
                bandwidth = "\(numStr) Mbps"
            }
        }

        return (maxClients, bandwidth)
    }

    // MARK: Command Execution

    /// Executes a shell command and returns its output.
    /// Handles the special case of GUI apps not inheriting shell PATH by using absolute paths for Docker.
    private func runCommand(_ command: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()

        // GUI apps don't inherit shell PATH, so we need to find Docker binary manually
        let executablePath: String
        if command == "docker" {
            let dockerPaths = [
                "/usr/local/bin/docker",
                "/opt/homebrew/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker"
            ]
            executablePath = dockerPaths.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/local/bin/docker"
        } else {
            executablePath = "/usr/bin/env"
        }

        if command == "docker" {
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        }

        // Capture both stdout and stderr
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
