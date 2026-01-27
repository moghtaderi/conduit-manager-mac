# Homebrew Formula for Psiphon Conduit Manager (macOS)
#
# Installation:
#   brew tap moghtaderi/conduit-manager-mac https://github.com/moghtaderi/conduit-manager-mac
#   brew install conduit-mac
#
# Or direct install:
#   brew install moghtaderi/conduit-manager-mac/conduit-mac

class ConduitMac < Formula
  desc "Security-hardened Psiphon Conduit Manager for macOS"
  homepage "https://github.com/moghtaderi/conduit-manager-mac"
  url "https://github.com/moghtaderi/conduit-manager-mac/archive/refs/tags/v1.4.0.tar.gz"
  sha256 "PLACEHOLDER_SHA256"  # Update this after creating release
  license "MIT"
  head "https://github.com/moghtaderi/conduit-manager-mac.git", branch: "main"

  depends_on :macos

  # Docker Desktop is a cask, not a formula dependency
  # The script will check for it at runtime

  def install
    bin.install "conduit-mac.sh" => "conduit"
  end

  def caveats
    <<~EOS
      Psiphon Conduit Manager has been installed!

      Prerequisites:
        Docker Desktop must be installed and running.
        Download from: https://www.docker.com/products/docker-desktop/

      Usage:
        conduit              # Launch interactive menu
        conduit --help       # Show help (if implemented)

      The script will guide you through:
        - First-time setup
        - Live monitoring dashboard
        - Security configuration
        - Backup and restore

      For more information:
        https://github.com/moghtaderi/conduit-manager-mac
    EOS
  end

  test do
    # Basic test - check script exists and is executable
    assert_predicate bin/"conduit", :exist?
    assert_predicate bin/"conduit", :executable?

    # Check it's a valid bash script
    assert_match "#!/bin/bash", File.read(bin/"conduit")

    # Check version string exists
    assert_match(/VERSION="[0-9]+\.[0-9]+\.[0-9]+"/, File.read(bin/"conduit"))
  end
end
