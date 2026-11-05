#!/usr/bin/env bash
# Applies this CachyOS + KDE Plasma 6 setup. See README.md.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state="$HOME/.local/state/cachyos-dotfiles"
run_dir="$state/backup-$(date +%Y%m%d-%H%M%S)-$$"
dry_run=0
changed=0
failures=()
only=""
do_packages=0 do_themes=0 do_dotfiles=0 do_plasma=0 do_hardware=0 do_detect=0 do_undo=0
components="shell terminal editors audio desktop shortcuts"
required_widgets="com.jaxparrow07.nothingkdewidgets.media com.jaxparrow07.nothingkdewidgets.weather
luisbocanegra.audio.visualizer luisbocanegra.panel.colorizer org.kde.plasma.clearclock
org.kde.plasma.kvitals org.cachyos.discordvoice"
# Let the tests stand in for the system and the theme list. Unset on real runs.
sysroot="${DOTFILES_SYSROOT:-}"
sources="${DOTFILES_SOURCES:-$repo/themes/sources.tsv}"

usage() {
    cat <<'USAGE'
Usage: ./install.sh [options]

  --packages       install package groups (asks about each one)
  --themes         fetch themes, icons, cursors and widgets from upstream
  --dotfiles       copy configs (asks about each part)
  --only LIST      with --dotfiles, copy only these parts, comma separated:
                   shell, terminal, editors, audio, desktop, shortcuts, or all
  --plasma         apply the panel and widget layout
  --hardware       detects your PC and offers GPU packages and device extras,
                   never included in --all
  --detect         show what was detected in this PC and exit
  --undo           put back what the most recent run changed
  --all            packages, themes, dotfiles and plasma
  --dry-run        show what would happen and change nothing
  -h, --help       show this help

With no options, a menu asks what to apply.
USAGE
}

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
failed() { warn "$1"; failures+=("$1"); }

run() {
    if [ "$dry_run" -eq 1 ]; then
        printf 'would run: %s\n' "$*"
    else
        "$@"
    fi
}

ask() {
    [ "$dry_run" -eq 1 ] && return 0
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy] ]]
}

list() { grep -vE '^\s*(#|$)' "$1"; }

detect() {
    gpus="$(lspci -nn 2>/dev/null | grep -E 'VGA compatible|3D controller|Display controller' || true)"
    gpu_count=0
    [ -z "$gpus" ] || gpu_count="$(printf '%s\n' "$gpus" | wc -l)"

    cpu="$(sed -n 's/^vendor_id[[:space:]]*: *//p;T;q' "$sysroot/proc/cpuinfo" 2>/dev/null || true)"
    case "$cpu" in
        GenuineIntel) cpu=Intel ;;
        AuthenticAMD) cpu=AMD ;;
        *) cpu=unknown ;;
    esac

    product="$(cat "$sysroot/sys/class/dmi/id/product_version" 2>/dev/null || true)"
    case "$(cat "$sysroot/sys/class/dmi/id/chassis_type" 2>/dev/null || true)" in
        8|9|10|11|14|30|31|32) chassis=laptop ;;
        *) chassis=desktop ;;
    esac

    screens="$(grep -lx connected "$sysroot"/sys/class/drm/*/status 2>/dev/null | wc -l || true)"
    [ "$screens" -ge 1 ] || screens=1
}

has_gpu() { printf '%s\n' "$gpus" | grep -Eq "$1"; }

show_detected() {
    say "Detected"
    printf '  CPU:      %s\n' "$cpu"
    printf '  Type:     %s\n' "$chassis"
    printf '  Monitors: %s\n' "$screens"
    printf '  GPUs:     %s\n' "$gpu_count"
    if [ -n "$gpus" ]; then printf '%s\n' "$gpus" | sed -E 's/^[^ ]+ [^:]*: /    /'; fi
}

usb_present() {
    # usb_present <vendor id> [product id]
    local dir
    for dir in "$sysroot"/sys/bus/usb/devices/*; do
        [ "$(cat "$dir/idVendor" 2>/dev/null || true)" = "$1" ] || continue
        if [ -z "${2:-}" ] || [ "$(cat "$dir/idProduct" 2>/dev/null || true)" = "$2" ]; then
            return 0
        fi
    done
    return 1
}

# Every change is recorded in $run_dir so that --undo can reverse it.
record() {
    mkdir -p "$run_dir"
    printf '%s\n' "$1" >> "$run_dir/changes.txt"
}

same() {
    # same <source> <path in $HOME>
    if [ -L "$1" ]; then
        [ -L "$2" ] && [ "$(readlink "$1")" = "$(readlink "$2")" ]
    else
        [ -f "$2" ] && [ ! -L "$2" ] && cmp -s "$1" "$2"
    fi
}

place() {
    # place <source file or symlink> <path relative to $HOME>
    local src="$1" rel="$2"
    same "$src" "$HOME/$rel" && return 0
    if [ "$dry_run" -eq 1 ]; then
        printf 'would write: ~/%s\n' "$rel"
        return 0
    fi
    if [ -e "$HOME/$rel" ] || [ -L "$HOME/$rel" ]; then
        mkdir -p "$run_dir/files/$(dirname "$rel")"
        cp -a "$HOME/$rel" "$run_dir/files/$rel"
        rm -f -- "$HOME/$rel"
    else
        record "file $rel"
    fi
    mkdir -p "$HOME/$(dirname "$rel")"
    cp -P "$src" "$HOME/$rel"
    changed=$((changed + 1))
}

# Prints the packages from a list that the configured repos offer, and warns
# about the rest. A single unknown name would otherwise fail the whole group.
available() {
    local known pkg skipped=""
    known="$(pacman -Slq 2>/dev/null | sort -u)"
    while read -r pkg; do
        # A here-string, as grep -q in a pipe can kill the writer and fail under pipefail.
        if grep -Fxq -- "$pkg" <<< "$known"; then
            printf '%s\n' "$pkg"
        else
            skipped="$skipped $pkg"
        fi
    done < <(list "$1")
    if [ -n "$skipped" ]; then warn "not in your repos, skipping:$skipped"; fi
}

install_group() {
    # install_group <packages file name> <question>
    local names
    if ! ask "$2 ($(list "$repo/packages/$1.txt" | tr '\n' ' '))?"; then return 0; fi
    names="$(available "$repo/packages/$1.txt" | tr '\n' ' ')"
    [ -n "$names" ] || return 0
    # shellcheck disable=SC2086
    run sudo pacman -S --needed $names || failed "installing the $1 packages"
}

install_packages() {
    local group
    for group in desktop apps dev gaming; do
        install_group "$group" "Install the '$group' packages"
    done

    local helper=""
    if command -v paru >/dev/null; then
        helper=paru
    elif command -v yay >/dev/null; then
        helper=yay
    fi
    if [ -z "$helper" ]; then
        warn "no AUR helper found, skipping packages/aur.txt"
    elif ask "Install the AUR packages one by one (asks about each)?"; then
        local pkg
        # The list is on fd 3 so prompts and paru can still read the keyboard.
        while read -r pkg <&3; do
            if ask "  Install $pkg from the AUR?"; then
                run "$helper" -S --needed "$pkg" || failed "installing $pkg from the AUR"
            fi
        done 3< <(list "$repo/packages/aur.txt")
    fi

    if ! command -v flatpak >/dev/null; then
        warn "flatpak not installed, skipping packages/flatpak.txt"
    elif ask "Install the Flatpak apps?"; then
        # shellcheck disable=SC2046
        run flatpak install flathub $(list "$repo/packages/flatpak.txt") || failed "installing Flatpak apps"
    fi
}

fetch_source() {
    # fetch_source <url> <commit> <folder>
    [ ! -d "$3" ] || return 0
    git clone -q --filter=blob:none --no-checkout "$1" "$3" &&
        git -C "$3" checkout -q "$2"
}

install_widget() {
    local dir="$1" id
    id="$(sed -nE 's/^\s*"Id": *"([^"]+)".*/\1/p' "$dir/metadata.json" | head -n1)"
    if [ -n "$id" ] && [ ! -d "$HOME/.local/share/plasma/plasmoids/$id" ]; then
        kpackagetool6 -t Plasma/Applet -i "$dir" >/dev/null && record "plasmoid $id"
    else
        kpackagetool6 -t Plasma/Applet -u "$dir" >/dev/null
    fi
}

# Layan draws a blue line on the panel while a widget's popup is open. Use the text
# colour instead, so it's white on a dark theme. Changes the download before it's
# placed, so a second run and --undo treat it like any other theme file.
whiten_open_widget_line() {
    local svg="$1/widgets/tabbar.svgz"
    [ -f "$svg" ] || return 0
    gzip -dc "$svg" | sed 's/ColorScheme-ButtonFocus/ColorScheme-Text/g' | gzip -9n > "$svg.new" &&
        mv "$svg.new" "$svg"
}

install_themes() {
    local work="" name kind url commit subpath target dir file
    [ "$dry_run" -eq 1 ] || work="$(mktemp -d)"
    while IFS=$'\t' read -r name kind url commit subpath target <&3; do
        case "$name" in '#'*|'') continue ;; esac
        say "$name"
        if [ "$dry_run" -eq 1 ]; then
            printf 'would fetch %s at %s (%s)\n' "$url" "${commit:0:7}" "$subpath"
            continue
        fi
        dir="$work/$(printf '%s %s' "$url" "$commit" | sha1sum | cut -c1-12)"
        if ! fetch_source "$url" "$commit" "$dir"; then
            failed "couldn't download $name"
            continue
        fi
        case "$kind" in
            dir)
                case "$target" in
                    .local/share/plasma/desktoptheme/*) whiten_open_widget_line "$dir/$subpath" ;;
                esac
                while IFS= read -r -d '' file; do
                    place "$file" "$target/${file#"$dir/$subpath/"}"
                done < <(cd "$dir" && find "$PWD/$subpath" -path '*/.git' -prune -o \( -type f -o -type l \) -print0 |
                    sed -z 's#/\./#/#')
                ;;
            plasmoid)
                install_widget "$dir/$subpath" || failed "couldn't install $name"
                ;;
            *) warn "unknown kind '$kind' for $name" ;;
        esac
    done 3< "$sources"
    # Stored here rather than fetched. widgets/discord-voice/setup.sh connects it.
    say "Discord Voice"
    if [ "$dry_run" -eq 1 ]; then
        printf 'would install widgets/discord-voice\n'
    else
        install_widget "$repo/widgets/discord-voice/package" || failed "couldn't install Discord Voice"
    fi
}

component_of() {
    case "$1" in
        .config/fish/*) echo shell ;;
        .config/alacritty/*|.config/konsolerc|.config/fastfetch/*) echo terminal ;;
        .config/zed/*|.config/micro/*) echo editors ;;
        .config/cava/*) echo audio ;;
        .config/kglobalshortcutsrc) echo shortcuts ;;
        *) echo desktop ;;
    esac
}

# Helvetica is a commercial font, so most people need a stand-in.
with_font() {
    # with_font <file>: prints a path to use in its place
    if grep -q Helvetica "$1" && ! grep -qi helvetica <<< "$(fc-list 2>/dev/null)"; then
        local swapped
        swapped="$(mktemp)"
        sed 's/Helvetica/Noto Sans/g' "$1" > "$swapped"
        printf '%s\n' "$swapped"
    else
        printf '%s\n' "$1"
    fi
}

install_dotfiles() {
    local part chosen=" " src rel
    if [ "$only" = all ]; then
        chosen=" $components "
    elif [ -n "$only" ]; then
        for part in ${only//,/ }; do
            [[ " $components " == *" $part "* ]] || die "unknown part: $part (choose from: $components)"
            chosen="$chosen$part "
        done
    else
        for part in $components; do
            if ask "Copy the '$part' configs?"; then chosen="$chosen$part "; fi
        done
    fi
    while IFS= read -r -d '' src; do
        rel="${src#"$repo/home/"}"
        [[ "$chosen" == *" $(component_of "$rel") "* ]] || continue
        place "$(with_font "$src")" "$rel"
    done < <(find "$repo/home" -type f -print0)
    if [[ "$chosen" == *" desktop "* ]]; then install_icons; fi
}

# Custom app icons are applied to this PC's own launchers, so apps it doesn't have
# get no dead menu entries.
install_icons() {
    local image entry icon dir rendered
    for image in "$repo"/icons/custom-*; do
        [ -e "$image" ] || continue
        place "$image" ".local/share/icons/${image##*/}"
    done
    [ -f "$repo/icons/overrides.tsv" ] || return 0
    while IFS=$'\t' read -r entry icon; do
        for dir in "$sysroot/usr/share/applications" "$sysroot/var/lib/flatpak/exports/share/applications"; do
            [ -f "$dir/$entry" ] || continue
            rendered="$(mktemp)"
            sed "0,/^Icon=/s#^Icon=.*#Icon=$icon#" "$dir/$entry" > "$rendered"
            place "$rendered" ".local/share/applications/$entry"
            break
        done
    done < "$repo/icons/overrides.tsv"
    run kbuildsycoca6 >/dev/null 2>&1 || true
}

# Keeps only the dock shortcuts for apps this PC actually has.
launchers_for_this_pc() {
    local line kept="" item app dir
    line="$(sed -n 's/^launchers=//p' "$repo/plasma/plasma-org.kde.plasma.desktop-appletsrc" | head -n1)"
    for item in ${line//,/ }; do
        app="${item#applications:}"
        if [ "$app" = "$item" ]; then
            kept="$kept,$item"
            continue
        fi
        for dir in "$sysroot/usr/share/applications" "$HOME/.local/share/applications" \
            "$sysroot/var/lib/flatpak/exports/share/applications"; do
            if [ -e "$dir/$app" ]; then
                kept="$kept,$item"
                break
            fi
        done
    done
    printf '%s\n' "${kept#,}"
}

# The dock and widgets live on the second screen of the three-monitor original.
# With fewer than three monitors, swap screens 0 and 1 so they land on the main one.
render_layout() {
    # render_layout <monitor count> <activity id> <home folder>
    local swap='s/^$/&/'
    if [ "$1" -lt 3 ]; then
        swap='s/^lastScreen=0$/lastScreen=@ONE@/; s/^lastScreen=1$/lastScreen=0/; s/^lastScreen=@ONE@$/lastScreen=1/'
    fi
    sed -e "$swap" -e "s#@HOME@#$3#g" -e "s#@ACTIVITY@#$2#g" \
        -e "s#^launchers=.*#launchers=$(launchers_for_this_pc)#" \
        "$repo/plasma/plasma-org.kde.plasma.desktop-appletsrc"
}

missing_widgets() {
    local id
    for id in $required_widgets; do
        [ -d "$HOME/.local/share/plasma/plasmoids/$id" ] ||
            [ -d "$sysroot/usr/share/plasma/plasmoids/$id" ] || printf '%s ' "$id"
    done
}

install_plasma() {
    local rel=".config/plasma-org.kde.plasma.desktop-appletsrc" rendered activity="" missing
    say "Fitting the layout to $screens monitor(s)"
    warn "The weather location isn't included. Set your own afterwards."
    missing="$(missing_widgets)"
    if [ -n "$missing" ] && [ "$dry_run" -eq 0 ]; then
        warn "these widgets aren't installed yet, run --themes first: $missing"
        ask "Apply the layout without them?" || return 0
    fi
    ask "Replace your panel and widget layout?" || return 0

    if command -v qdbus6 >/dev/null; then
        activity="$(qdbus6 org.kde.ActivityManager /ActivityManager/Activities CurrentActivity 2>/dev/null || true)"
    fi
    rendered="$(mktemp)"
    render_layout "$screens" "$activity" "$HOME" > "$rendered"

    # Bring the shell back even if something below fails.
    trap 'kstart plasmashell >/dev/null 2>&1 || true' EXIT
    run kquitapp6 plasmashell || true
    local image
    for image in "$repo"/wallpapers/*; do
        place "$image" ".local/share/wallpapers/cachyos-dotfiles/${image##*/}"
    done
    install_icons
    place "$rendered" "$rel"
    if [ -f "$repo/plasma/kscreenlockerrc" ]; then
        local lock
        lock="$(mktemp)"
        sed "s#@HOME@#$HOME#g" "$repo/plasma/kscreenlockerrc" > "$lock"
        place "$lock" .config/kscreenlockerrc
    fi
    trap - EXIT
    run kstart plasmashell || failed "couldn't restart Plasma, log out and back in"
}

install_rule() {
    # install_rule <file> <description>
    ask "Install the udev rule for your $2?" || return 1
    run sudo install -m644 "$repo/hardware/peripherals/$1" /etc/udev/rules.d/
}

install_sidebar_fix() {
    local dir="$repo/hardware/plasma-sidebar"
    ask "Install the pacman hook that keeps the Add Widgets sidebar on the right monitor?" || return 0
    run sudo install -Dm755 "$dir/fix-plasma-sidebar" "$sysroot/usr/local/bin/fix-plasma-sidebar" &&
        run sudo install -Dm644 "$dir/fix-plasma-sidebar.hook" "$sysroot/etc/pacman.d/hooks/fix-plasma-sidebar.hook" &&
        run sudo "$dir/fix-plasma-sidebar" "$sysroot/usr/share/plasma/shells/org.kde.plasma.desktop/contents/views/Desktop.qml" ||
        failed "installing the sidebar fix"
}

install_hardware() {
    show_detected

    if [ "$screens" -ge 2 ]; then install_sidebar_fix; fi

    if has_gpu 'NVIDIA'; then
        install_group gpu-nvidia "Install NVIDIA tools"
        if [ ! -d "$sysroot/sys/module/nvidia" ]; then
            warn "The NVIDIA driver isn't loaded. On CachyOS, set it up with: sudo chwd -a"
        fi
    fi
    if has_gpu 'AMD|ATI'; then install_group gpu-amd "Install AMD graphics packages"; fi
    if has_gpu 'Intel'; then install_group gpu-intel "Install Intel graphics packages"; fi
    if [ "$chassis" = laptop ] && [ "$gpu_count" -ge 2 ]; then
        install_group gpu-hybrid "Install dual-GPU laptop tools"
    fi

    if [[ "$product" == *Legion* ]]; then
        install_group legion "Install Lenovo Legion controls"
        say "Legion notes: hardware/legion-pro-7/README.md"
    fi

    local installed=0
    if usb_present 3329; then
        if install_rule 70-audeze-maxwell.rules "Audeze headset"; then installed=1; fi
    fi
    if usb_present 0c45 800a; then
        if install_rule 70-epomaker-th99pro.rules "EPOMAKER keyboard"; then installed=1; fi
    fi
    if [ "$installed" -eq 1 ]; then
        run sudo udevadm control --reload
        run sudo udevadm trigger
    fi
    say "Boot and monitor fixes are manual: see hardware/README.md"
}

undo_last() {
    local run="" dir kind value
    while IFS= read -r dir; do
        if [ ! -e "$dir/undone" ]; then
            run="$dir"
            break
        fi
    done < <(find "$state" -maxdepth 1 -type d -name 'backup-*' 2>/dev/null | sort -r)
    [ -n "$run" ] || die "nothing to undo"

    say "Undoing the run from ${run##*/backup-}"
    if [ "$dry_run" -eq 1 ]; then
        [ ! -f "$run/changes.txt" ] || sed 's/^/would remove: /' "$run/changes.txt"
        [ ! -d "$run/files" ] || find "$run/files" \( -type f -o -type l \) -printf 'would restore: ~/%P\n'
        return 0
    fi
    ask "Put everything from that run back?" || return 0

    # Plasma saves its layout as it quits, which would undo the restore.
    local layout=".config/plasma-org.kde.plasma.desktop-appletsrc" shell_stopped=0
    if [ -e "$run/files/$layout" ] || grep -qxF "file $layout" "$run/changes.txt" 2>/dev/null; then
        trap 'kstart plasmashell >/dev/null 2>&1 || true' EXIT
        kquitapp6 plasmashell >/dev/null 2>&1 || true
        shell_stopped=1
    fi

    if [ -f "$run/changes.txt" ]; then
        while read -r kind value; do
            case "$kind" in
                file)
                    rm -f -- "$HOME/$value"
                    (cd "$HOME" && rmdir -p --ignore-fail-on-non-empty -- "$(dirname "$value")" 2>/dev/null) || true
                    ;;
                plasmoid)
                    kpackagetool6 -t Plasma/Applet -r "$value" >/dev/null || failed "couldn't remove widget $value"
                    ;;
            esac
        done < "$run/changes.txt"
    fi
    if [ -d "$run/files" ]; then cp -a "$run/files/." "$HOME/"; fi
    if [ "$shell_stopped" -eq 1 ]; then
        trap - EXIT
        kstart plasmashell >/dev/null 2>&1 || failed "couldn't restart Plasma, log out and back in"
    fi
    : > "$run/undone"
    say "Done. Packages stay installed. Log out and back in to see every change."
}

menu() {
    if ask "Install packages?"; then do_packages=1; fi
    if ask "Fetch themes and widgets?"; then do_themes=1; fi
    if ask "Copy configs?"; then do_dotfiles=1; fi
    if ask "Apply the panel layout?"; then do_plasma=1; fi
    if ask "Check this PC for GPU packages and device extras?"; then do_hardware=1; fi
}

no_flags=0
[ "$#" -gt 0 ] || no_flags=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --packages) do_packages=1 ;;
        --themes) do_themes=1 ;;
        --dotfiles) do_dotfiles=1 ;;
        --only)
            [ "$#" -ge 2 ] || die "--only needs a list of parts"
            only="$2"
            do_dotfiles=1
            shift
            ;;
        --plasma) do_plasma=1 ;;
        --hardware) do_hardware=1 ;;
        --detect) do_detect=1 ;;
        --undo) do_undo=1 ;;
        --all) do_packages=1 do_themes=1 do_dotfiles=1 do_plasma=1 ;;
        --dry-run) dry_run=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root"
[ -f "$sysroot/etc/arch-release" ] || die "this setup is for CachyOS or other Arch-based systems"
if [ "${KDE_SESSION_VERSION:-}" != "6" ]; then
    warn "you don't appear to be in a Plasma 6 session"
fi
if ! grep -q '^ID=cachyos' "$sysroot/etc/os-release" 2>/dev/null; then
    warn "not CachyOS: the gaming packages need the CachyOS repos"
fi

detect
if [ "$do_detect" -eq 1 ]; then show_detected; exit 0; fi
if [ "$do_undo" -eq 1 ]; then undo_last; exit 0; fi

if [ "$no_flags" -eq 1 ]; then menu; fi

if [ "$do_packages" -eq 1 ]; then say "Packages"; install_packages; fi
if [ "$do_themes" -eq 1 ]; then say "Themes and widgets"; install_themes; fi
if [ "$do_dotfiles" -eq 1 ]; then say "Configs"; install_dotfiles; fi
if [ "$do_plasma" -eq 1 ]; then say "Panel layout"; install_plasma; fi
if [ "$do_hardware" -eq 1 ]; then say "Hardware"; install_hardware; fi

if [ "$changed" -gt 0 ]; then
    say "Changed $changed files. To put them back: ./install.sh --undo"
fi
if [ "${#failures[@]}" -gt 0 ]; then
    warn "${#failures[@]} step(s) didn't finish:"
    printf '  - %s\n' "${failures[@]}" >&2
    exit 1
fi
say "Done. Log out and back in to see every change."
