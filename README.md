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
ts-session --persist work        # first run registers, later runs reuse
tssh user@peer                   # Tailscale-managed auth (web login)
kssh user@100.x.y.z              # your own SSH keys, via SOCKS5
ts status                        # any tailscale cmd on this session
exit                             # teardown; identity persists
```

`tssh`/`kssh` also work from **any other terminal** while a session is live
(pick one with `-s <name>` if several are running). `ts-session --list` shows
live sessions; `--robust` gives a disposable session instead; the header
comments in `ts-session.sh` cover all modes.

The session daemon runs **as your user** (userspace networking needs no
root): no sudo password, and teardown can't be stranded by an expired sudo
prompt. The trade-off: this machine can't accept inbound `tailscale ssh`
during a session — outbound only. The session also comes up `--shields-up`,
blocking all other inbound connections too, regardless of the tailnet's ACL
(`ts set --shields-up=false` to lift it for one session). If you ever need
inbound, the header of `ts-session.sh` describes the path back to a root
daemon.

## Boot persistence (machine has no login session, e.g. a headless box)

`--persist` needs a shell to stay open. For a machine that must join the
tailnet at boot with nobody logged in, use `--boot` instead, under systemd:

```bash
# once, interactively, to register the identity (there's no browser at boot):
ts-session --persist home

# then install the unit (fill in User= and the ExecStart path first):
sudo cp ts-session@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ts-session@home.service
journalctl -u ts-session@home -f
```

Same identity and state dir as `--persist`, just no interactive shell.
`tssh`/`kssh` from any terminal on that box find it the same way. Unlike
`--persist`, `--boot` does **not** set shields-up — the point of putting a
machine on the fleet is being reachable from elsewhere, so it accepts
inbound (subject to your tailnet's ACL). Only use this on a machine that
also runs Mullvad (or another VPN with its own `mullvad-exclude`-equivalent
cgroup exclusion) and needs the same exclusion trick; a plain machine just
needs stock `tailscale up`.

To confirm a `--boot` machine actually joined, don't use `ts-session --list`
— that only shows sessions live **on the host you run it from**. Check with
`ts status` from any live session, or the admin console's Machines list.

## License

[GPLv3](LICENSE).

## Files

- `ts-session.sh` — session launcher (all modes documented in its header)
- `ts-session@.service` — systemd unit template for `--boot` (headless/boot persistence)
- `tssh` / `kssh` — standalone ssh helpers, session auto-discovery
- `ts-session-lib.sh` — shared discovery lib
- `ts-session-lifetime.md` — what persists between sessions, key expiry, per-tailnet setup
