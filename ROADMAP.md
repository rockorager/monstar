# Roadmap

Short list of known follow-ups. Most early terminal compatibility work
has landed: OSC/XTGETTCAP/DECRQSS responses, OSC 52 writes, kitty color
queries, kitty graphics, selection/clipboard basics, styled font faces,
pointer shapes, notifications, Wayland activation/decorations/suspend,
high-resolution wheel scrolling, and text-input-v3 IME support.

## Dependency maintenance

- Re-pin the Ghostty dependency to upstream main once the Zig 0.16
  migration lands in an upstream release. We are currently using the
  vendored dependency needed for Zig 0.16 compatibility.

## Not planned for now

- Custom terminfo entry: intentionally skipped; Monstar currently sets
  `TERM=xterm-ghostty`.
- Config/keybinding polish beyond the existing key=value config: skipped
  for now unless a concrete need comes up.
- Extra text-input polish such as surrounding-text deletion: skipped for
  now because terminals generally do not have editable surrounding text;
  committed IME text and preedit display are implemented.
