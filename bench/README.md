# monstar-bench

A portable, end-to-end benchmark of Monstar's rendering paths, measured
together with the compositor. It runs the matrix from the "CPU vs GPU terminal
rendering" spec on your machine and writes a JSON result plus a Markdown
table. Results from several machines merge into one table.

## Quick start

```sh
zig build -Doptimize=ReleaseFast           # the binary under test
bench/monstar-bench bootstrap              # once: pinned workloads into ~/.cache/monstar-bench
bench/monstar-bench run --label my-laptop  # about 40 min per compositor with the defaults
bench/monstar-bench run --quick            # smoke test: 1 rep, 3 s cells
```

`run` writes `bench-results/<label>-<compositor>-<time>.json` and a `.md`
next to it. Run it once in Sway and once in Hyprland, then:

```sh
bench/monstar-bench merge a.json b.json -o merged.json
bench/monstar-bench report merged.json > table.md
```

`bench/monstar-bench probe` shows the session, the RAPL zones, and which
configs this Monstar build supports, without root.

## Requirements

- Linux with RAPL package energy (`/sys/class/powercap/intel-rapl:N`, Intel or
  AMD Zen). Power is the headline metric, so the tool refuses to run without
  it; virtual machines usually do not expose RAPL.
- `sudo` (see below), Python 3.10+, git and a C compiler (bootstrap only),
  `btop` (optional; its workload is skipped when missing), and Sway or Hyprland.

## Sessions

`--session auto` (default) runs in the current Sway or Hyprland session. On a
dedicated workspace (`monstar-bench`) with 32 px outer gaps in Sway, so a tiled
window is always composited, and restores the previous workspace afterwards.
Outside Sway/Hyprland it starts Sway nested in the current Wayland session, or
headless when there is none. `--session nested|headless` forces one;
`--headless-mode 1920x1200@60` sets the started Sway's output.

## Root

The tool runs as you and starts one small root helper with `sudo`, after
printing why. The kernel restricts the RAPL energy counter to root since the
PLATYPUS fix (CVE-2020-8694). The helper only reads RAPL counters, creates a
uinput keyboard, traces KMS page flips (tracefs `drm_vblank_event` paired
with `drm_vblank_event_delivered`, since the first fires on every vblank),
reads debugfs plane state, and drops the page cache before cold starts. Monstar, the
compositor and the workloads always run as you. Every helper-backed
measurement is marked `"privileged": true` in the JSON.

## What runs

Configs are selected with `-o` overrides that every rendering path honors:

| Config | Overrides | Expected path |
| --- | --- | --- |
| cpu | `renderer=cpu`, `presentation=shm` | CPU raster, wl_shm |
| udmabuf | `renderer=cpu`, `presentation=dmabuf` | CPU raster, linux-dmabuf |
| vulkan | `renderer=vulkan` | Vulkan renderer, swapchain |

The tool first checks which overrides the build accepts, then launches it and
reads the renderer and presentation path Monstar reports. A config whose path
does not match (an unknown key, or a fallback) is skipped and listed with the
reason. Builds without the keys run only the path they present through.

With the default `vulkan-startup = cpu-first`, the vulkan config shows CPU
frames until Vulkan is ready and then switches to the swapchain. That handoff
is expected: steady-state measurement starts only after it, and startup
records both the first frame and the handoff (the first Vulkan frame).

Each config runs tiled and fullscreen with these workloads (pins in
`monstar_bench/pins.py`, LazyVim plugin commits in `pins/lazy-lock.json`):

| Workload | Program | Driven by |
| --- | --- | --- |
| idle (20 s) | bash at a fixed prompt | nothing |
| shell-typing | bash | a fixed command line at ~9 keys/s with typos and backspaces; latency |
| btop | btop, `update_ms = 100` | itself |
| nvim-scroll | stock LazyVim on Linux v6.6 `kernel/sched/fair.c` | `j` then `Ctrl-d` at 25 keys/s |
| nvim-insert | same, at line 6000 | a C line typed at ~9 keys/s; latency |
| screensaver | Omarchy's tte loop (Omarchy 7644b56, tte 0.15.0, `matrix`) | itself |
| log-10/60/500 | colored log lines at a fixed rate | itself |
| cat-flood | `cat` of the corpus 64 times (~440 MB) | until done |

Cells are 10 s after a settle period; workloads that start themselves wait on a
FIFO so measurement begins in steady state. Workloads run in a private network
namespace (`unshare --net`) when available, so nothing reaches the network
during measurement. Each repetition starts with an idle-system baseline (no
Monstar window) for ΔW. Startup runs separately: launch to first presented
frame, cold (page cache dropped) and warm, tiled.

Keys come from uinput (through libinput) in your own session, and from the
compositor's virtual-keyboard protocol in nested/headless sessions. Both use a
US layout.

## Frame telemetry

Monstar records frame timing itself when `MONSTAR_FRAME_TELEMETRY=<file>` is
set (`src/FrameTelemetry.zig`). Without it, Monstar binds no
`wp_presentation` and every hook is a null check. The file is JSON lines, all
times in CLOCK_MONOTONIC ns:

```json
{"ev":"start","t":1179151085989,"pid":10205}
{"ev":"clock","id":1}
{"ev":"path","t":...,"renderer":"cpu","presentation":"shm"}
{"ev":"key","t":...,"key":30}
{"ev":"frame","id":2,"start":...,"render_done":...,"commit":...,"w":1276,"h":697,
 "present":...,"refresh":16666666,"msc":1234,"flags":7,"missed":0}
{"ev":"frame","id":3,"start":...,"render_done":...,"commit":...,"w":1276,"h":697,"gpu_ns":512000,
 "present":...,"refresh":16666666,"msc":1235,"flags":15,"missed":0}
{"ev":"frame","id":1,"start":...,"render_done":...,"commit":...,"w":800,"h":600,"discarded":true}
```

`start` is when the frame's render was submitted, `render_done` when the raster
result came back, `commit` the `wl_surface.commit`, and `present`/`refresh`/
`msc`/`flags` the `wp_presentation_feedback.presented` event. `missed` counts
refreshes skipped before this frame while it was already rendering when the
previous frame reached the screen; a continuous stream should advance one
refresh per frame. `gpu_ns`, present only for GPU-rendered frames that were
presented, is the frame's GPU time from timestamp queries: rasterization plus
the copy into the presented buffer. Renderers other than the CPU path must call
`FrameTelemetry.notePath` with their actual renderer and presentation and use
the same hooks (`renderSubmitted`, `renderFinished`, `beforeCommit`).

## Result JSON (`monstar-bench/1`)

```text
schema, id (uuid), tool {version, argv, started, finished}
machine  {label, hostname, arch, cpu {model, threads, governor, driver, epp, platform_profile},
          gpus [{card, driver, vendor, device, vram_mb, boot_vga, discrete}],
          kernel, distro, mesa, memory_mb, on_ac_power, loadavg}
session  {compositor, version, mode (own|nested|headless), pid,
          display {output, width, height, refresh_hz, scale, make, model}}
monstar  {binary, version, commit, dirty}
pins, cache (system tool paths)
configs  {cpu|udmabuf|vulkan: {status ok|skipped, reason, overrides, rejected, expect, handoff_from,
          effective}}
settings {repetitions, states, workloads, skipped_workloads, input, durations_s,
          startup_launches, baseline_s, font, keeps_up_max_missed_pct}
measurements {name: {status ok|unavailable|fake|unused, privileged, source}}
baseline {runs [{package_w, package_j, seconds, compositor_pct}], summary}
cells [{key "compositor/config/state/workload", compositor, config, state, workload,
        duration_s, errors [], runs [RUN], summary SUMMARY}]
startup [{key, compositor, config, cache cold|warm, first_present_ms [], first_commit_ms [],
          handoff_ms [] (configs with handoff_from; null where no handoff happened), failures,
          summary}]
```

Each `RUN` keeps raw samples: `seconds`; `power {package_w, package_j,
dgpu_w?, gpu_busy_pct?}`; `cpu {client_pct, compositor_pct, workload_pct}` (%
of one core); `frames {committed, presented, discarded, missed_refreshes,
late_frames, refresh_ms, refresh_source, interval_ms [], render_ms [],
gpu_ms [], commit_to_present_ms [], size}`; `memory {client, compositor: {rss_kb, pss_kb,
peak_rss_kb}}`; `gpu {client_engine_ms, client_memory_kb}` from DRM fdinfo;
`latency {key_to_present_ms [], key_to_commit_ms [], key_to_receive_ms [],
key_to_flip_ms [] | null, keys, unmatched, input}`; `flood {wall_s, bytes,
mb_per_s, complete}`; `window`, `effective`, `kms_flips`, `kms_fbs`,
`scanout_compositor`, `warning`.

`SUMMARY` holds medians with min/max across repetitions (`package_w`,
`package_delta_w`, `client_cpu_pct`, ...), pooled percentiles (`frame_interval_ms`,
`render_ms`, `gpu_ms`, `latency.key_to_present_ms`, ...), `missed_refreshes`,
`missed_pct` and `keeps_up` (missed ≤ 1% of frames). Summaries are recomputed
from the raw runs by `report` and `merge`. A merged file is
`{"schema": "monstar-bench-merged/1", "runs": [result, ...]}`, deduplicated by
`id`.

## Tests

```sh
python3 -m unittest discover -s bench/tests
```

`--sysfs-root DIR` (hidden) points RAPL, tracefs, debugfs and drop_caches at a
fake tree for development without hardware; results made that way are marked
`fake` and the table says so.
