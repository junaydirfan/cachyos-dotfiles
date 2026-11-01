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
paths=(home plasma wallpapers icons)
# More deleted files than this means a broken capture, not a settings change.
max_deleted=10

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

# Puts the repo back so one bad capture can't block every later sync. Safe because
# the tree was clean before the capture.
roll_back() {
    git reset -q --hard
    git clean -fdq -- "${paths[@]}"
    stop "$1"
}

# A manual run and the timer must not capture over each other.
exec 9> "${XDG_RUNTIME_DIR:-/tmp}/$name.lock"
flock -n 9 || exit 0

cd "$repo"
[ "$(git branch --show-current)" = main ] || stop "the repo isn't on main"
# Unfinished work must never be swept into an automatic commit.
[ -z "$(git status --porcelain)" ] || stop "the repo has uncommitted changes"
git pull -q --ff-only || stop "couldn't update from GitHub"

scripts/sync-from-system.sh >/dev/null || roll_back "couldn't capture the settings"
if ! scripts/check-secrets.sh >/dev/null; then
    roll_back "the secret check failed, so nothing was committed"
fi
deleted="$(git ls-files --deleted -- "${paths[@]}" | wc -l)"
if [ "$deleted" -gt "$max_deleted" ]; then
    roll_back "the capture removed $deleted files, so nothing was committed"
fi

git add -- "${paths[@]}"
if ! git diff --cached --quiet; then
    git commit -q -m "Sync settings from my PC"
fi
if [ -n "$(git log --oneline '@{upstream}..')" ]; then
    git push -q || stop "couldn't push to GitHub"
fi
