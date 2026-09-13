# Linear-light blending with 8-bit buffers

Monstar always composites pixels in linear light using the exact piecewise
sRGB transfer function. Ordinary builds use this policy; there is no blending
mode switch or runtime configuration key.

```sh
zig build -Doptimize=ReleaseFast
zig build test
./zig-out/bin/monstar --bench
```

The framebuffer remains encoded ARGB8888/XRGB8888. Foreground and destination
channels decode to 16-bit linear-light intermediates, blend there, and encode
back to bytes. Translucent destinations are unassociated before decoding and
premultiplied again after encoding. Opaque image colors remain unchanged.
No compositor color-management protocol or full-frame conversion pass is
required. Background fills retain their specified encoded colors. Encoded RGB
interpolation remains for constructing faint/search styling colors, not for
pixel composition.

The decode-table approach follows cnt0's proposal in
[PR #58](https://github.com/rockorager/monstar/pull/58), motivated by
[issue #57](https://github.com/rockorager/monstar/issues/57). The original
gamma-2.2 approximation has been replaced with piecewise sRGB.

## Fractional text on an integer grid

Scalable text uses fractional physical sizes through `FT_Set_Char_Size`,
`FT_LOAD_TARGET_LIGHT | FT_LOAD_NO_BITMAP`, and `FT_RENDER_MODE_NORMAL` grayscale
coverage. Native Adobe CFF stem darkening is enabled. HarfBuzz uses the same
load flags and preserves 26.6 advances and offsets. Terminal cells remain
integer-sized: each cluster starts at its grid origin, with fractional pen
positions preserved inside the cluster.

Glyph caches distinguish horizontal and vertical raster phases. Negative
positions decompose with floor division; FreeType applies the fractional phase
once, and the renderer uses integer origins plus returned bearings. Shaping and
rasterization save and restore face transforms. Bitmap/color faces retain their
separate loading and cell-fitting path; procedural symbols remain grid-aligned.

The historical A/B/C/D comparison selected B (light hinting with darkening).
Unhinted, darkening-off, and encoded-space experiment modes are not supported.

## Memory and precision

- Four bytes per framebuffer pixel, rather than eight for a 16-bit linear
  RGBA framebuffer: 11.7 MB versus 23.3 MB at 2400x1216, per buffer.
- A shared 512-byte decode table and 64 KiB encode table.
- A 33.25 KiB thread-local cache: 32 foreground/background pairs, each with
  256 possible coverage results and validity bits. Results are populated
  lazily; collisions invalidate the slot. Pixels with another destination
  color take the uncached path.
- Every blend rounds back to encoded 8-bit storage. Repeated transparency
  can lose more detail than a higher-precision linear framebuffer.

## Measuring performance

Run `--bench` with a release build and fixed CPU, font, and configuration:

```sh
zig build -Doptimize=ReleaseFast
taskset -c 2 ./zig-out/bin/monstar --bench
```

Repeat runs. The benchmark identifies the fixed blending policy, warms glyphs
and the blend cache, and measures opaque and translucent
full redraws, changing-row redraws, larger grids, and standalone copies.
These are renderer timings, not FPS or end-to-end presentation latency.
Cache-friendly repeated colors benefit most; high color churn can benefit less.

Historically, a three-run renderer comparison of the cached prototype
against PR #58's unchanged 16-bit raster path measured 4.04 versus 5.68 ms for
full-screen text, and 12.18 versus 18.75 ms for a 384x112-cell grid. Both used
Zig 0.16 ReleaseFast and DejaVu Sans Mono 16px on a shared Linux orb. Those
measurements preceded the standalone port and fractional/sRGB changes; they
exclude compositor output conversion and are not measurements of this version.

The scroll reuse change is separate from blending: in-place one-row rotations
reuse matching retained rows, unless glyph ink crosses row boundaries. It
remains enabled. The renderer-only scrolling benchmark does not
exercise the application's asynchronous scroll-copy optimization.
