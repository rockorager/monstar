# Rex hosts for Omarchy

A "Rex hosts" row for the [Omarchy](https://omarchy.org) menu that opens
monstar on a [Rex](https://www.superlogical.com/rex) host. It needs Omarchy 4,
monstar 1.4 or later, `rex`, and `jq`.

Choosing the row lists this machine and the hosts from `rex hosts`. After you
pick a host, it lists "New shell" and the host's running monstar shells, with
detached shells (Super+D in a `--rex` window) first, and opens a monstar window
on your choice. A host with no shells opens a new one straight away.

## Install

```sh
install -Dm755 rex-launch ~/.local/bin/rex-launch
```

Then add the `"rex"` entry from `omarchy-menu.jsonc` to
`~/.config/omarchy/extensions/omarchy-menu.jsonc`, creating the file as a JSON
object if it does not exist. The menu reloads the file by itself.

The picker only lists hosts you have added with
`rex hosts add LABEL ENDPOINT`, such as `rex hosts add studio studio`. For
each host it opens the first endpoint monstar supports, skipping `https://`
endpoints and Unix sockets missing on this machine.
