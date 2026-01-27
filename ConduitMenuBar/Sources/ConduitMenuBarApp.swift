import SwiftUI
import AppKit
import UserNotifications

// MARK: - Main App

@main
struct ConduitMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty scene - we only use the menu bar
        Settings {
            EmptyView()
        }
    }
}

// MARK: - Docker Status

enum DockerStatus {
    case notInstalled
    case notRunning
    case running
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var conduitManager: ConduitManager?
    var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Initialize manager
        conduitManager = ConduitManager()

        // Setup menu
        setupMenu()

        // Start status update timer
        updateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
        updateStatus()
    }

    func setupMenu() {
        let menu = NSMenu()

        // Status header with icon
        let statusItem = NSMenuItem(title: "○ Conduit: Checking...", action: nil, keyEquivalent: "")
        statusItem.tag = 100  // Tag for updating
        menu.addItem(statusItem)

        // Docker status (hidden by default, shown when Docker has issues)
        let dockerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        dockerItem.tag = 101
        dockerItem.isHidden = true
        menu.addItem(dockerItem)

        // Client stats
        let statsItem = NSMenuItem(title: "Clients: -", action: nil, keyEquivalent: "")
        statsItem.tag = 102
        menu.addItem(statsItem)

        // Traffic stats
        let trafficItem = NSMenuItem(title: "Traffic: -", action: nil, keyEquivalent: "")
        trafficItem.tag = 103
        menu.addItem(trafficItem)

        menu.addItem(NSMenuItem.separator())

        // Control items
        let startItem = NSMenuItem(title: "▶ Start", action: #selector(startConduit), keyEquivalent: "s")
        startItem.tag = 200
        menu.addItem(startItem)

        let stopItem = NSMenuItem(title: "■ Stop", action: #selector(stopConduit), keyEquivalent: "x")
        stopItem.tag = 201
        menu.addItem(stopItem)

        menu.addItem(NSMenuItem.separator())

        // Docker Desktop download link (hidden by default)
        let downloadDockerItem = NSMenuItem(title: "Download Docker Desktop...", action: #selector(openDockerDownload), keyEquivalent: "")
        downloadDockerItem.tag = 300
        downloadDockerItem.isHidden = true
        menu.addItem(downloadDockerItem)

        // Terminal manager
        menu.addItem(NSMenuItem(title: "Open Terminal Manager...", action: #selector(openTerminal), keyEquivalent: "t"))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        self.statusItem?.menu = menu
    }

    func updateStatus() {
        guard let manager = conduitManager else { return }

        let dockerStatus = manager.getDockerStatus()
        let isRunning = dockerStatus == .running && manager.isContainerRunning()

        // Update icon based on status
        if let button = statusItem?.button {
            let symbolName: String
            switch dockerStatus {
            case .notInstalled, .notRunning:
                symbolName = "exclamationmark.triangle"
            case .running:
                symbolName = isRunning ? "globe.americas.fill" : "globe"
            }

            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Conduit") {
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                if let configuredImage = image.withSymbolConfiguration(config) {
                    configuredImage.isTemplate = true
                    button.image = configuredImage
                }
                button.contentTintColor = nil
            }
        }

        // Update menu items
        if let menu = statusItem?.menu {
            // Status text
            if let statusMenuItem = menu.item(withTag: 100) {
                switch dockerStatus {
                case .notInstalled:
                    statusMenuItem.title = "⚠ Docker Not Installed"
                case .notRunning:
                    statusMenuItem.title = "⚠ Docker Not Running"
                case .running:
                    statusMenuItem.title = isRunning ? "● Conduit: Running" : "○ Conduit: Stopped"
                }
            }

            // Docker status message
            if let dockerItem = menu.item(withTag: 101) {
                switch dockerStatus {
                case .notInstalled:
                    dockerItem.title = "   Install Docker Desktop to use Conduit"
                    dockerItem.isHidden = false
                case .notRunning:
                    dockerItem.title = "   Please start Docker Desktop"
                    dockerItem.isHidden = false
                case .running:
                    dockerItem.isHidden = true
                }
            }

            // Client stats
            if let statsItem = menu.item(withTag: 102) {
                if isRunning, let stats = manager.getStats() {
                    statsItem.title = "Clients: \(stats.connected) connected"
                    statsItem.isHidden = false
                } else {
                    statsItem.title = "Clients: -"
                    statsItem.isHidden = dockerStatus != .running
                }
            }

            // Traffic stats
            if let trafficItem = menu.item(withTag: 103) {
                if isRunning, let traffic = manager.getTraffic() {
                    trafficItem.title = "Traffic: ↑ \(traffic.upload)  ↓ \(traffic.download)"
                    trafficItem.isHidden = false
                } else {
                    trafficItem.title = "Traffic: -"
                    trafficItem.isHidden = dockerStatus != .running
                }
            }

            // Update Start/Stop button states
            if let startItem = menu.item(withTag: 200) {
                startItem.title = isRunning ? "↻ Restart" : "▶ Start"
                startItem.isEnabled = dockerStatus == .running
            }

            if let stopItem = menu.item(withTag: 201) {
                stopItem.isEnabled = isRunning
            }

            // Show/hide Docker download link
            if let downloadItem = menu.item(withTag: 300) {
                downloadItem.isHidden = dockerStatus != .notInstalled
            }
        }
    }

    @objc func startConduit() {
        guard let manager = conduitManager else { return }

        if manager.getDockerStatus() != .running {
            showNotification(title: "Conduit", body: "Please start Docker Desktop first")
            return
        }

        manager.startContainer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.updateStatus()
        }
        showNotification(title: "Conduit", body: "Starting Conduit service...")
    }

    @objc func stopConduit() {
        conduitManager?.stopContainer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.updateStatus()
        }
        showNotification(title: "Conduit", body: "Conduit service stopped")
    }

    @objc func openDockerDownload() {
        if let url = URL(string: "https://www.docker.com/products/docker-desktop/") {
            NSWorkspace.shared.open(url)
        }
    }

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

    func findConduitScript() -> String? {
        let possiblePaths = [
            "\(NSHomeDirectory())/conduit-manager/conduit-mac.sh",
            "/usr/local/bin/conduit",
            "\(NSHomeDirectory())/conduit-mac.sh"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Conduit Manager

class ConduitManager {
    let containerName = "conduit-mac"

    func getDockerStatus() -> DockerStatus {
        // First check if Docker CLI exists
        if !isDockerInstalled() {
            return .notInstalled
        }

        // Then check if Docker daemon is running
        if !isDockerRunning() {
            return .notRunning
        }

        return .running
    }

    func isDockerInstalled() -> Bool {
        let dockerPaths = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker"
        ]
        return dockerPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    func isDockerRunning() -> Bool {
        let output = runCommand("docker", arguments: ["info"])
        // Docker info returns error text when daemon isn't running
        return !output.isEmpty && !output.lowercased().contains("error") && !output.lowercased().contains("cannot connect")
    }

    func isContainerRunning() -> Bool {
        let output = runCommand("docker", arguments: ["ps", "--format", "{{.Names}}"])
        return output.contains(containerName)
    }

    func startContainer() {
        if !isContainerRunning() {
            // Check if container exists but is stopped
            let allContainers = runCommand("docker", arguments: ["ps", "-a", "--format", "{{.Names}}"])
            if allContainers.contains(containerName) {
                _ = runCommand("docker", arguments: ["start", containerName])
            }
            // If container doesn't exist, user needs to use the terminal script
        } else {
            _ = runCommand("docker", arguments: ["restart", containerName])
        }
    }

    func stopContainer() {
        _ = runCommand("docker", arguments: ["stop", containerName])
    }

    func getStats() -> (connected: Int, connecting: Int)? {
        let output = runCommand("docker", arguments: ["logs", "--tail", "50", containerName])

        // Parse STATS line
        let lines = output.components(separatedBy: "\n")
        for line in lines.reversed() {
            if line.contains("[STATS]") {
                // Extract Connected: X
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
                    if let connected = Int(numStr) {
                        return (connected, 0)
                    }
                }
            }
        }
        return nil
    }

    func getTraffic() -> (upload: String, download: String)? {
        let output = runCommand("docker", arguments: ["logs", "--tail", "50", containerName])

        // Parse STATS line for traffic data
        // Format: [STATS] Connected: X | Connecting: Y | Up: 1.2 GB | Down: 3.4 GB
        let lines = output.components(separatedBy: "\n")
        for line in lines.reversed() {
            if line.contains("[STATS]") {
                var upload = "-"
                var download = "-"

                // Extract Up: value
                if let upRange = line.range(of: "Up: ") {
                    let start = upRange.upperBound
                    let remaining = String(line[start...])
                    // Find the end (either | or end of line)
                    if let pipeIndex = remaining.firstIndex(of: "|") {
                        upload = String(remaining[..<pipeIndex]).trimmingCharacters(in: .whitespaces)
                    } else {
                        // Take until end or next space after the value
                        let parts = remaining.components(separatedBy: " ")
                        if parts.count >= 2 {
                            upload = "\(parts[0]) \(parts[1])"
                        }
                    }
                }

                // Extract Down: value
                if let downRange = line.range(of: "Down: ") {
                    let start = downRange.upperBound
                    let remaining = String(line[start...])
                    // Find the end (either | or end of line)
                    if let pipeIndex = remaining.firstIndex(of: "|") {
                        download = String(remaining[..<pipeIndex]).trimmingCharacters(in: .whitespaces)
                    } else {
                        // Take until end
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

    private func runCommand(_ command: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()

        // GUI apps don't inherit shell PATH, so we need to use absolute paths
        // Docker Desktop installs docker CLI to /usr/local/bin/docker
        let executablePath: String
        if command == "docker" {
            // Try common Docker paths
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
