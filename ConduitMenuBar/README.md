# Conduit Menu Bar App

A lightweight macOS menu bar application for monitoring and controlling Psiphon Conduit.

## Features

- **Status indicator** - Shows whether Conduit is running
- **Quick controls** - Start/Stop from the menu bar
- **Node ID display** - View and copy your node ID
- **Client stats** - See connected clients at a glance
- **Notifications** - Get notified of status changes

## Building

### Requirements

- macOS 12.0 or later
- Xcode 14.0 or later (or Swift 5.7+ toolchain)

### Build from command line

```bash
cd ConduitMenuBar
swift build -c release
```

The built app will be at `.build/release/ConduitMenuBar`

### Build with Xcode

1. Open `Package.swift` in Xcode
2. Select Product > Build
3. The app will be in the derived data folder

## Installation

1. Build the app
2. Copy to Applications folder (optional)
3. Run the app
4. It will appear in your menu bar

## Usage

- **Click the menu bar icon** to see status and options
- **Start/Restart** - Start or restart the Conduit container
- **Stop** - Stop the Conduit container
- **Node ID** - Click to copy your node ID to clipboard
- **Open Dashboard** - Opens the terminal dashboard
- **Open Terminal Manager** - Opens the full terminal interface

## Note

This menu bar app requires the main `conduit-mac.sh` script to be installed.
The app provides a convenient GUI overlay but uses the same Docker container.
