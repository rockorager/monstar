# GPU renderer research

These are the prototype and measurement harness behind the November 2026
question "would a Vulkan renderer help Monstar?". In short: CPU raster
presented as a udmabuf dma-buf removes most of the compositor's cost. A GPU
renderer clearly wins only on client CPU and on fullscreen direct scanout, and
it adds 18–65 ms of Vulkan init. `results/SUMMARY.md` has the numbers.

Nothing here is built by Monstar's `build.zig`.

## Contents

- **`vkgrid/`** is a standalone C prototype of a Vulkan terminal-grid renderer.
  It is not a terminal. It uses a FreeType R8 glyph atlas, a single fullscreen
  fragment pass that blends in linear light, and a FIFO swapchain on a
  `VK_KHR_wayland_surface`.
  - `vkgrid idle` draws once, then redraws only for key echo.
  - `vkgrid scroll` scrolls one row per frame.
  - `--overlap` is the "CPU frames first, then GPU" startup experiment. It
    commits wl_shm frames while Vulkan initializes on a thread, then hands the
    same `wl_surface` to the swapchain.
  - `SIGUSR1` recreates the swapchain from dma-buf feedback. This is how it
    picks up the scanout tranche when fullscreen.
  - It prints startup phase marks (`mark NAME ms`) and per-second CPU/GPU
    frame times.
- **Measurement tools:**
  - `measure.py LABEL SECONDS OUT.jsonl proc[,proc]` samples, for the named
    processes, CPU from `/proc` (utime+stime as % of one core), RAPL package
    power, the amdgpu PPT sensor, `gpu_busy_percent`, and the page-flip rate
    from the `drm:drm_vblank_event` tracepoint.
  - `latency.py N OUT.json` measures keypress-to-flip latency. A uinput
    keyboard goes through libinput, the compositor and the client, and the
    first flip after each press is recorded.
  - `startup.py` measures launch to first visible flip on an empty output.
  - `vkphases.py N` gives medians of vkgrid's Vulkan init phases.
  - `summarize.py` builds the tables from `results/suite.jsonl` and
    `results/lat*.json`.
- **Workloads:**
  - `gen-text.py` writes the scroll corpora (`text*.txt`).
  - `scroll60*.py RATE` writes one line per tick.
  - `scroll-finite.py` scrolls a fixed number of lines, then holds the frame
    for screenshots.
  - `flood.sh` is a `cat` loop.
- **Suites:**
  - `suite.sh` and `suite2.sh` run Sway steady state and latency.
  - `fs-suite.sh` runs fullscreen.
  - `suite4k.sh` runs headless Sway at 4K@120.
  - `lat-interleave.sh` interleaves latency runs.
  - `suite-scan.sh` (and `suite-scan2.sh`, which takes `KINDS=`) runs shm,
    udmabuf, gbm and vkgrid on Sway or Hyprland, and records whether the
    primary plane shows the client's buffer.
  - `scancheck.sh` and `scanout-test.sh` are one-off plane checks.
  - `ab.sh` and `pixcheck.sh` run the overhang-fix A/B: CPU, and a
    pixel-identical screenshot comparison.
- **Compositor setup:**
  - Sway: `sway-up.sh gles2|vulkan [scanout 1|0]` and `sway-down.sh` start
    and stop Sway on DRM on VT63. Use `SWAY_CONF=sway-comp.conf` for 64 px
    gaps; `sway-hl.conf` and `sway-4k.conf` are the other configs used, and
    `sway4k-up.sh` starts the headless 4K Sway.
  - Hyprland: `hypr-up.sh GAPS` and `hypr-down.sh` start and stop Hyprland
    from `hypr.lua.in` (Hyprland 0.57 Lua config, direct scanout on,
    animations off).
- **`config/`** holds the Monstar configs passed through `XDG_CONFIG_HOME`.
  `adwaita` uses Adwaita Mono; `default` uses the system `monospace`, which is
  Nimbus Mono PS on the test machine.
- **`tools/`** has small FreeType and GBM probes:
  - `probe.c` and `metrics.c` were used for the font overhang investigation.
  - `gbmtime.c` times `gbm_create_device`, about 18 ms warm.
- **`patches/gbm-linear-scanout-prototype.patch`** applies to the udmabuf
  prototype (`MONSTAR_GBM=1`). It copies each frame into a GBM
  SCANOUT|LINEAR buffer, which compositors can scan out without a GPU
  renderer.
- **`results/`** holds the raw JSON and logs (small) and `SUMMARY.md`.

## Build and run

Dependencies: a C compiler, `glslc` (shaderc), `wayland-scanner`,
wayland-protocols, and Vulkan, FreeType, wayland-client and libgbm development
files. The suites also need Python 3, `seatd`, Sway and/or Hyprland, `grim`,
root access (for tracefs, RAPL, uinput, debugfs and VT switching) and a free
VT.

```sh
cd research/gpu-renderer
vkgrid/build.sh                      # generates shader and protocol headers, builds vkgrid/vkgrid
cc -O2 -o tools/gbmtime tools/gbmtime.c -lgbm
cc -O2 -o tools/probe tools/probe.c $(pkg-config --cflags --libs freetype2)   # likewise metrics.c
python3 gen-text.py                  # scroll corpora, about 15 MB, not committed
(cd ../.. && zig build -Doptimize=ReleaseFast)
./sway-up.sh gles2 1                 # Sway on DRM, VT63, runtime in /tmp/mvk-run
./suite2.sh gles2 shm 3              # appends to results/suite.jsonl
./suite2.sh gles2 vkgrid 3
python3 summarize.py
./sway-down.sh; chvt 1
```

- Scripts locate themselves. They use `$MONSTAR` or `../../zig-out/bin/monstar`
  as the Monstar binary.
- `suite-scan.sh`, `scancheck.sh` and `ab.sh` expect prebuilt binaries in
  `bin-udmabuf/`, `bin-before/` and `bin-after/`, which are not committed.
- The scripts were written against the udmabuf prototype, where dma-buf
  presentation was opt-in with `MONSTAR_UDMABUF=1`. In the production change,
  udmabuf is the default and `MONSTAR_SHM=1` forces wl_shm, so the shm runs
  need that variable instead.
- Several paths are specific to this machine: `/dev/dri/card1` and
  `renderD128`, `plane[206]` as the primary plane in
  `/sys/kernel/debug/dri/1/state`, the `intel-rapl:0` and `hwmon5` power
  sensors in `measure.py`, and the `eDP-1` output. Adjust them for other
  hardware.

## Hardware and setup of the recorded numbers

- **Machine:** Ryzen 5 PRO 7640HS laptop with a Radeon 760M iGPU (amdgpu; RADV
  and radeonsi from Mesa 26.2.6) on Linux 7.2.14 (Arch).
- **Display:** eDP-1 panel at 1920×1200@60, scale 1. The 4K runs used a
  headless 3840×2160@120 Sway output.
- **Compositors:** Sway 1.12 / wlroots 0.20.2 on real DRM, with the gles2 and
  vulkan renderers, no debug logging, and no wallpaper unless noted.
  Hyprland 0.57.0 for the follow-up.
- **Monstar:** `5e1e745` for the first suite and `0924626` plus the udmabuf
  prototype for the scanout follow-up, both ReleaseFast. Font: Adwaita Mono
  16 px unless the label says nimbus.
- **Runs:** steady-state numbers are medians of 3 runs of 10 s (2 for the Sway
  vulkan renderer). Idle package power is about 3.2 W. The machine runs other
  services, so treat differences under about 0.3 W as noise.
