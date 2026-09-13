# Linear-light blending with 8-bit buffers

Build with `-Dlinear-light-blending=true` to enable the experimental CPU
linear-light path. The default remains encoded-space blending. This is a
build option, not a runtime configuration key.

```sh
zig build -Doptimize=ReleaseFast -Dlinear-light-blending=true
zig build test -Dlinear-light-blending=true
./zig-out/bin/monstar --bench
```

The framebuffer remains encoded ARGB8888/XRGB8888. Foreground and destination
channels decode to 16-bit linear-light intermediates, blend there, and encode
back to bytes. Translucent destinations are unassociated before decoding and
premultiplied again after encoding. Opaque image colors remain unchanged.
No compositor color-management protocol or full-frame conversion pass is
required. Glyph coverage, clipping, and background fills are otherwise unchanged.

The gamma-2.2 convention and decode-table approach follow cnt0's proposal in
[PR #58](https://github.com/rockorager/monstar/pull/58), motivated by
[issue #57](https://github.com/rockorager/monstar/issues/57). Gamma 2.2 is an
approximation, not the exact piecewise sRGB transfer function. This path does
not add the text-weight correction used by some GPU terminals.

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

## Comparing performance

Build the two modes into separate prefixes, then run `--bench` on the same
CPU with the same font/configuration:

```sh
zig build -Doptimize=ReleaseFast --prefix /tmp/monstar-encoded
zig build -Doptimize=ReleaseFast -Dlinear-light-blending=true --prefix /tmp/monstar-linear
taskset -c 2 /tmp/monstar-encoded/bin/monstar --bench
taskset -c 2 /tmp/monstar-linear/bin/monstar --bench
```

Repeat runs and alternate their order. The benchmark prints its blending
mode, warms glyphs and the blend cache, and measures opaque and translucent
full redraws, changing-row redraws, larger grids, and standalone copies.
These are renderer timings, not FPS or end-to-end presentation latency.
Cache-friendly repeated colors benefit most; high color churn can benefit less.

During development, a three-run renderer comparison of the cached prototype
against PR #58's unchanged 16-bit raster path measured 4.04 versus 5.68 ms for
full-screen text, and 12.18 versus 18.75 ms for a 384x112-cell grid. Both used
Zig 0.16 ReleaseFast and DejaVu Sans Mono 16px on a shared Linux orb. Those
measurements preceded the standalone port to current main; they exclude
compositor output conversion and do not establish end-to-end equivalence.

The scroll reuse change is separate from blending: in-place one-row rotations
reuse matching retained rows, unless glyph ink crosses row boundaries. It
benefits both build modes. The renderer-only scrolling benchmark does not
exercise the application's asynchronous scroll-copy optimization.
