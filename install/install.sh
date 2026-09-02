#!/bin/sh
# Compile, installe et lance le widget. Idempotent.
set -e
cd "$(dirname "$0")/.."

LABEL="com.claude-usage-widget"
APP="$HOME/Library/Application Support/ClaudeUsageWidget"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "→ compilation"
swiftc -O main.swift -o claude-usage-widget

echo "→ installation dans $APP"
mkdir -p "$APP" "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
cp claude-usage-widget "$APP/"

echo "→ LaunchAgent (le chemin est substitué à partir de \$HOME)"
sed "s|__HOME__|$HOME|g" install/com.claude-usage-widget.plist > "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✓ installé. Journal : /tmp/claude-usage-widget.err.log"
