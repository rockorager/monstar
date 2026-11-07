# Summarized results

Medians, generated from the raw files in this directory. The first two tables
are `python3 summarize.py` output (`suite.jsonl` and `lat*.json`).
CPU is % of one core; power is RAPL package watts; Sway at 1920×1200@60 on
real DRM unless the label says otherwise. Workloads: `scroll60` scrolls 60
lines/s of ~180-column colored text (full-surface damage every frame),
`scroll60-short` the same at ~100 columns, `flood` is a `cat` loop.

## Steady state and keypress-to-flip latency (Sway)

| config | workload | client CPU % | sway CPU % | RAPL pkg W | GPU busy % | n |
|---|---|---:|---:|---:|---:|---:|
| gles2/shm | idle | 0.0 | 0.0 | 3.28 | 0.0 | 3 |
| gles2/shm | scroll60 | 8.9 | 10.0 | 5.36 | 2.9 | 3 |
| gles2/shm | scroll60-short | 8.3 | 9.8 | 5.35 | 2.8 | 3 |
| gles2/shm | flood | 165.5 | 5.9 | 32.16 | 2.0 | 3 |
| gles2/udmabuf | idle | 0.0 | 0.0 | 3.35 | 0.0 | 3 |
| gles2/udmabuf | scroll60 | 9.3 | 6.0 | 5.28 | 3.2 | 3 |
| gles2/udmabuf | scroll60-short | 8.5 | 6.0 | 5.24 | 3.0 | 3 |
| gles2/udmabuf | flood | 164.8 | 1.7 | 31.35 | 2.0 | 3 |
| gles2/vkgrid | idle | 0.0 | 0.0 | 3.15 | 0.0 | 3 |
| gles2/vkgrid | scroll60 | 2.0 | 6.4 | 5.73 | 8.8 | 3 |
| gles2/shm-nimbus | idle | 0.0 | 0.0 | 3.07 | 0.0 | 1 |
| gles2/shm-nimbus | scroll60 | 25.9 | 8.3 | 7.10 | 2.5 | 1 |
| gles2/shm-nimbus | scroll60-short | 20.5 | 9.2 | 6.20 | 2.7 | 1 |
| gles2/shm-nimbus | flood | 168.9 | 6.0 | 32.23 | 2.0 | 1 |
| vulkan/shm | idle | 0.0 | 0.0 | 3.29 | 0.0 | 2 |
| vulkan/shm | scroll60 | 10.6 | 12.6 | 6.13 | 10.4 | 2 |
| vulkan/shm | scroll60-short | 9.6 | 11.1 | 6.02 | 9.7 | 2 |
| vulkan/shm | flood | 164.8 | 5.8 | 32.67 | 6.0 | 2 |
| vulkan/udmabuf | idle | 0.0 | 0.0 | 3.34 | 0.0 | 2 |
| vulkan/udmabuf | scroll60 | 10.4 | 5.6 | 5.66 | 7.5 | 2 |
| vulkan/udmabuf | scroll60-short | 9.6 | 5.5 | 5.60 | 6.9 | 2 |
| vulkan/udmabuf | flood | 164.8 | 1.5 | 32.18 | 5.0 | 2 |
| vulkan/vkgrid | idle | 0.0 | 0.0 | 3.33 | 0.0 | 2 |
| vulkan/vkgrid | scroll60 | 2.7 | 5.7 | 6.18 | 11.9 | 2 |
| gles2-fullscreen/shm | scroll60-short | 8.2 | 9.3 | 5.64 | 2.8 | 3 |
| gles2-fullscreen/udmabuf | scroll60-short | 8.3 | 5.6 | 5.44 | 3.1 | 3 |
| gles2-fullscreen/vkgrid | scroll60-short | 2.1 | 3.8 | 5.02 | 6.0 | 3 |

| latency set | n | mean ms | p50 | p90 | p99 | >16.7 ms |
|---|---:|---:|---:|---:|---:|---:|
| gles2/shm | 300 | 12.06 | 11.93 | 18.97 | 20.64 | 20% |
| gles2/udmabuf | 300 | 12.47 | 12.85 | 19.32 | 20.80 | 27% |
| gles2/vkgrid | 300 | 12.96 | 13.22 | 19.74 | 21.18 | 30% |
| vulkan/shm | 150 | 12.28 | 12.27 | 19.62 | 20.67 | 23% |
| vulkan/udmabuf | 150 | 12.06 | 12.06 | 19.22 | 20.40 | 23% |
| vulkan/vkgrid | 150 | 13.15 | 13.23 | 19.63 | 21.01 | 25% |
| gles2-shm-nimbus (suite) | 120 | 12.43 | 12.64 | 18.62 | 20.55 | 22% |
| gles2-shm (suite) | 120 | 11.43 | 11.32 | 18.01 | 20.22 | 20% |
| gles2-udmabuf (suite) | 120 | 13.24 | 14.50 | 18.95 | 20.73 | 31% |
| gles2-vkgrid (suite) | 120 | 13.05 | 13.15 | 20.06 | 21.13 | 30% |
| monstar-shm-gles2 (suite) | 100 | 12.20 | 11.99 | 18.82 | 20.95 | 21% |
| vulkan-shm (suite) | 120 | 12.40 | 12.06 | 19.55 | 20.59 | 26% |
| vulkan-udmabuf (suite) | 120 | 13.30 | 14.07 | 19.48 | 20.33 | 28% |
| vulkan-vkgrid (suite) | 120 | 12.75 | 13.02 | 19.59 | 20.88 | 28% |

## 3840×2160@120, headless Sway (gles2), scroll 120 lines/s (`suite4k.jsonl`)

| client | client CPU % | Sway CPU % | RAPL pkg W |
|---|---:|---:|---:|
| Monstar wl_shm | 32.6 | 27.2 | 13.6 |
| Monstar udmabuf | 34.7 | 2.6 | 9.6 |
| vkgrid | 2.2 | ~4 | 10.9 (GPU 40–55% busy) |

## Launch to first visible flip, empty Sway output (`startup.jsonl`)

| client | warm p50 ms (n=15) | cold ms (n=3) |
|---|---:|---:|
| Monstar wl_shm | 38.7 | 63–73 |
| Monstar udmabuf | 33.8 | – |
| vkgrid, Vulkan init before first frame | 44.1 | 96–114 |
| vkgrid `--overlap` (CPU frame first; v2 = final version) | 34.0 first CPU frame, 38.0 first Vulkan frame | – |

vkgrid Vulkan init phases, warm medians (`vkphases.py`): instance 9.7,
physical-device enumeration 4.5, device 1.1, pipeline 0.2, atlas and buffers
0.8, swapchain 0.7, first frame 0.6; 18.4 ms total. Cold: 63–66 ms, mostly
loading `libvulkan_radeon.so` and libLLVM.

## Scanout follow-up, 60 Hz scroll60-short (`scan.jsonl`)

Client CPU / compositor CPU / package W, medians of 3. `gbm` is the prototype
in `../patches/gbm-linear-scanout-prototype.patch`.

| | shm | udmabuf | gbm | vkgrid |
|---|---|---|---|---|
| Sway fullscreen | 8.6 / 7.7 / 5.25 | 7.7 / 5.6 / 5.26 | 13.7 / 2.8 / 5.06 (scanout) | 2.2 / 3.8 / 4.76 (scanout) |
| Sway, 64 px gaps, black background | 6.5 / 6.7 / 5.36 | 6.4 / 5.8 / 5.10 | 12.2 / 2.7 / 4.90 (scanout) | 2.1 / 6.1 / 5.60 |
| Hyprland fullscreen | 8.4 / 9.2 / 5.65 | 6.8 / 8.3 / 4.66 | 13.7 / 3.2 / 5.38 (scanout) | 2.5 / 4.8 / 4.73 (no scanout) |
| Hyprland, 64 px gaps | 6.7 / 12.8 / ~5.3 | 7.5 / 7.5 / 5.21 | 8.9 / 7.1 / 5.56 | 2.6 / 7.2 / 5.64 |

amdgpu never scans out udmabuf: `amdgpu_display_user_framebuffer_create`
rejects imported dma-bufs whose BO lacks `AMDGPU_GEM_CREATE_CPU_GTT_USWC`.

## Nimbus Mono PS overhang fix (`overhang-ab.jsonl`)

Monstar CPU at 60 Hz scroll before/after the scroll-reuse fix (4775880):
Nimbus 24.9% → 10.0%, Adwaita Mono with accented text 18.9% → 8.5%.
