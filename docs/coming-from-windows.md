# Coming from Windows

This setup doesn't run on Windows. It's for CachyOS, a Linux system, so you'd install that first.

1. **Back up your files.** Installing an operating system can erase your drive.
2. **Install CachyOS** using the [official guide](https://wiki.cachyos.org/), and choose **KDE Plasma** as your desktop.
   If you want to keep Windows too, read the dual-boot section there first and turn off Fast Startup in Windows.
3. **Update and reboot.** Open the Konsole terminal app and run `sudo pacman -Syu`, then restart.
4. **Follow the Quick start** in the [main README](../README.md).

## Common questions

**What's a terminal?** It's an app where you type commands. On this setup that's Konsole. You can paste with
Ctrl+Shift+V.

**Do I need to install drivers?** Usually not. CachyOS sets up your graphics driver during installation.

**What does `sudo` do?** It runs a command as an administrator, like the Windows "Allow this app to make changes" prompt.
It asks for your password, and nothing appears as you type it.

**Will my Windows games work?** Many do through Steam and Proton. The optional `gaming` packages set that up. Check
[ProtonDB](https://www.protondb.com/) for specific games, especially ones with anti-cheat.

**Can I undo this?** Yes. Run `./install.sh --undo`. See [troubleshooting](troubleshooting.md) for more.
