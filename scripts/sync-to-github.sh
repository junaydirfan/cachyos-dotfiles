#!/usr/bin/env bash
# Captures this PC's settings and pushes them to GitHub. The repo is public, so
# nothing is committed unless the secret check passes.
#   scripts/sync-to-github.sh            sync now
#   scripts/sync-to-github.sh --install  sync daily with a systemd user timer
#   scripts/sync-to-github.sh --remove   stop syncing daily
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
name=cachyos-dotfiles-sync
paths=(home plasma wallpapers)

# Runs unattended, so failures have to reach the desktop as well as the journal.
stop() {
    echo "$1" >&2
    notify-send -a 'Dotfiles sync' 'Settings not synced' "$1" 2>/dev/null || true
    exit 1
}

install_timer() {
    mkdir -p "$units"
    cat > "$units/$name.service" <<UNIT
[Unit]
Description=Sync settings to the dotfiles repo
After=graphical-session.target

[Service]
Type=oneshot
ExecStart=$repo/scripts/sync-to-github.sh
UNIT
    cat > "$units/$name.timer" <<UNIT
[Unit]
Description=Sync settings to the dotfiles repo daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now "$name.timer"
}

remove_timer() {
    systemctl --user disable --now "$name.timer" 2>/dev/null || true
    rm -f "$units/$name.service" "$units/$name.timer"
    systemctl --user daemon-reload
}

case "${1:-}" in
    --install) install_timer; exit 0 ;;
    --remove) remove_timer; exit 0 ;;
    '') ;;
    *) sed -n '2,6p' "$0" >&2; exit 1 ;;
esac

cd "$repo"
[ "$(git branch --show-current)" = main ] || stop "the repo isn't on main"
# Unfinished work must never be swept into an automatic commit.
[ -z "$(git status --porcelain)" ] || stop "the repo has uncommitted changes"
git pull -q --ff-only || stop "couldn't update from GitHub"

scripts/sync-from-system.sh >/dev/null || stop "couldn't capture the settings"
if ! scripts/check-secrets.sh; then
    # Safe because the tree was clean before the capture.
    git reset -q --hard
    git clean -fdq -- "${paths[@]}"
    stop "the secret check failed, so nothing was committed"
fi

git add -- "${paths[@]}"
if ! git diff --cached --quiet; then
    git commit -q -m "Sync settings from my PC"
fi
if [ -n "$(git log --oneline '@{upstream}..')" ]; then
    git push -q || stop "couldn't push to GitHub"
fi
