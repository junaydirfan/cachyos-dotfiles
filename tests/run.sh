#!/usr/bin/env bash
# Runs the installer against simulated PCs. Needs no network and touches nothing real.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
bin="$work/bin"
passed=0 failed=0
mkdir -p "$bin"

check() {
    # check <description> <command...>
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        echo "FAIL: $name"
    fi
}

# shellcheck disable=SC2016
fake() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
fake lspci 'cat "$DOTFILES_SYSROOT/lspci"'
fake pacman 'if [ "$1" = -Slq ]; then cat "$DOTFILES_SYSROOT/repo"; else echo "pacman $*" >> "$DOTFILES_SYSROOT/log"; fi'
fake sudo '"$@"'
fake fc-list 'if [ -n "${HELVETICA:-}" ]; then echo Helvetica; seq 100000; fi'
fake kquitapp6 'echo quit >> "$DOTFILES_SYSROOT/log"'
fake kstart 'echo start >> "$DOTFILES_SYSROOT/log"'
fake qdbus6 'echo test-activity'
fake kbuildsycoca6 'true'
fake kpackagetool6 'echo "kpackagetool6 $*" >> "$DOTFILES_SYSROOT/log"
if [ "$3" = -i ]; then mkdir -p "$HOME/.local/share/plasma/plasmoids/$(basename "$4")"; fi'

pc() {
    # pc <name> <cpu vendor> <chassis> <product> <monitors> <gpu lines>
    local root="$work/$1" i
    mkdir -p "$root"/{etc,proc,home,sys/class/dmi/id,sys/bus/usb/devices/1-1,usr/share/applications}
    touch "$root/etc/arch-release"
    echo "vendor_id : $2" > "$root/proc/cpuinfo"
    echo "$3" > "$root/sys/class/dmi/id/chassis_type"
    echo "$4" > "$root/sys/class/dmi/id/product_version"
    for ((i = 1; i <= $5; i++)); do
        mkdir -p "$root/sys/class/drm/card0-DP-$i"
        echo connected > "$root/sys/class/drm/card0-DP-$i/status"
    done
    printf '%b' "$6" > "$root/lspci"
    cat "$repo"/packages/*.txt > "$root/repo"
    touch "$root/log"
}

on() {
    # on <pc> <installer args...>: runs with answers from $ANSWERS, default yes
    local root="$work/$1"
    shift
    yes "${ANSWERS:-y}" | env HOME="$root/home" DOTFILES_SYSROOT="$root" DOTFILES_SOURCES="$work/sources.tsv" \
        PATH="$bin:$PATH" KDE_SESSION_VERSION=6 "$repo/install.sh" "$@"
}

has() { grep -qF -- "$2" "$work/$1/log"; }
lacks() { ! has "$@"; }
output_has() { printf '%s' "$1" | grep -qF -- "$2"; }

amd='03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 22\n'
intel='00:02.0 VGA compatible controller [0300]: Intel Corporation Alder Lake\n'
nvidia='01:00.0 VGA compatible controller [0300]: NVIDIA Corporation TU106\n'
pc amd AuthenticAMD 3 MS-7D25 1 "$amd"
pc intel GenuineIntel 10 ThinkPad 1 "$intel"
pc nvidia GenuineIntel 3 Z790 2 "$nvidia"
pc legion GenuineIntel 10 "Legion Pro 7" 3 "$intel$nvidia"
pc other AuthenticAMD 3 B650 1 "$amd"
pc broken AuthenticAMD 3 B650 1 "$amd"

# A local stand-in for an upstream theme, with a symlink like real icon themes.
upstream="$work/upstream"
mkdir -p "$upstream/icons/sub" "$upstream/widget"
echo icon > "$upstream/icons/sub/a.svg"
ln -s a.svg "$upstream/icons/sub/b.svg"
printf '{ "KPlugin": {\n  "Id": "test.widget"\n} }\n' > "$upstream/widget/metadata.json"
git -C "$upstream" init -q
git -C "$upstream" add -A
git -C "$upstream" -c user.name=t -c user.email=t@t commit -qm init
commit="$(git -C "$upstream" rev-parse HEAD)"
printf 'Icons\tdir\t%s\t%s\ticons\t.local/share/icons/Test\n' "$upstream" "$commit" > "$work/sources.tsv"
printf 'Widget\tplasmoid\t%s\t%s\twidget\t\n' "$upstream" "$commit" >> "$work/sources.tsv"

# Hardware offers
on amd --hardware >/dev/null 2>&1
check "AMD gets AMD packages" has amd vulkan-radeon
check "AMD skips NVIDIA packages" lacks amd nvidia-settings
check "AMD skips Legion packages" lacks amd lenovolegionlinux
on intel --hardware >/dev/null 2>&1
check "single-GPU laptop skips dual-GPU tools" lacks intel nvidia-prime
on legion --hardware >/dev/null 2>&1
check "Legion gets Legion packages" has legion lenovolegionlinux
check "hybrid laptop gets dual-GPU tools" has legion nvidia-prime
out="$(on nvidia --hardware 2>&1)"
check "NVIDIA without a driver gets the chwd hint" output_has "$out" "chwd -a"

# Packages missing from the repos are skipped, not fatal
sed -i '/^vulkan-radeon$/d' "$work/other/repo"
on other --hardware >/dev/null 2>&1
check "unavailable package is skipped" lacks other " vulkan-radeon"
check "rest of the group still installs" has other lact

# Partial configs
home="$work/other/home"
on other --only shell >/dev/null 2>&1
check "--only copies the chosen part" test -f "$home/.config/fish/config.fish"
check "--only leaves other parts" test ! -e "$home/.config/kglobalshortcutsrc"
check "unknown part is rejected" bash -c "! yes | env HOME='$home' DOTFILES_SYSROOT='$work/other' PATH='$bin:$PATH' '$repo/install.sh' --only nope"
check "default apps are never replaced" test ! -e "$repo/home/.config/mimeapps.list"

# An early match in a long font list must still count as installed
HELVETICA=1 on nvidia --only desktop >/dev/null 2>&1
check "installed Helvetica is kept" grep -q Helvetica "$work/nvidia/home/.config/kdeglobals"

# Custom icons reach only the apps this PC has
entry="$(cut -f1 "$repo/icons/overrides.tsv" | head -n1)"
absent="$(cut -f1 "$repo/icons/overrides.tsv" | tail -n1)"
icon="$(cut -f2 "$repo/icons/overrides.tsv" | head -n1)"
printf '[Desktop Entry]\nIcon=stock\nExec=app\n\n[Desktop Action a]\nIcon=action\n' > "$work/nvidia/usr/share/applications/$entry"
on nvidia --only desktop >/dev/null 2>&1
apps="$work/nvidia/home/.local/share/applications"
check "custom icon images are installed" test -f "$work/nvidia/home/.local/share/icons/$icon.png"
check "an installed app gets its custom icon" grep -qx "Icon=$icon" "$apps/$entry"
check "the rest of the launcher is kept" grep -qx 'Exec=app' "$apps/$entry"
check "action icons are left alone" grep -qx 'Icon=action' "$apps/$entry"
check "a missing app gets no launcher" test ! -e "$apps/$absent"
check "the layout has no paths outside the repo" bash -c "! grep -q 'Pictures' '$repo/plasma/plasma-org.kde.plasma.desktop-appletsrc'"

# Backups and undo
home="$work/amd/home"
mkdir -p "$home/.config/fish"
echo mine > "$home/.config/fish/config.fish"
on amd --only all >/dev/null 2>&1
check "configs are copied" test -f "$home/.config/kwinrc"
check "missing Helvetica falls back" bash -c "! grep -q Helvetica '$home/.config/kdeglobals'"
out="$(on amd --only all 2>&1)"
check "second run changes nothing" bash -c "! printf '%s' '$out' | grep -q 'Changed'"
on amd --undo >/dev/null 2>&1
check "undo restores the original" grep -qx mine "$home/.config/fish/config.fish"
check "undo removes new files" test ! -e "$home/.config/kwinrc"

# Themes
home="$work/intel/home"
on intel --themes >/dev/null 2>&1
check "theme files are installed" test -f "$home/.local/share/icons/Test/sub/a.svg"
check "symlinks stay symlinks" test -L "$home/.local/share/icons/Test/sub/b.svg"
check "widget is installed" has intel "-i"
on intel --undo >/dev/null 2>&1
check "undo removes theme files" test ! -e "$home/.local/share/icons/Test/sub/a.svg"
check "undo removes the widget" has intel "-r test.widget"

printf 'Good\tdir\t%s\t%s\ticons\t.local/share/icons/Good\n' "$upstream" "$commit" > "$work/good.tsv"
{ printf 'Bad\tdir\t%s/missing\t%s\ticons\t.local/share/icons/Bad\n' "$upstream" "$commit"; cat "$work/good.tsv"; } > "$work/sources.tsv"
on broken --themes >/dev/null 2>&1
status=$?
check "a failed download is reported" test "$status" -eq 1
check "later themes still install" test -f "$work/broken/home/.local/share/icons/Good/sub/a.svg"

# Panel layout
for pc_name in amd legion; do on "$pc_name" --plasma >/dev/null 2>&1; done
file=".config/plasma-org.kde.plasma.desktop-appletsrc"
panel_screen() { awk '/^\[Containments\]\[778\]$/{on=1;next} /^\[/{on=0} on&&/^lastScreen=/{print substr($0,12)}' "$1"; }
check "one monitor: dock on the main screen" test "$(panel_screen "$work/amd/home/$file")" = 0
check "three monitors: dock on the middle screen" test "$(panel_screen "$work/legion/home/$file")" = 1
tray_screen() { awk '/^\[Containments\]\[778\]\[Applets\]\[783\]$/{on=1;next} /^\[/{on=0} on&&/^lastScreen=/{print substr($0,12)}' "$1"; }
check "one monitor: tray follows the dock" test "$(tray_screen "$work/amd/home/$file")" = 0
check "three monitors: tray follows the dock" test "$(tray_screen "$work/legion/home/$file")" = 1
check "placeholders are filled in" bash -c "! grep -q '@HOME@\|@ACTIVITY@\|@ONE@' '$work/amd/home/$file'"
check "shortcuts for missing apps are dropped" bash -c "! grep -q 'com.spotify.Client' '$work/amd/home/$file'"
check "the file manager shortcut stays" grep -q 'preferred://filemanager' "$work/amd/home/$file"
check "Plasma is restarted" has amd start
check "the lock screen matches a shipped wallpaper" test -f "$(sed -n 's#^Image=file://##p' "$work/amd/home/.config/kscreenlockerrc" | head -n1)"
check "exactly three wallpapers ship" test "$(find "$repo/wallpapers" -type f | wc -l)" -eq 3
check "wallpapers are installed" test "$(find "$work/amd/home/.local/share/wallpapers/cachyos-dotfiles" -type f | wc -l)" -eq 3
for image in $(sed -n 's#^Image=file://##p' "$work/amd/home/$file"); do
    check "layout wallpaper exists: ${image##*/}" test -f "$image"
done
: > "$work/amd/log"
on amd --undo >/dev/null 2>&1
check "undo stops Plasma before restoring the layout" has amd quit
check "undo restores the layout" test ! -e "$work/amd/home/$file"
check "undo restarts Plasma" has amd start
check "undo removes the wallpapers" test ! -e "$work/amd/home/.local/share/wallpapers/cachyos-dotfiles"

# Discord voice
check "the voice bridge follows a call" python3 -I "$repo/tests/discord_voice_test.py"

# Sidebar fix
qml="$work/nvidia/usr/share/plasma/shells/org.kde.plasma.desktop/contents/views/Desktop.qml"
fix="$repo/hardware/plasma-sidebar/fix-plasma-sidebar"
mkdir -p "$(dirname "$qml")"
printf '        hideOnWindowDeactivate: true\n\n        onVisibleChanged: {\n' > "$qml"
on nvidia --hardware >/dev/null 2>&1
check "two monitors: the hook is installed" test -f "$work/nvidia/etc/pacman.d/hooks/fix-plasma-sidebar.hook"
check "two monitors: the script is installed" test -x "$work/nvidia/usr/local/bin/fix-plasma-sidebar"
check "two monitors: Desktop.qml is patched" grep -q 'let result = desktop.x' "$qml"
check "one monitor: no sidebar hook" test ! -e "$work/amd/etc/pacman.d/hooks/fix-plasma-sidebar.hook"
check "the hook watches the patched file" grep -qx "Target = ${qml#"$work/nvidia/"}" "$repo/hardware/plasma-sidebar/fix-plasma-sidebar.hook"
patched="$(cat "$qml")"
"$fix" "$qml"
check "patching twice changes nothing" test "$patched" = "$(cat "$qml")"
echo 'something else' > "$work/unknown.qml"
"$fix" "$work/unknown.qml" 2>/dev/null
status=$?
check "an unknown file doesn't fail pacman" test "$status" -eq 0
check "an unknown file is left alone" grep -qx 'something else' "$work/unknown.qml"

# Sync to GitHub, against a throwaway remote and stand-ins for the capture and check
remote="$work/remote.git"
clone="$work/clone"
fake notify-send 'true'
git init -q --bare -b main "$remote"
git init -q -b main "$clone"
git -C "$clone" config user.name t
git -C "$clone" config user.email t@t
mkdir -p "$clone/scripts" "$clone/home" "$clone/plasma" "$clone/wallpapers" "$clone/icons"
cp "$repo/scripts/sync-to-github.sh" "$clone/scripts/"
printf '#!/usr/bin/env bash\ntest ! -e "$SYNC_CAPTURE.broken" || { rm home/setting; exit 1; }\ntest ! -e "$SYNC_CAPTURE.wipe" || rm -f home/many-*\ncat "$SYNC_CAPTURE" > home/setting\n' > "$clone/scripts/sync-from-system.sh"
printf '#!/usr/bin/env bash\ntest ! -e "$SYNC_CAPTURE.bad"\n' > "$clone/scripts/check-secrets.sh"
chmod +x "$clone"/scripts/*.sh
export SYNC_CAPTURE="$work/capture"
echo one > "$SYNC_CAPTURE"
echo one > "$clone/home/setting"
touch "$clone/plasma/keep" "$clone/wallpapers/keep" "$clone/icons/keep"
git -C "$clone" add -A
git -C "$clone" commit -qm init
git -C "$clone" remote add origin "$remote"
git -C "$clone" push -qu origin main
sync_now() { PATH="$bin:$PATH" "$clone/scripts/sync-to-github.sh"; }
pushed() { git -C "$remote" rev-list --count main; }

sync_now
check "sync with no changes makes no commit" test "$(pushed)" -eq 1
echo two > "$SYNC_CAPTURE"
sync_now
check "sync pushes changed settings" test "$(git -C "$remote" show main:home/setting)" = two
echo three > "$SYNC_CAPTURE"
touch "$SYNC_CAPTURE.bad"
sync_now >/dev/null 2>&1
status=$?
rm "$SYNC_CAPTURE.bad"
check "a failed secret check is reported" test "$status" -eq 1
check "a failed secret check pushes nothing" test "$(pushed)" -eq 2
check "a failed secret check leaves the repo clean" test -z "$(git -C "$clone" status --porcelain)"
echo draft > "$clone/home/draft"
sync_now >/dev/null 2>&1
status=$?
check "unfinished work stops the sync" test "$status" -eq 1
check "unfinished work isn't pushed" test "$(pushed)" -eq 2
rm "$clone/home/draft"
touch "$SYNC_CAPTURE.broken"
sync_now >/dev/null 2>&1
status=$?
rm "$SYNC_CAPTURE.broken"
check "a failed capture is reported" test "$status" -eq 1
check "a failed capture leaves the repo clean" test -z "$(git -C "$clone" status --porcelain)"
echo two > "$SYNC_CAPTURE"
sync_now
touch "$clone"/home/many-{1..11}
git -C "$clone" add -A
git -C "$clone" commit -qm many
touch "$SYNC_CAPTURE.wipe"
sync_now >/dev/null 2>&1
status=$?
rm "$SYNC_CAPTURE.wipe"
check "a capture that deletes too much is reported" test "$status" -eq 1
check "a capture that deletes too much keeps the files" test -f "$clone/home/many-1"

before="$(find "$work/legion/home" -type f | wc -l)"
on legion --all --hardware --dry-run >/dev/null 2>&1
check "dry run writes nothing" test "$(find "$work/legion/home" -type f | wc -l)" -eq "$before"

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
