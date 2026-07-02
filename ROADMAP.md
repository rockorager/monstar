# Roadmap

Rough priority order. Items link to reference implementations where useful.

## Selection and clipboard polish

Basic drag selection, double/triple-click word/line selection,
selection auto-scroll, clipboard, primary selection, paste MIME
negotiation, and stale-selection clearing are done.

## Sprite polish

Sprite rendering (box drawing, blocks, braille, powerline, branch,
legacy computing) and text decorations landed, vendored from ghostty's
sprite face onto z2d. Cursor shape sprites (bar,
underline, hollow) and wide (2-cell) sprite variants landed too.

## Config polish

The key=value config file landed (font, colors, palette, scrollback,
shell, wheel speed). Possible follow-ups: live reload on file change,
configurable keybindings for copy/paste, cursor style/blink defaults,
and font fallback family overrides.

## Smaller items

- Re-pin the ghostty dependency to upstream main once the Zig 0.16
  migration lands (ghostty 1.4, PR #12726); currently pinned to the
  `vancluever/ghostty#zig-0.16` branch.
- Server-side decorations via `xdg-decoration-unstable-v1`.
- Mode 2048 edge: re-enabling the already-enabled mode should resend a
  size report (needs a mode-change hook in ghostty-vt's effects API;
  consider proposing upstream).
- Nerd Font "Mono" variant renders icons at single-cell size; consider
  double-width icon handling.
