# Legion Pro 7 16IRX9H notes

These are specific to this laptop (i9-14900HX, RTX 4080 Max-Q) and to my peripherals. Skip whatever doesn't apply.

`./install.sh --hardware` offers the Legion packages on these laptops. Everything below that touches boot is manual on
purpose, because a typo can stop your system from booting.

## Legion controls
`lenovolegionlinux` and `lenovolegionlinux-dkms` provide the Legion kernel module, fan and power controls, and a GUI.
Project: https://github.com/johnfanv2/LenovoLegionLinux

## NVIDIA in the initramfs
`/etc/mkinitcpio.conf` has:

```
MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
```

Run `sudo limine-mkinitcpio` after changing it.

## Forcing an EDID for an external monitor
I load a saved EDID for a Samsung monitor on `DP-3`. Only do this if your monitor is misdetected, and dump your own: an
EDID contains the monitor's serial number, so mine isn't in this repo.

1. Dump it while the monitor works (adjust the connector name):
   ```
   sudo mkdir -p /usr/lib/firmware/edid
   sudo cp /sys/class/drm/card*-DP-3/edid /usr/lib/firmware/edid/monitor.bin
   ```
2. Add it to `/etc/mkinitcpio.conf`:
   ```
   FILES=(/usr/lib/firmware/edid/monitor.bin)
   ```
3. Add this to the command line in `/etc/default/limine`, keeping your existing `root=` value:
   ```
   drm.edid_firmware=DP-3:edid/monitor.bin video=DP-3:e
   ```
   `drm.edid_firmware` uses the saved file. `video=DP-3:e` forces the connector on.
4. Rebuild with `sudo limine-mkinitcpio` and reboot. Keep a snapshot or fallback entry available.
