# Troubleshooting

**Undo the last run.** This restores replaced files and removes new ones. Run it again to step back another run.
Installed packages stay.

```bash
./install.sh --undo
```

Then log out and back in.

**Something failed partway.** The installer finishes what it can and lists what didn't work. Fix the cause, often your
internet connection, and run the same command again. Finished steps won't repeat.

**Panels look wrong or are missing.** The installer puts the dock and widgets on your main monitor, but a different
monitor order can still put them on the wrong screen. Right-click the desktop, choose Enter Edit Mode, and add or move
panels.

**A widget shows an error or is blank.** Run `./install.sh --themes` again. Panel Colorizer and Audio Visualizer also
ship a compiled plugin that the installer doesn't build. If a feature is missing, follow their READMEs.

**The font looks different.** The UI font is Helvetica, a commercial font that isn't included. Without it you get Noto
Sans. Choose another in System Settings under Text & Fonts.

**Graphics feel slow, or games won't start.** Run `./install.sh --detect` to check your GPU was found, then run
`sudo chwd -a` to set up the driver on CachyOS.

**A dock shortcut is missing.** Shortcuts are left out for apps you don't have. Install the app, then pin it from the
launcher.
