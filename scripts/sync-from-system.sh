#!/usr/bin/env bash
# Re-captures configs from this machine into the repo, scrubbing personal data.
# Run scripts/check-secrets.sh afterwards, and read the diff before committing.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$repo/home"
config="$HOME/.config"

copy() {
    # copy <path relative to $HOME>
    [ -e "$HOME/$1" ] || { echo "skip (missing): $1"; return 0; }
    mkdir -p "$dest/$(dirname "$1")"
    cp -a "$HOME/$1" "$dest/$1"
}

# Removes every INI section whose header starts with the given text.
drop_section() {
    awk -v prefix="$1" '
        /^\[/ { skip = (index($0, prefix) == 1) }
        !skip { print }
    ' "$2" > "$2.tmp"
    mv "$2.tmp" "$2"
}

rm -rf "$dest"
mkdir -p "$dest"

for f in kwinrc kwinrulesrc kglobalshortcutsrc kdeglobals kcminputrc plasmarc \
    dolphinrc konsolerc; do
    copy ".config/$f"
done
copy .config/fontconfig/fonts.conf
copy .config/gtk-3.0/settings.ini
copy .config/gtk-4.0/settings.ini
copy .gtkrc-2.0
copy .config/fish/config.fish
copy .config/alacritty/alacritty.toml
copy .config/fastfetch/config.jsonc
copy .config/fastfetch/custom_logo.txt
copy .config/zed/settings.json
copy .config/micro/settings.json
copy .config/cava/themes
copy .config/cava/shaders

# Only CachyOS ships this file, so don't fail without it.
sed -i -E 's#^source (/usr/share/cachyos-fish-config/.*)$#test -f \1; and source \1#' \
    "$dest/.config/fish/config.fish"

# Desktop IDs and tiling layouts are per-machine UUIDs.
drop_section '[Tiling]' "$dest/.config/kwinrc"
sed -i -E '/^Id_[0-9]+=/d; /^XwaylandEisNoPromptApps=/d' "$dest/.config/kwinrc"
# Scaling belongs to the display, so let each PC keep its own.
drop_section '[Xwayland]' "$dest/.config/kwinrc"
sed -i '/^gtk-xft-dpi=/d' "$dest/.config/gtk-3.0/settings.ini" "$dest/.config/gtk-4.0/settings.ini"
# These sections are per input device: this laptop's touchpad, my keyboard and mouse.
drop_section '[Libinput]' "$dest/.config/kcminputrc"
# Wallpaper history holds personal paths.
drop_section '[Wallpapers]' "$dest/.config/plasmarc"
# File dialog history, if any was saved.
sed -i -E '/^(Recent (Files|URLs)|History)/d' "$dest/.config/kdeglobals"

# Panels and widgets. Installed by the installer's --plasma step.
layout="$repo/plasma/plasma-org.kde.plasma.desktop-appletsrc"
cp "$config/plasma-org.kde.plasma.desktop-appletsrc" "$layout"
# Weather place and desktop icon positions, which name your files.
sed -i -E \
    -e '/^(placeDisplayName|placeInfo)=/d' \
    -e '/^(positions|changedPositions)=/d' \
    -e 's/^activityId=[0-9a-f-]{36}$/activityId=@ACTIVITY@/' \
    "$layout"
# A launcher icon kept in ~/Pictures won't exist for anyone else.
sed -i -E \
    -e "s#^icon=$HOME/Pictures/[^ ]*\$#icon=start-here-kde-symbolic#" \
    -e "s#\"icon\":\"$HOME/Pictures/[^\"]*\"#\"icon\":\"start-here-kde-symbolic\"#g" \
    "$layout"
# Keep only the wallpapers applied right now, wherever they're stored.
mkdir -p "$repo/wallpapers"
find "$repo/wallpapers" -type f -delete
while IFS= read -r image; do
    image="${image#Image=file://}"
    if [ -f "$image" ]; then
        cp "$image" "$repo/wallpapers/"
    else
        echo "skip wallpaper that isn't a single file: ${image##*/}"
    fi
done < <(grep '^Image=file://' "$layout")
sed -i -E 's#^Image=file://.*/([^/]+)$#Image=file://@HOME@/.local/share/wallpapers/cachyos-dotfiles/\1#' "$layout"
sed -i "s#$HOME#@HOME@#g" "$layout"

echo "synced. Now run scripts/check-secrets.sh and read the diff."
