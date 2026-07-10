# monstar

monstar is a small Wayland terminal emulator written in Zig, built on Ghostty's terminal core.

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

Run a command directly in a new terminal window:

```sh
monstar -e ls -la
```

Use `--` to run a command through `/bin/sh -c`:

```sh
monstar -- 'echo "$SHELL"'
```

Set the child's working directory:

```sh
monstar --working-directory /tmp -e env A=B
```

Keep the window open after a command exits:

```sh
monstar --hold -e make test
```

Useful launcher/scripting options include:

```sh
monstar --title scratch --app-id com.example.scratchpad --hold \
  --window-size-chars 100x32 --font "Iosevka" \
  -o scrollback=20000 -e fish
```

Run `monstar --help` for the full option list.

Configuration is read from `$XDG_CONFIG_HOME/monstar/config` or `~/.config/monstar/config`.
Send `SIGUSR1` to reload the config for a running process:

```sh
pkill -USR1 monstar
```

`font-size` is specified in typographic points and accepts fractional values.
The default is 12 points, equivalent to 16 logical pixels at the standard
Linux 96 DPI baseline:

```conf
font-size = 12.5
```

Set `app-id` to customize the Wayland app-id and desktop-entry hint used by
compositor/window-manager rules:

```conf
app-id = com.example.scratchpad
```

Set `theme` to choose the built-in light or dark color theme, or `system` to
follow the desktop portal color scheme. The default is `system`:

```conf
theme = light
```

Add minimum padding around the terminal grid with Ghostty-style X/Y options:

```conf
window-padding-x = 4
window-padding-y = 4
```

One value applies to both sides of an axis. Two comma-separated values set
left/right or top/bottom independently:

```conf
window-padding-x = 4,8
window-padding-y = 6,10
```

Padding is measured in logical pixels and follows the output scale. Any space
left after fitting whole cells remains on the right and bottom. The default is
zero padding.

By default, child processes inherit Monstar's cgroup. To move each newly
spawned child into a separate transient systemd scope, enable Linux cgroup
isolation:

```conf
linux-cgroup = always
```

Valid values are `never` (the default) and `always`. The setting is applied
when a child starts; reloading the config does not move an existing child.
When enabled, Monstar falls back to the inherited cgroup if the session bus
or systemd scope creation is unavailable.

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
