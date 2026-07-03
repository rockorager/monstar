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
Press `Ctrl+Shift+,` to reload the config in a running window.
Send `SIGUSR1` to reload the config for a running process:

```sh
pkill -USR1 monstar
```
