#!/usr/bin/env bash
# Installs the Discord voice widget and its background bridge, then asks for your
# Discord app's ID and secret if they aren't saved yet. Safe to run again.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
share="$HOME/.local/share/discord-voice-widget"
config="${XDG_CONFIG_HOME:-$HOME/.config}/discord-voice-widget/config.json"
units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
service=discord-voice-bridge.service

if [ -d "$HOME/.local/share/plasma/plasmoids/org.cachyos.discordvoice" ]; then
    kpackagetool6 -t Plasma/Applet -u "$here/package" >/dev/null
else
    kpackagetool6 -t Plasma/Applet -i "$here/package" >/dev/null
fi

mkdir -p "$share" "$units"
install -m755 "$here/bridge.py" "$share/bridge.py"
cat > "$units/$service" <<UNIT
[Unit]
Description=Discord voice data for the desktop widget

[Service]
ExecStart=/usr/bin/python3 -I $share/bridge.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable "$service"
systemctl --user restart "$service"

# A failed sign-in leaves no token, so ask again rather than reuse details that may be wrong.
if [ -f "$config" ] && ! grep -q access_token "$config" && [ -t 0 ]; then
    read -r -p "Discord isn't connected yet. Enter your app details again? [y/N] " reply
    if [[ "$reply" =~ ^[Yy] ]]; then rm -f "$config"; fi
fi

if [ ! -f "$config" ] && [ -t 0 ]; then
    cat <<'HELP'

Create a free Discord app (one time):
  1. Open https://discord.com/developers/applications and choose New Application.
  2. Under OAuth2, copy the Client ID and reset to get a Client Secret.
  3. Under OAuth2 > Redirects, keep exactly one entry, http://127.0.0.1, and save.

HELP
    read -r -p "Client ID: " client_id
    read -r -s -p "Client Secret (hidden): " client_secret
    echo
    mkdir -p "$(dirname "$config")"
    (
        umask 077
        CLIENT_ID="$client_id" CLIENT_SECRET="$client_secret" python3 -I -c '
import json, os, sys
json.dump({"client_id": os.environ["CLIENT_ID"], "client_secret": os.environ["CLIENT_SECRET"]}, open(sys.argv[1], "w"))
' "$config"
    )
    systemctl --user restart "$service"
    echo "Now approve the request that pops up in Discord."
fi
