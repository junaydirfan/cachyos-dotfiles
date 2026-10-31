#!/usr/bin/env bash
# Applies this CachyOS + KDE Plasma 6 setup. See README.md.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stamp="$(date +%Y%m%d-%H%M%S)"
backup="$HOME/.local/state/cachyos-dotfiles/backup-$stamp"
dry_run=0
backed_up=0
do_packages=0 do_themes=0 do_dotfiles=0 do_plasma=0 do_hardware=0 do_detect=0
# Lets the tests stand in for /sys and /proc. Empty on real runs.
sysroot="${DOTFILES_SYSROOT:-}"

usage() {
    cat <<'USAGE'
Usage: ./install.sh [options]

  --packages   install package groups (asks about each one)
  --themes     fetch themes, icons, cursors and widgets from upstream
  --dotfiles   copy app and desktop configs into your home folder
  --plasma     apply the panel and widget layout
  --hardware   detects your PC and offers GPU packages and device extras,
               never included in --all
  --detect     show what was detected in this PC and exit
  --all        packages, themes, dotfiles and plasma
  --dry-run    show what would happen and change nothing
  -h, --help   show this help

With no options, a menu asks what to apply.
USAGE
}

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

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

offer_group() {
    # offer_group <packages file name> <description>
    if ask "Install $2 ($(list "$repo/packages/$1.txt" | tr '\n' ' '))?"; then
        # shellcheck disable=SC2046
        run sudo pacman -S --needed $(list "$repo/packages/$1.txt")
    fi
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

# Saves a file or folder from $HOME before it gets replaced.
save() {
    local rel="$1"
    [ -e "$HOME/$rel" ] || return 0
    # Keep the first copy if several steps touch the same target.
    [ ! -e "$backup/$rel" ] || return 0
    if [ "$dry_run" -eq 1 ]; then
        printf 'would back up: ~/%s\n' "$rel"
        return 0
    fi
    mkdir -p "$backup/$(dirname "$rel")"
    cp -a "$HOME/$rel" "$backup/$rel"
    backed_up=$((backed_up + 1))
}

place() {
    # place <source file> <path relative to $HOME>
    local src="$1" rel="$2"
    if [ -f "$HOME/$rel" ] && cmp -s "$src" "$HOME/$rel"; then
        return 0
    fi
    save "$rel"
    if [ "$dry_run" -eq 1 ]; then
        printf 'would write: ~/%s\n' "$rel"
    else
        mkdir -p "$HOME/$(dirname "$rel")"
        cp "$src" "$HOME/$rel"
    fi
}

install_packages() {
    local group
    for group in desktop apps dev gaming; do
        ask "Install the '$group' packages ($(list "$repo/packages/$group.txt" | wc -l) packages)?" || continue
        # shellcheck disable=SC2046
        run sudo pacman -S --needed $(list "$repo/packages/$group.txt")
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
                run "$helper" -S --needed "$pkg"
            fi
        done 3< <(list "$repo/packages/aur.txt")
    fi

    if ! command -v flatpak >/dev/null; then
        warn "flatpak not installed, skipping packages/flatpak.txt"
    elif ask "Install the Flatpak apps?"; then
        # shellcheck disable=SC2046
        run flatpak install flathub $(list "$repo/packages/flatpak.txt")
    fi
}

install_themes() {
    local work="" name kind url subpath target dir
    [ "$dry_run" -eq 1 ] || work="$(mktemp -d)"
    while IFS=$'\t' read -r name kind url subpath target <&3; do
        case "$name" in '#'*|'') continue ;; esac
        say "$name"
        if [ "$dry_run" -eq 1 ]; then
            printf 'would fetch %s (%s) as %s\n' "$url" "$subpath" "$kind"
            continue
        fi
        dir="$work/$(printf '%s' "$url" | sha1sum | cut -c1-12)"
        [ -d "$dir" ] || git clone -q --depth 1 "$url" "$dir"
        case "$kind" in
            dir)
                save "$target"
                mkdir -p "$HOME/$target"
                tar -C "$dir/$subpath" --exclude=.git -cf - . | tar -C "$HOME/$target" -xf -
                ;;
            plasmoid)
                kpackagetool6 -t Plasma/Applet -i "$dir/$subpath" 2>/dev/null ||
                    kpackagetool6 -t Plasma/Applet -u "$dir/$subpath"
                ;;
            *) warn "unknown kind '$kind' for $name" ;;
        esac
    done 3< "$repo/themes/sources.tsv"
}

install_dotfiles() {
    local src rel
    while IFS= read -r -d '' src; do
        rel="${src#"$repo/home/"}"
        place "$src" "$rel"
    done < <(find "$repo/home" -type f -print0)
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
        "$repo/plasma/plasma-org.kde.plasma.desktop-appletsrc"
}

install_plasma() {
    local rel=".config/plasma-org.kde.plasma.desktop-appletsrc" rendered activity=""
    say "Fitting the layout to $screens monitor(s)"
    warn "Wallpapers and the weather location are not included. Set your own afterwards."
    ask "Replace your panel and widget layout?" || return 0

    if command -v qdbus6 >/dev/null; then
        activity="$(qdbus6 org.kde.ActivityManager /ActivityManager/Activities CurrentActivity 2>/dev/null || true)"
    fi
    rendered="$(mktemp)"
    render_layout "$screens" "$activity" "$HOME" > "$rendered"

    run kquitapp6 plasmashell || true
    place "$rendered" "$rel"
    run kstart plasmashell
}

install_hardware() {
    show_detected

    if has_gpu 'NVIDIA'; then
        offer_group gpu-nvidia "NVIDIA tools"
        if [ ! -d "$sysroot/sys/module/nvidia" ]; then
            warn "The NVIDIA driver isn't loaded. On CachyOS, set it up with: sudo chwd -a"
        fi
    fi
    if has_gpu 'AMD|ATI'; then offer_group gpu-amd "AMD graphics packages"; fi
    if has_gpu 'Intel'; then offer_group gpu-intel "Intel graphics packages"; fi
    if [ "$chassis" = laptop ] && [ "$gpu_count" -ge 2 ]; then
        offer_group gpu-hybrid "dual-GPU laptop tools"
    fi

    if [[ "$product" == *Legion* ]]; then
        offer_group legion "Lenovo Legion controls"
        say "Legion notes: hardware/legion-pro-7/README.md"
    fi

    local installed=0
    if usb_present 3329; then
        install_rule 70-audeze-maxwell.rules "Audeze headset" && installed=1
    fi
    if usb_present 0c45 800a; then
        install_rule 70-epomaker-th99pro.rules "EPOMAKER keyboard" && installed=1
    fi
    if [ "$installed" -eq 1 ]; then
        run sudo udevadm control --reload
        run sudo udevadm trigger
    fi
    say "Boot and monitor fixes are manual: see hardware/README.md"
}

install_rule() {
    # install_rule <file> <description>
    ask "Install the udev rule for your $2?" || return 1
    run sudo install -m644 "$repo/hardware/peripherals/$1" /etc/udev/rules.d/
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
        --plasma) do_plasma=1 ;;
        --hardware) do_hardware=1 ;;
        --detect) do_detect=1 ;;
        --all) do_packages=1 do_themes=1 do_dotfiles=1 do_plasma=1 ;;
        --dry-run) dry_run=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root"
[ -f /etc/arch-release ] || die "this setup is for CachyOS or other Arch-based systems"
if [ "${KDE_SESSION_VERSION:-}" != "6" ]; then
    warn "you don't appear to be in a Plasma 6 session"
fi
if ! grep -q '^ID=cachyos' /etc/os-release 2>/dev/null; then
    warn "not CachyOS: the gaming packages and fish config need the CachyOS repos"
fi

detect
if [ "$do_detect" -eq 1 ]; then show_detected; exit 0; fi

if [ "$no_flags" -eq 1 ]; then menu; fi

if [ "$do_packages" -eq 1 ]; then say "Packages"; install_packages; fi
if [ "$do_themes" -eq 1 ]; then say "Themes and widgets"; install_themes; fi
if [ "$do_dotfiles" -eq 1 ]; then say "Configs"; install_dotfiles; fi
if [ "$do_plasma" -eq 1 ]; then say "Panel layout"; install_plasma; fi
if [ "$do_hardware" -eq 1 ]; then say "Hardware"; install_hardware; fi

if [ "$backed_up" -gt 0 ]; then
    say "Backed up $backed_up items. To restore them:"
    printf '  cp -a "%s/." "$HOME/"\n' "$backup"
fi
say "Done. Log out and back in to see every change."
