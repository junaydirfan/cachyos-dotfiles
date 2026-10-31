# Troubleshooting

**Undo everything.** The installer prints a restore command when it finishes. Backups are in
`~/.local/state/cachyos-dotfiles/`. Copy one back, then log out and in:

```bash
cp -a ~/.local/state/cachyos-dotfiles/backup-<timestamp>/. "$HOME/"
```

**Panels look wrong or are missing.** The installer puts the dock and widgets on your main monitor, but a different
monitor order can still put them on the wrong screen. Right-click the desktop, choose Enter Edit Mode, and add or move
panels.

**A widget shows an error or is blank.** Run `./install.sh --themes` again. Panel Colorizer and Audio Visualizer also
ship a compiled plugin that the installer doesn't build. If a feature is missing, follow their READMEs.

**The font looks different.** The UI font is Helvetica, a commercial font that isn't included, so Plasma falls back to
another one. Choose a font in System Settings under Text & Fonts.

**The wallpaper changed to the default.** Wallpapers aren't included. Set your own.

**Graphics feel slow, or games won't start.** Run `./install.sh --detect` to check your GPU was found, then run
`sudo chwd -a` to set up the driver on CachyOS.

**The dock has shortcuts to apps you don't have.** Right-click the shortcut and unpin it.
