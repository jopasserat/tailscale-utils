# ts-session.sh: what persists, for how long, and switching tailnets

This covers two things: exactly what survives (and what doesn't) when you close a
`--persist` session, and the concrete steps to reach a second tailnet.

## The four different "lifetimes" (don't conflate them)

When you run `./ts-session.sh --persist home` (or `work`), four separate
clocks are in play. Confusing them is the main source of "wait, why did it ask
me to log in again?" surprises.

### 1. The session itself: lives only while the shell is open

The excluded shell and its userspace `tailscaled` exist **only between launch and
`exit`**. On `exit`, the trap runs `tailscale down`, kills the session daemon,
and removes the socket. There is no background daemon left running, that's the
whole point of the Mullvad-exclusion design. So "how long does the session
persist?" = exactly as long as you keep the shell open. Close it and Tailscale is
gone from this machine until you start another session.

### 2. The node IDENTITY: persists on disk indefinitely (that's --persist)

What `--persist` keeps between sessions is the **registration**, stored in
`~/.config/ts-session/<name>-state/tailscaled.state`. This is NOT deleted on
exit. It holds the node key, so the *next* session reuses the same identity with
no re-auth. This file persists until you delete it. This is the only thing that
survives a session, and it's just an identity, not a running connection.

  - `--persist` keeps it  -> register once, reappear as the same node each time.
  - `--robust` deletes it  -> fresh identity every session (re-auth each time).

### 3. The NODE KEY expiry: 180 days by default

Even a persisted identity has a clock. Each device's node key, by default,
expires 180 days after login, after which the node must re-authenticate (a
browser login) before it works again. So a `--persist` node that you never touch
will, at the 180-day mark, require one interactive re-login. Two ways to handle:

  - **Disable key expiry for this node** (recommended for a machine you don't
    want to babysit): admin console -> Machines -> your device -> menu ->
    "Disable Key Expiry". Then the identity never forces a re-login.
  - **Or just re-authenticate** when it happens: start a session and follow the
    login URL once.

  Note: nodes registered with a TAG have key expiry disabled automatically. So
  if your work key is tagged (see below), that node likely won't hit the
  180-day wall at all.

### 4. The AUTH KEY expiry: 1-90 days, but only matters for FIRST registration

The `tskey-auth-...` you saved in `~/.ts/<name>.key` expires between 1 and 90
days (90 max if unspecified). BUT this clock only governs *registering new
nodes*. Once a node is registered, an expired auth key does not affect it, the
node runs on its own node key (#3). So:

  - The auth key is only consulted on the FIRST `--persist <name>` run.
  - After that, you can let the auth key expire; this machine keeps working.
  - You'd only need a fresh auth key to register a *different* machine later.

### Summary table

| Thing                        | Lifetime                    | Deleted on exit? |
|------------------------------|-----------------------------|------------------|
| Running session + daemon     | until you type `exit`       | yes (by design)  |
| Node identity (`--persist`)  | until you delete state dir  | NO (persists)    |
| Node key (the identity's)    | 180 days (or disabled)      | n/a              |
| Auth key in `~/.ts/*.key`    | 1-90 days, first-reg only   | n/a              |

Also periodic, separate from all four: **Tailscale SSH check mode** (`tssh`) may
ask for a browser re-check roughly daily, or after network changes. That's an
SSH-session check, not a node/key expiry, and `kssh` (your own keys via SOCKS)
avoids it entirely.

## The tssh / kssh helpers work from ANY terminal

Inside a session shell, `tssh`, `kssh` and `ts` are functions wired to that
session's socket, no `--socket=$TS_SOCK` copy-pasting. The standalone scripts
in this repo do the same from any *other* terminal: a live session registers
itself in `${XDG_RUNTIME_DIR:-/tmp}/ts-session/<name>.env`, and the scripts
find it there (the daemon's unix socket and localhost SOCKS proxy are
reachable from non-excluded shells too). Put them on PATH once:

```bash
ln -s "$(pwd)"/{tssh,kssh} ~/.local/bin/
```

With several sessions live at once, pick one with `tssh -s work ...` (or
`TS_SESSION=work`); the default is the most recently started live
session. `./ts-session.sh --list` shows what's live.

## Switching to a second tailnet (e.g. work)

The two tailnets are fully separate identities. You don't "switch" a running
session, you just start a session pointed at the other one. `<name>` selects
which tailnet.

### First time (once per tailnet)

1. In a browser, log into the target tailnet's admin console:
   https://login.tailscale.com/admin/settings/keys
   (switch accounts in the browser if you're on your personal tailnet).
2. Generate an auth key: Reusable ON, Ephemeral OFF. If the tailnet's policy
   requires a tag, set it here (ask their tailnet admin which tag). Tagged nodes
   also get key expiry disabled automatically.
3. Save it locally, mode 600, under the name the script auto-finds:
   ```bash
   install -m 600 /dev/stdin ~/.ts/work.key   # paste the key, then Ctrl-D
   ```

### Every time after

```bash
./ts-session.sh --persist work
#   first run: registers using ~/.ts/work.key
#   later runs: reuses the stored work identity, no re-auth
tssh user@work-server        # Tailscale-managed auth (may do a browser check)
#   or
kssh user@100.x.y.z               # your own SSH keys, no check, use the 100.x IP
exit                              # session ends; identity persists for next time
```

Personal/home is identical with `home` in place of `work`. Because they're
separate state dirs and separate identities, you can even run one session for
each at the same time in two terminals if you ever need both at once, they don't
share the single-tailnet-at-a-time limit that the system daemon's `switch` has,
since each is its own userspace daemon.

---

Sources (Tailscale official docs):
- Auth keys (auth-key expiry 1-90 days, node-key default 180 days):
  https://tailscale.com/docs/features/access-control/auth-keys
- Key expiry (180-day default, disable per device, tagged-node behaviour):
  https://tailscale.com/docs/features/access-control/key-expiry
