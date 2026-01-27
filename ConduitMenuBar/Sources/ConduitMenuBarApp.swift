import SwiftUI
import AppKit

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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var conduitManager: ConduitManager?
    var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

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

        // Terminal manager
        menu.addItem(NSMenuItem(title: "Open Terminal Manager...", action: #selector(openTerminal), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Copy Node ID", action: #selector(copyNodeId), keyEquivalent: "c"))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        self.statusItem?.menu = menu
    }

    func updateStatus() {
        guard let manager = conduitManager else { return }

        let isRunning = manager.isContainerRunning()

        // Update icon based on status
        if let button = statusItem?.button {
            // Use different SF Symbols for running vs stopped
            let symbolName = isRunning ? "globe.americas.fill" : "globe"

            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Conduit") {
                // Configure size for menu bar
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                if let configuredImage = image.withSymbolConfiguration(config) {
                    // Always use template mode for proper dark mode support
                    configuredImage.isTemplate = true
                    button.image = configuredImage
                }
                // Clear any tint - let the system handle light/dark mode
                button.contentTintColor = nil
            }
        }

        // Update menu items
        if let menu = statusItem?.menu {
            // Status text
            if let statusMenuItem = menu.item(withTag: 100) {
                statusMenuItem.title = isRunning ? "● Conduit: Running" : "○ Conduit: Stopped"
            }

            // Client stats
            if let statsItem = menu.item(withTag: 102) {
                if isRunning, let stats = manager.getStats() {
                    statsItem.title = "Clients: \(stats.connected) connected"
                } else {
                    statsItem.title = "Clients: -"
                }
            }

            // Traffic stats
            if let trafficItem = menu.item(withTag: 103) {
                if isRunning, let traffic = manager.getTraffic() {
                    trafficItem.title = "Traffic: ↑ \(traffic.upload)  ↓ \(traffic.download)"
                } else {
                    trafficItem.title = "Traffic: -"
                }
            }

            // Update Start/Stop button states
            if let startItem = menu.item(withTag: 200) {
                startItem.title = isRunning ? "↻ Restart" : "▶ Start"
            }

            if let stopItem = menu.item(withTag: 201) {
                stopItem.isEnabled = isRunning
            }
        }
    }

    @objc func startConduit() {
        conduitManager?.startContainer()
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

    @objc func copyNodeId() {
        if let nodeId = conduitManager?.getNodeId() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(nodeId, forType: .string)
            showNotification(title: "Copied", body: "Node ID copied to clipboard")
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
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = nil
        NSUserNotificationCenter.default.deliver(notification)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Conduit Manager

class ConduitManager {
    let containerName = "conduit-mac"

    func isContainerRunning() -> Bool {
        let output = runCommand("docker", arguments: ["ps", "--format", "{{.Names}}"])
        return output.contains(containerName)
    }

    func isDockerRunning() -> Bool {
        let output = runCommand("docker", arguments: ["info"])
        return !output.isEmpty && !output.contains("error")
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

    func getNodeId() -> String? {
        // Use docker to read the key file
        let output = runCommand("docker", arguments: [
            "run", "--rm",
            "-v", "conduit-data:/data",
            "alpine",
            "cat", "/data/conduit_key.json"
        ])

        if output.isEmpty || output.contains("error") {
            return nil
        }

        // Parse the JSON to extract privateKeyBase64
        // This is a simplified extraction
        if let range = output.range(of: "privateKeyBase64\":\"") {
            let start = range.upperBound
            if let end = output[start...].firstIndex(of: "\"") {
                let base64Key = String(output[start..<end])
                // Decode and get last 32 bytes, then re-encode
                if let data = Data(base64Encoded: base64Key), data.count >= 32 {
                    let last32 = data.suffix(32)
                    return last32.base64EncodedString().replacingOccurrences(of: "=", with: "")
                }
            }
        }
        return nil
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
