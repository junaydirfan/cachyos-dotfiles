# cachyos-dotfiles

My CachyOS desktop: KDE Plasma 6 on Wayland, with the Layan theme, YAMIS icons and WhiteSur cursors. It includes configs,
package lists, and an installer that backs up anything it replaces.

Built on a Lenovo Legion Pro 7 (i9-14900HX, RTX 4080 Max-Q) with fish, Limine and btrfs.

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
| `--dotfiles` | Copies `home/` into your home folder: Plasma, KWin, shortcuts, fish, Alacritty, fastfetch, Zed, micro, cava. |
| `--plasma` | Applies the panel and widget layout, then restarts the Plasma shell. |
| `--hardware` | Legion Pro 7 packages and udev rules. Never part of `--all`. See [the hardware notes](hardware/legion-pro-7/README.md). |
| `--all` | Everything except `--hardware`. |
| `--dry-run` | Shows what would happen. |

## Before you run it

- Anything replaced is backed up to `~/.local/state/cachyos-dotfiles/`, and the installer prints the restore command.
- The panel layout was made for three monitors and 150% scaling.
- Wallpapers, the weather location and the Helvetica UI font aren't included.
- Tested on my own machine, not yet on a clean install. Please open an issue if something breaks.

More help is in [troubleshooting](docs/troubleshooting.md).

## Credits

Themes and widgets belong to their authors and keep their own licenses:

- [Layan](https://github.com/vinceliuice/Layan-kde) and [WhiteSur cursors](https://github.com/vinceliuice/WhiteSur-cursors) by vinceliuice
- [YAMIS](https://bitbucket.org/dirn-typo/yet-another-monochrome-icon-set) by dirn
- [ClearClock](https://github.com/qewer33/ClearClock), [KVitals](https://github.com/yassine20011/kvitals),
  [PlasMusic Toolbar](https://github.com/ccatterina/plasmusic-toolbar), [Nothing KDE Widgets](https://github.com/jaxparrow07/nothing-kde-widgets),
  [Panel Colorizer](https://github.com/luisbocanegra/plasma-panel-colorizer) and [Plasma Audio Visualizer](https://github.com/luisbocanegra/plasma-audio-visualizer)

My own files are under the [MIT License](LICENSE).
