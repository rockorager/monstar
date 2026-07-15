<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./dist/dev.rockorager.monstar-wordmark.svg">
    <source media="(prefers-color-scheme: light)" srcset="./dist/dev.rockorager.monstar-wordmark-light.svg">
    <img alt="Monstar" src="./dist/dev.rockorager.monstar-wordmark-light.svg" width="360">
  </picture>
</h1>

Monstar is a Linux-native terminal built for Wayland. It integrates with the
desktop session all the way down—from portals and D-Bus to systemd scopes—while
keeping the terminal focused, responsive, and configurable.

## Highlights

- **At home on Linux.** Native notifications, taskbar progress, portal-driven
  link opening and color schemes, and systemd process management.
- **First-class Wayland.** Native windows, fractional scaling, IME, clipboard,
  primary selection, activation, and system bell support.
- **Live scrollback search.** Search and move between matches while terminal
  output continues in the background.
- **Modern terminal features.** Kitty graphics, OSC 8 hyperlinks, URI detection,
  synchronized output, and rich color support are built in.
- **Flexible appearance.** Use fontconfig fonts and bundled color schemes, follow
  the desktop light/dark preference, and tune padding and background opacity.
- **Comfortable input.** Smooth touchpad inertia, independent wheel tuning,
  rectangular selection, and link opening work out of the box.
- **Reloadable configuration.** Most appearance and interaction settings update
  in the running window without a restart.

## Performance

Reference results from a `ReleaseFast` build on an Intel Core Ultra 7 258V,
running under Sway:

| Workload | Result |
| --- | ---: |
| Launch and exit (`monstar -e true`) | **17.6 ms** median |
| ASCII PTY/parser throughput | **131.7 MB/s** |
| CSI-heavy PTY/parser throughput | **56.8 MB/s** |

Launch time is the complete process lifetime measured over 100 runs after 10
warmups with an empty configuration. It is not a time-to-first-frame metric.
Throughput was measured with
`kitten __benchmark__ --repetitions 100 ascii csi`; the benchmark waits for a
terminal response after each stream, with synchronized output suppressing
rendering. Results vary by hardware and system load.

## Linux-native by design

Desktop integration is part of Monstar's core rather than an add-on:

- **XDG desktop portals** open links, local files, and directories with the
  user's preferred applications. Wayland activation tokens make the focus
  handoff clean, and portal settings keep light/dark themes in sync with the
  desktop.
- **D-Bus session services** let terminal applications publish desktop
  notifications and launcher/taskbar progress where supported. Notification
  actions can bring the terminal back into focus without fighting the
  compositor.
- **systemd user services** collect new Monstar windows launched with
  `Ctrl+Shift+N`. Optional per-shell transient scopes keep process accounting
  and memory-pressure handling attached to the shell's process tree instead of
  the terminal itself.
- **Native Wayland protocols** provide fractional scaling, text-input-v3 IME,
  cursor shapes, clipboard and primary selection, server-side decorations,
  named app icons, activation, and the compositor's system bell.

Enable a transient systemd scope for each newly spawned shell with:

```conf
linux-cgroup = always
```

If the session bus or systemd scope is unavailable, Monstar leaves the shell in
its inherited cgroup. Portal link opening falls back to `xdg-open` when the
desktop portal is not available, and optional Wayland protocols have sensible
fallbacks for older compositors.

## Install

Arch Linux users can install the current development version from the
[`monstar-git` AUR package](https://aur.archlinux.org/packages/monstar-git)
with an AUR helper, for example:

```sh
yay -S monstar-git
```

To build and install Monstar from source into `~/.local`:

```sh
zig build -Doptimize=ReleaseFast install --prefix "$HOME/.local"
```

This installs the executable, desktop entry, app icon, manual pages, and bundled
themes. Ensure `$HOME/.local/bin` is on your `PATH`, then launch a shell:

```sh
monstar
```

See [Development](#development) for build requirements.

## Start using Monstar

With no arguments, Monstar starts `$SHELL`, falling back to `/bin/sh`. Use `-e`
to run a command directly:

```sh
monstar -e fish --login
```

Use `--` to run a shell expression:

```sh
monstar -- 'git log --oneline | less'
```

Launcher-friendly options can set the working directory, initial size, title,
app ID, font, and one-off configuration overrides:

```sh
monstar --working-directory ~/src \
  --title scratch \
  --window-size-chars 100x32 \
  --font Iosevka \
  -o background-opacity=0.95
```

Run `monstar --help`, `man monstar`, or `man 5 monstar` for the complete command
and configuration reference.

## Configuration

Monstar reads `$XDG_CONFIG_HOME/monstar/config`, falling back to
`~/.config/monstar/config`. A useful starting point looks like this:

```conf
font-family = Iosevka
font-size = 12.5
theme = light:Rose Pine Dawn,dark:Rose Pine
background-opacity = 0.95
window-padding-x = 8
window-padding-y = 6
mouse-scroll-multiplier = precision:1,discrete:3
```

Without an explicit theme, the built-in colors follow the desktop portal.
Monstar includes a large collection of iTerm2 color schemes and loads custom
themes from `$XDG_CONFIG_HOME/monstar/themes` or `~/.config/monstar/themes`.

Set the default command for new windows. Commands run through `/bin/sh -c`
unless prefixed with `direct:`:

```conf
command = fish --login
# command = direct:fish --no-config
```

Press `Ctrl+Shift+,` or send `SIGUSR1` to reload the configuration:

```sh
pkill -USR1 monstar
```

Visual and interaction settings apply immediately. Settings that control newly
created processes or storage take effect for new windows.

## Keybindings

| Shortcut | Action |
| --- | --- |
| `Ctrl+Shift+C` / `Ctrl+Shift+V` | Copy / paste |
| `Ctrl+Shift+F` | Search scrollback |
| `Ctrl+Shift+N` | Open a new window in the current directory |
| `Ctrl+Shift+,` | Reload configuration |
| `Ctrl++` / `Ctrl+=` / `Ctrl+-` | Adjust the font size |
| `Ctrl+0` | Reset the font size |
| `Ctrl` + left click | Open a hyperlink or detected URI |
| `Ctrl` + drag | Make a rectangular selection |

Scrollback search updates as you type. Use `Ctrl+N` and `Ctrl+P` to move between
matches, `Enter` to accept one as the primary selection, and `Escape` to return
to the previous viewport.

Hold `Shift` while dragging to select text when an application has captured the
mouse. Use `Ctrl+Shift` instead of `Ctrl` to open a link in the same situation.
Middle-click pastes the primary selection.

## Development

Building requires Zig 0.16, the Wayland 1.25 core schema,
wayland-protocols 1.49, and development libraries for Wayland, fontconfig,
FreeType, HarfBuzz, xkbcommon, and D-Bus. Runtime protocol versions are
negotiated with the compositor, so older compositors remain supported.

```sh
zig build
zig build test
zig build fmt
```
