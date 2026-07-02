# Roadmap

Rough priority order. Items link to reference implementations where useful.

## Selection and clipboard polish

Basic drag selection, clipboard, and primary selection are done.
Remaining: double/triple-click word/line selection (ghostty-vt's
`selectWord`/`selectLine`), auto-scroll when dragging past the window
edge, mime negotiation from the offer's advertised types instead of
requesting blindly, and clearing the selection when the screen
content under it changes.

## Sprite polish

Sprite rendering (box drawing, blocks, braille, powerline, branch,
legacy computing) and text decorations landed, vendored from ghostty's
sprite face onto z2d. Remaining: cursor shape sprites (bar, underline,
hollow rect from `special.zig` are vendored but unused — the cursor is
still always a filled block), and wide (2-cell) sprite variants where
ghostty passes `cell_width > 1`.

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
