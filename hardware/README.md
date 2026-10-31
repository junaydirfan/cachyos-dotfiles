# Hardware support

The desktop setup doesn't depend on any one PC. Nothing in `home/` or the panel layout is tied to a brand, CPU or GPU,
and display scaling and mouse settings are left for each PC to keep.

Check what the installer sees in your PC:

```bash
./install.sh --detect
```

Then `./install.sh --hardware` offers only what matches:

| Detected | What it offers |
| --- | --- |
| NVIDIA GPU | `nvidia-settings` and video decoding, plus a reminder to run `sudo chwd -a` if the driver isn't loaded |
| AMD GPU | Vulkan drivers, including 32-bit for games, and LACT for GPU control |
| Intel GPU | Vulkan drivers, video decoding and `intel_gpu_top` |
| Laptop with two GPUs | `nvidia-prime` and `switcheroo-control` for choosing which GPU runs an app |
| Lenovo Legion | Fan and power controls. See [the Legion notes](legion-pro-7/README.md) |
| Audeze Maxwell or EPOMAKER TH99 Pro plugged in | A udev rule so the device works without root. See [peripherals](peripherals/) |

Desktops and laptops get the same setup. The battery and brightness widgets stay out of the way on PCs without them.

CachyOS sets up your graphics driver during installation, so most people won't need anything here beyond the extras.

Fixing a misdetected monitor works on any PC. See the EDID steps in [the Legion notes](legion-pro-7/README.md#forcing-an-edid-for-an-external-monitor).
