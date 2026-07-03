# Monstar

Monstar is a small Wayland terminal emulator written in Zig, built on Ghostty's terminal core.

## Building

```sh
zig build
```

## Installing

```sh
zig build -Doptimize=ReleaseFast install --prefix $HOME/.local
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

To pipe the last OSC 133-delimited command output with `Ctrl+Shift+G`, set a
shell command that receives the output on stdin:

```conf
pipe-command-output = cat > /tmp/monstar-output
```

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl+Shift+C` | Copy selection to clipboard |
| `Ctrl+Shift+G` | Pipe last command output to `pipe-command-output` |
| `Ctrl+Shift+N` | New window in current directory |
| `Ctrl+Shift+V` | Paste from clipboard |
| `Ctrl+Shift+X` | Jump to next OSC 133 prompt |
| `Ctrl+Shift+Z` | Jump to previous OSC 133 prompt |
| `Ctrl+Shift+,` | Reload config |
| `Ctrl++` / `Ctrl+=` | Increase font size for this window |
| `Ctrl+-` | Decrease font size for this window |
| `Ctrl+0` | Reset font size for this window |
| `Ctrl` + left click | Open OSC 8 hyperlink |
| `Ctrl` + drag | Rectangular text selection |
