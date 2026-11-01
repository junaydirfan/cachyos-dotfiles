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
copy .config/systemd/user/plasma-plasmashell.service.d/clock-format.conf

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

# Custom app icons: launchers whose icon differs from the one the app ships with.
# Only the image and its app are kept, as the rest of a launcher is per-PC.
icons="$repo/icons"
rm -rf "$icons"
mkdir -p "$icons"
: > "$icons/overrides.tsv"
for entry in "$HOME"/.local/share/applications/*.desktop; do
    file="${entry##*/}"
    base=""
    for dir in /usr/share/applications /var/lib/flatpak/exports/share/applications; do
        if [ -f "$dir/$file" ]; then base="$dir/$file"; break; fi
    done
    [ -n "$base" ] || continue
    icon="$(sed -n 's/^Icon=//p;T;q' "$entry")"
    [ -n "$icon" ] && [ "$icon" != "$(sed -n 's/^Icon=//p;T;q' "$base")" ] || continue
    case "$icon" in
        /*) image="$icon" ;;
        *) image="$(find "$HOME/.local/share/icons" -maxdepth 1 -type f -name "$icon.*" -print -quit)" ;;
    esac
    if [ -f "$image" ]; then
        name="custom-${image##*/}"
        cp "$image" "$icons/$name"
        icon="${name%.*}"
    fi
    printf '%s\t%s\n' "$file" "$icon" >> "$icons/overrides.tsv"
done

# Panels and widgets. Installed by the installer's --plasma step.
layout="$repo/plasma/plasma-org.kde.plasma.desktop-appletsrc"
cp "$config/plasma-org.kde.plasma.desktop-appletsrc" "$layout"
# Weather place and desktop icon positions, which name your files.
sed -i -E \
    -e '/^(placeDisplayName|placeInfo)=/d' \
    -e '/^(positions|changedPositions)=/d' \
    -e 's/^activityId=[0-9a-f-]{36}$/activityId=@ACTIVITY@/' \
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
# The lock screen has one wallpaper for every monitor. Installed with the layout.
lock="$repo/plasma/kscreenlockerrc"
cp "$config/kscreenlockerrc" "$lock"
sed -i -E 's#^(Image|PreviewImage)=file://.*/([^/]+)$#\1=file://@HOME@/.local/share/wallpapers/cachyos-dotfiles/\2#' "$lock"
# Widget icons kept in ~/Pictures travel with the repo. Runs after the wallpapers so
# a wallpaper there isn't mistaken for an icon.
while IFS= read -r image; do
    [ -f "$image" ] || continue
    cp "$image" "$icons/custom-${image##*/}"
    sed -i "s#$image#@HOME@/.local/share/icons/custom-${image##*/}#g" "$layout"
done < <(grep -oE "$HOME/Pictures/[^\",]+\.(png|svg)" "$layout" | sort -u)
sed -i "s#$HOME#@HOME@#g" "$layout"

echo "synced. Now run scripts/check-secrets.sh and read the diff."
