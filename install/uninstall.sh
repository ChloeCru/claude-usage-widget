#!/bin/sh
set -e
LABEL="com.claude-usage-widget"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Library/Application Support/ClaudeUsageWidget"
echo "✓ désinstallé"
