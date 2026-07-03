# Monstar

Monstar is a small Wayland terminal emulator written in Zig, built on Ghostty's terminal core.

## Building

```sh
zig build
```

## Running

```sh
zig build run
```

Configuration is read from `$XDG_CONFIG_HOME/monstar/config` or `~/.config/monstar/config`.
Send `SIGUSR1` to reload the config for a running process:

```sh
pkill -USR1 monstar
```

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl+Shift+C` | Copy selection to clipboard |
| `Ctrl+Shift+N` | New window in current directory |
| `Ctrl+Shift+V` | Paste from clipboard |
| `Ctrl+Shift+,` | Reload config |
| `Ctrl++` / `Ctrl+=` | Increase font size for this window |
| `Ctrl+-` | Decrease font size for this window |
| `Ctrl+0` | Reset font size for this window |
| `Ctrl` + left click | Open OSC 8 hyperlink |
