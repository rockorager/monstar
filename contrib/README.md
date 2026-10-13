# pam-cgroup-userwork

pam_exec helper (runs as root at login) that delegates a writable cgroup v2 subtree with the appropriate permissions to each user. This cgroup subtree can then be used by Monstar's cgroupfs backend.

If you're using systemd then this helper is not needed causes systemd already does that by itself.

## How it works

The script creates `/sys/fs/cgroup/userwork/<uid>`, enables the memory and pids controllers for its children, chowns it to the user, and moves the session process into it. Requires a mounted cgroup v2 hierarchy.

## Install

```sh
install -m755 pam-cgroup-userwork /usr/local/bin/
```

and register it in the session PAM stack:

```
session optional pam_exec.so /usr/local/bin/pam-cgroup-userwork
```
Add this line to any PAM stack (typically in `/etc/pam.d`) that is executed during your usual login. Different Linux distributions typically prefer different stacks for that; check your distribution's documentation. The most universal way to find the right stack is to check what's included by `login` (i.e. by `/etc/pam.d/login` or `/usr/lib/pam.d/login`)

## Test

Apply changes described above and re-login; `/proc/self/cgroup` should then show a `0::/userwork/<uid>` entry.

If you rename the subtree (anything other than `userwork`), set `linux-cgroup-path` in Monstar's config to the matching absolute base path within the cgroup v2 mount, e.g. `linux-cgroup-path = /mysubtree`; Monstar appends `/<uid>` itself.
