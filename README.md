# tailscale-utils

Use Tailscale alongside Mullvad without fighting the kill-switch: open a
Mullvad-excluded shell running a session-scoped userspace `tailscaled`, ssh to
your tailnet peers, `exit`, and everything routes back through Mullvad.

## Setup (once per tailnet)

```bash
# put the entrypoint and ssh helpers on PATH:
ln -s "$(pwd)"/{tssh,kssh} ~/.local/bin/
ln -s "$(pwd)/ts-session.sh" ~/.local/bin/ts-session

# generate an auth key (Reusable ON, Ephemeral OFF) at
# https://login.tailscale.com/admin/settings/keys, then:
install -m 600 /dev/stdin ~/.ts/work.key   # paste key, Ctrl-D
```

The auth key is **one-shot**: it's only read on the first `--persist` run to
register the node. After that you can delete `~/.ts/<name>.key`; later runs
never look for it. (No key at all also works, you just get an interactive
login URL on first run.)

## Use

```bash
ts-session --persist work   # first run registers, later runs reuse
tssh user@peer                   # Tailscale-managed auth (web login)
kssh user@100.x.y.z              # your own SSH keys, via SOCKS5
ts status                        # any tailscale cmd on this session
exit                             # teardown; identity persists
```

`tssh`/`kssh` also work from **any other terminal** while a session is live
(pick one with `-s <name>` if several are running). `ts-session --list` shows
live sessions; `--robust` gives a disposable session instead; the header
comments in `ts-session.sh` cover all modes.

## Files

- `ts-session.sh` — session launcher (all modes documented in its header)
- `tssh` / `kssh` — standalone ssh helpers, session auto-discovery
- `ts-session-lib.sh` — shared discovery lib
- `ts-session-lifetime.md` — what persists between sessions, key expiry, per-tailnet setup
