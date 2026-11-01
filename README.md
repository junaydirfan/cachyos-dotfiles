# cachyos-dotfiles

My CachyOS desktop: KDE Plasma 6 on Wayland, with the Layan theme, YAMIS icons and WhiteSur cursors. It includes configs,
package lists, and an installer that backs up anything it replaces.

It's made to work on any PC running CachyOS with KDE Plasma: desktop or laptop, with Intel or AMD processors and Intel,
AMD or NVIDIA graphics. Coming from Windows? Start with [this short guide](docs/coming-from-windows.md).

I built it on a Lenovo Legion Pro 7 with fish, Limine and btrfs, but you don't need any of that hardware.

## Quick start

```bash
git clone https://github.com/junaydirfan/cachyos-dotfiles
```

```bash
cd cachyos-dotfiles
```

Preview first. This changes nothing:

```bash
./install.sh --all --dry-run
```

Then run the menu, which asks about each part:

```bash
./install.sh
```

Log out and back in when it finishes.

## What each part does

| Option | What it does |
| --- | --- |
| `--packages` | Installs package groups from `packages/`, asking about each. AUR packages are confirmed one by one. |
| `--themes` | Fetches themes, icons, cursors and widgets from their authors. See `themes/sources.tsv`. |
| `--dotfiles` | Copies configs into your home folder, asking about each part. |
| `--only LIST` | Copies just the parts you name, with no prompts. See below. |
| `--plasma` | Applies the panel and widget layout and the three wallpapers, then restarts the Plasma shell. |
| `--hardware` | Detects your PC and offers matching GPU packages and device extras. Never part of `--all`. See [hardware support](hardware/README.md). |
| `--undo` | Puts back what the most recent run changed. |
| `--detect` | Shows the CPU, GPUs, monitors and PC type it found, then exits. |
| `--all` | Everything except `--hardware`. |
| `--dry-run` | Shows what would happen. |

## Pick only what you want

You don't have to take the whole setup. Configs come in parts:

| Part | Includes |
| --- | --- |
| `shell` | fish |
| `terminal` | Alacritty, Konsole, fastfetch |
| `editors` | Zed, micro |
| `audio` | cava |
| `desktop` | KWin, colors, fonts, Dolphin, GTK apps, mouse cursor |
| `shortcuts` | Keyboard shortcuts, which replace your own |

For example, to copy just the terminal and shell configs:

```bash
./install.sh --only terminal,shell
```

## Before you run it

- `./install.sh --undo` reverses the last run: it restores replaced files and removes new ones. Installed packages stay.
- Your default apps and display scaling are left alone.
- If one download or package fails, the rest still install and you get a list of what didn't finish.
- Themes and widgets are pinned to versions in `themes/sources.tsv`, so an upstream change can't alter what you install.
- You need CachyOS with KDE Plasma. Other Arch-based systems will mostly work, but not the gaming packages or fish config.
- The panel layout fits itself to one, two or three or more monitors. Your own display scaling is kept.
- The weather location isn't included. Helvetica isn't either, so you get Noto Sans unless you have it.
- Tested on my own Intel and NVIDIA laptop, with the panel layout also run in a separate Plasma session. AMD, Intel-only
  and desktop PCs are covered by simulated tests (`tests/run.sh`), not real hardware, and nothing has run on a clean
  install yet. Please open an issue with the output of `./install.sh --detect` if something breaks.

More help is in [troubleshooting](docs/troubleshooting.md).

## Keeping the repo up to date

To capture this PC's settings and push them now:

```bash
scripts/sync-to-github.sh
```

To do that daily, or to stop:

```bash
scripts/sync-to-github.sh --install
```

```bash
scripts/sync-to-github.sh --remove
```

A sync stops and shows a notification if the capture fails or removes more than 10 files, the secret check fails, the
repo has uncommitted changes, or GitHub can't be reached. Only an unreachable GitHub leaves a commit, which the next sync
pushes.

Custom app icons are included. Set one on a launcher, or on a panel widget from `~/Pictures`, and the next sync saves it
in `icons/`. `--dotfiles` and `--plasma` apply each icon to that PC's own launcher, and skip apps it doesn't have.

## Credits

Themes and widgets belong to their authors and keep their own licenses:

- [Layan](https://github.com/vinceliuice/Layan-kde) and [WhiteSur cursors](https://github.com/vinceliuice/WhiteSur-cursors) by vinceliuice
- Wallpapers are photos from [Pexels](https://www.pexels.com/license/) by Sonny and Seven Storm Photography, and aren't covered by this repo's MIT license
- [YAMIS](https://bitbucket.org/dirn-typo/yet-another-monochrome-icon-set) by dirn
- [ClearClock](https://github.com/qewer33/ClearClock), [KVitals](https://github.com/yassine20011/kvitals),
  [PlasMusic Toolbar](https://github.com/ccatterina/plasmusic-toolbar), [Nothing KDE Widgets](https://github.com/jaxparrow07/nothing-kde-widgets),
  [Panel Colorizer](https://github.com/luisbocanegra/plasma-panel-colorizer) and [Plasma Audio Visualizer](https://github.com/luisbocanegra/plasma-audio-visualizer)

My own files are under the [MIT License](LICENSE).
