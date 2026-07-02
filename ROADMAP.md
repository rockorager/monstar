# Roadmap

Rough priority order. Items link to reference implementations where useful.

## Selection and clipboard polish

Basic drag selection, clipboard, and primary selection are done.
Remaining: double/triple-click word/line selection (ghostty-vt's
`selectWord`/`selectLine`), auto-scroll when dragging past the window
edge, mime negotiation from the offer's advertised types instead of
requesting blindly, and clearing the selection when the screen
content under it changes.

## Custom drawing for box-drawing and friends

Render "grid glyphs" procedurally instead of from fonts so lines meet
pixel-perfectly across cells regardless of the font in use. Reference:
ghostty's sprite face (`src/font/sprite/Face.zig` and
`src/font/sprite/draw/` in the ghostty repo; see `draw/README.md` for
the draw-function convention).

Codepoint ranges ghostty covers, one module each:

- `box.zig` — box drawing, U+2500–257F
- `block.zig` — block elements, U+2580–259F
- `geometric_shapes.zig` — the cell-sized geometric shapes (triangles etc.)
- `braille.zig` — braille patterns, U+2800–28FF
- `powerline.zig` — powerline triangles/half-circles, U+E0B0…
- `branch.zig` — branch/commit drawing characters (kitty extension)
- `symbols_for_legacy_computing[_supplement].zig` — U+1FB00… sextants/octants
- `special.zig` — non-codepoint sprites: underline styles, strikethrough,
  overline, cursor shapes

Key implementation notes from ghostty:

- The sprite face is consulted *before* real fonts for covered
  codepoints, and quacks like a normal face so shaping/caching layers
  don't special-case it. For vtread: intercept in
  `Font.faceForCodepoint` (these never shape or ligate, so they can
  bypass HarfBuzz entirely).
- Draw functions receive the cell size and grid metrics and paint onto
  a canvas padded by a quarter cell on each edge, so glyphs may
  intentionally overflow the cell — that overlap is what makes
  diagonals and corners connect seamlessly between neighboring cells.
- Sprites are keyed by codepoint + cell size, cached like regular
  glyphs, and rebuilt on font/scale changes.

`special.zig` overlaps with the underline/strikethrough item below;
doing them together is natural.

## Text decorations

Underline (single/double/curly/dotted/dashed, colored), strikethrough,
overline. Style flags are already in `vt.Style`; rendering is missing.
Best done as sprites (see above).

## Config file

Font family and size, colors/palette, scrollback limit, wheel scroll
lines, default shell. Probably a simple key=value file at
`$XDG_CONFIG_HOME/vtread/config`.

## Color emoji

Fixed-size color faces (Noto Color Emoji) currently fail to load and
are skipped. Needs FT_LOAD_COLOR, strike selection nearest the cell
size, BGRA blitting, and scaling into the cell.

## terminfo entry

Ship a `vtread` terminfo (and stop defaulting TERM to
xterm-256color). ghostty's terminfo generator is a useful reference.

## Smaller items

- Re-pin the ghostty dependency to upstream main once the Zig 0.16
  migration lands (ghostty 1.4, PR #12726); currently pinned to the
  `vancluever/ghostty#zig-0.16` branch.
- Server-side decorations via `xdg-decoration-unstable-v1`.
- SIGKILL escalation if a child ignores SIGHUP on window close.
- Mode 2048 edge: re-enabling the already-enabled mode should resend a
  size report (needs a mode-change hook in ghostty-vt's effects API;
  consider proposing upstream).
- Nerd Font "Mono" variant renders icons at single-cell size; consider
  double-width icon handling.
- Render only dirty rows (RenderState already tracks them; the
  renderer currently redraws everything every frame).
