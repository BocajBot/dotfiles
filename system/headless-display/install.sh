#!/bin/sh
# Root side of the i3 $mod+Shift+m headless toggle (~/.local/bin/headless-toggle).
# Run: pkexec sh system/headless-display/install.sh   (from the chezmoi source dir)
set -e
cd "$(dirname "$0")"
install -Dm755 headless-display /usr/local/libexec/headless-display
install -Dm644 edid-1080p60.bin /usr/local/share/headless-display/edid-1080p60.bin
install -Dm644 headless-display.service /etc/systemd/system/headless-display.service
install -Dm644 50-headless-display.rules /etc/polkit-1/rules.d/50-headless-display.rules
systemctl daemon-reload
