#!/usr/bin/env bash
#
# ts-session.sh
#
# Opens a shell whose traffic is EXCLUDED from the Mullvad tunnel, so you can
# use Tailscale (work servers, home machines) without Mullvad's kill-switch
# blackholing it. Close the shell and all traffic goes back through Mullvad.
# No firewall rules, no persistent routing changes.
#
# Why a shell? mullvad-exclude moves itself into an exclusion cgroup, then execs
# the target. Child processes inherit the parent's cgroup, so EVERY command you
# run from this shell (tailscale, ssh) is excluded automatically.
#
# The excluded Tailscale daemon runs in USERSPACE mode (no tailscale0 device),
# which is what lets it coexist with Mullvad without fighting over routes. The
# catch: plain `ssh 100.x.y.z` won't route in userspace mode. Use the helpers
# below instead; they wire up the daemon socket / SOCKS5 proxy for you.
#
# ---------------------------------------------------------------------------
# HELPERS: tssh / kssh / ts (no more copy-pasting --socket=$TS_SOCK around)
# ---------------------------------------------------------------------------
# Inside every session shell these exist as functions; the standalone scripts
# next to this one do the same FROM ANY TERMINAL by discovering the live
# session in ${XDG_RUNTIME_DIR:-/tmp}/ts-session/ (localhost SOCKS and the
# unix socket are reachable from non-excluded shells too):
#
#   tssh user@peer       SSH with TAILSCALE auth (web login; infrequent
#                        browser "check mode" re-prompts possible)
#   kssh user@100.x.y.z  SSH with YOUR OWN KEYS via the SOCKS5 proxy
#                        (no checks; use the 100.x IP, MagicDNS won't resolve)
#   ts <cmd>             any tailscale command on this session (ts status ...)
#
# Put the standalone ones on PATH once, plus this script as the entrypoint:
#   ln -s "$(pwd)"/{tssh,kssh} ~/.local/bin/
#   ln -s "$(pwd)/ts-session.sh" ~/.local/bin/ts-session
# With several sessions live at once, pick one: tssh -s work user@peer
# (or TS_SESSION=<name>); default is the most recently started live session.
# Each concurrent session gets its own SOCKS5 port automatically (1055, 1056…).
#
# ---------------------------------------------------------------------------
# NO ROOT: the session daemon runs as YOUR USER (and the one limitation)
# ---------------------------------------------------------------------------
# Userspace-networking mode needs no TUN device, so the session tailscaled
# runs unprivileged: no sudo password at start, and, crucially, a RELIABLE
# teardown. (The old sudo-based version orphaned root daemons whenever the
# session outlived sudo's 15-minute credential window: the exit trap's
# `sudo pkill` hit a password prompt inside a dying shell and failed.)
#
# LIMITATION: a non-root tailscaled cannot run the Tailscale SSH *server*,
# so other nodes can't `tailscale ssh` INTO this machine during a session.
# Reaching OUT (tssh/kssh to peers) is unaffected, which is the use case here.
#
# The session also comes up with --shields-up, which blocks ALL inbound
# connections (not just SSH) regardless of the tailnet's ACL. Turn it off for
# one session with: ts set --shields-up=false
#
# GOING BACK TO ROOT (if you ever need inbound Tailscale SSH): in
# launch_session(), prefix the `tailscaled`, `tailscale ... up`, and the
# trap's `tailscale ... down`/`pkill` with sudo, and hand the state dirs to
# root (sudo chown -R root:root ~/.config/ts-session/<name>-state). Be aware
# that teardown then needs a live sudo timestamp at exit again, the flaw
# described above returns.
#
# ---------------------------------------------------------------------------
# MODES
# ---------------------------------------------------------------------------
#   ./ts-session.sh [account]           Option A: excluded shell using the
#                              SYSTEM tailscaled daemon. Optional [account]
#                              switches the system daemon's tailnet first.
#
#   ./ts-session.sh --check [account]   Like default, but verifies the exclusion
#                              is real (shows your real ISP IP first).
#
#   ./ts-session.sh --switch [account]  Just switch the SYSTEM daemon's active
#                              tailnet (no shell). No arg -> picker.
#
#   ./ts-session.sh --list     List live sessions (name, socket, SOCKS5 port)
#                              registered by --robust/--persist runs.
#
#   ./ts-session.sh --robust [keyfile]  Option B, DISPOSABLE: excluded shell +
#                              session-scoped userspace tailscaled with a
#                              THROWAWAY state dir (deleted on exit). Re-auths
#                              every session. Pair with an EPHEMERAL key so the
#                              node auto-removes. Guarantees full exclusion.
#
#   ./ts-session.sh --persist <name> [keyfile]
#                              Option B, PERSISTENT: same excluded userspace
#                              session, but state is kept in
#                              ~/.config/ts-session/<name>-state and NOT deleted
#                              on exit. Registers ONCE (first run), then reuses
#                              the stored identity with no re-auth. Use a
#                              NON-EPHEMERAL key. <name> selects which tailnet
#                              (e.g. 'home' or 'work'), each gets its own
#                              persistent identity. This is the one for "ssh to
#                              home or work, repeatedly, with Mullvad on".
#
#   ./ts-session.sh --boot <name> [keyfile]
#                              Same identity/state as --persist, but with no
#                              interactive shell: runs tailscaled in the
#                              foreground and tears down on SIGTERM/SIGINT
#                              instead of on shell exit. For a systemd unit,
#                              so a Mullvad+Tailscale machine without a login
#                              session still joins the tailnet at boot. See
#                              ts-session@.service. Register the identity
#                              first (a --persist run, or a saved key file) --
#                              there's no browser at boot for a first login.
#                              UNLIKE --persist, this does NOT set shields-up:
#                              a --boot machine exists to be reachable FROM
#                              elsewhere (ssh'd into from the laptop), so it
#                              accepts inbound subject to the tailnet ACL.
#
# DISPOSABLE vs PERSISTENT: --robust leaves no trace (ephemeral key + /tmp state
# wiped on exit). --persist/--boot register each tailnet once and reappear as
# the same stable node every time (non-ephemeral key + kept state). Different
# tailnets = different <name> = different state dir.
#
# ---------------------------------------------------------------------------
# GETTING AUTH KEYS (per tailnet, from the WEB console, daemon not required)
# ---------------------------------------------------------------------------
#   Browser -> https://login.tailscale.com/admin/settings/keys (log into the
#   right tailnet) -> Generate auth key. For --persist use:
#     Reusable: ON   Ephemeral: OFF   Expiry: your call   Tags: if policy needs
#   Save each as ~/.ts/<name>.key (mode 600). This script auto-finds that path:
#     install -m 600 /dev/stdin ~/.ts/home.key       # paste key, Ctrl-D
#     install -m 600 /dev/stdin ~/.ts/work.key       # paste key, Ctrl-D
#
# SECURITY: never pass the raw key as an argument (it lands in shell history).
# Use a key file (auto-found at ~/.ts/<name>.key, or pass a path) or TS_AUTHKEY.
#
# KEYS ARE ONE-SHOT: an auth key is only consulted on the FIRST --persist run
# for a given <name> (registration). Once the identity exists in the state
# dir, the key file is never read again, deleting ~/.ts/<name>.key is safe and
# later runs cannot fail because of it.
#
# ---------------------------------------------------------------------------
# TYPICAL USE (Mullvad always on; system daemon disabled; reach out to peers)
# ---------------------------------------------------------------------------
#   ./ts-session.sh --persist home           # first run registers, later reuse
#     tssh user@home-box                     # tailscale auth
#     kssh user@100.x.y.z                    # your own ssh keys
#     exit
#   ./ts-session.sh --persist work
#     tssh user@work-server
#     exit
#   # ...and from any OTHER terminal while a session is live:
#   tssh user@home-box                       # standalone script, finds session

set -uo pipefail

SESSION_SOCK="/tmp/ts-session-$$.sock"
SOCKS_PORT="1055"                                   # base; bumped if taken
# Registry of live sessions, read by the standalone tssh/kssh scripts.
# Keep in sync with ts_session_dir() in ts-session-lib.sh.
SESSION_DIR="${XDG_RUNTIME_DIR:-/tmp}/ts-session"

# First free port at or above $SOCKS_PORT, so concurrent sessions don't clash.
pick_socks_port() {
  local p="$SOCKS_PORT"
  if command -v ss >/dev/null 2>&1; then
    while ss -Hltn 2>/dev/null | awk '{print $4}' | grep -q ":${p}\$"; do
      p=$((p + 1))
    done
  fi
  echo "$p"
}

if ! command -v mullvad-exclude >/dev/null 2>&1; then
  echo "mullvad-exclude not found. Is the Mullvad app installed?" >&2
  echo "(If this laptop is Mullvad-free, you don't need this script, just use" >&2
  echo " the system tailscaled daemon directly.)" >&2
  exit 1
fi
if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale not found. Install it first." >&2
  exit 1
fi

# tailscaled usually lives in /usr/sbin, which is not on regular users' PATH
# (the old sudo-based version found it via sudo's secure_path). Resolve it
# explicitly; only --robust/--persist need it (checked in launch_session).
TAILSCALED_BIN="$(command -v tailscaled || true)"
if [ -z "$TAILSCALED_BIN" ]; then
  for p in /usr/sbin/tailscaled /usr/local/sbin/tailscaled /sbin/tailscaled; do
    if [ -x "$p" ]; then TAILSCALED_BIN="$p"; break; fi
  done
fi

# --- account picker (Option A / system daemon only) ------------------------
pick_account() {
  local want="${1:-}"
  if [ -n "$want" ]; then echo "$want"; return 0; fi
  local profiles
  profiles="$(tailscale switch --list 2>/dev/null | tail -n +2 | awk '{print $1}')"
  [ -z "$profiles" ] && return 1
  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$profiles" | fzf --prompt="tailnet> " --height=40%
  else
    echo "Available accounts:" >&2
    local i=1 p
    local -a arr=()
    while IFS= read -r p; do arr+=("$p"); echo "  $i) $p" >&2; i=$((i + 1)); done <<< "$profiles"
    printf "Pick a number: " >&2
    local n; read -r n
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#arr[@]}" ]; then
      echo "${arr[$((n - 1))]}"
    else
      return 1
    fi
  fi
}

# --- resolve state dir + auth key for a persisted (named) identity ---------
# Shared by --persist (interactive) and --boot (systemd). Sets STATEDIR and
# AUTHKEY as globals; exits 1 on an unrecoverable problem.
resolve_persist() {
  local name="$1" keyfile_arg="$2"
  STATEDIR="$HOME/.config/ts-session/${name}-state"
  # Two daemons on one statedir end badly; point at the live session instead.
  if [ -e "$SESSION_DIR/${name}.env" ] &&
     [ -S "$(sed -n 's/^TS_SOCK=//p' "$SESSION_DIR/${name}.env")" ]; then
    echo "==> WARNING: a '$name' session already looks LIVE. Instead of a second"
    echo "    session, just run tssh/kssh from this terminal, they'll find it."
  fi
  # Migration from the old sudo-based version: root-owned state would make
  # the user-run tailscaled fail (or worse, silently re-register).
  if [ -e "$STATEDIR" ] && [ ! -O "$STATEDIR" ]; then
    echo "==> '$name' state dir is not owned by you (left by the old sudo-based" >&2
    echo "    version of this script). Reclaim it once, then re-run:" >&2
    echo "        sudo chown -R \"\$USER\" '$STATEDIR'" >&2
    exit 1
  fi
  AUTHKEY=""
  if [ -s "$STATEDIR/tailscaled.state" ]; then
    # Registered already: the auth key is one-shot (first registration only)
    # and is deliberately never consulted again, so deleting it is safe.
    echo "==> Reusing stored '$name' identity (no re-auth, no auth key needed)."
    [ -f "$HOME/.ts/${name}.key" ] && \
      echo "    (~/.ts/${name}.key is no longer used; safe to delete.)"
  else
    # First registration for this tailnet: find a key or go interactive.
    # NOTE: TS_AUTHKEY is deliberately NOT used here, it's ambiguous across
    # tailnets; per-name key files avoid registering with the wrong account.
    if [ -n "$keyfile_arg" ] && [ -f "$keyfile_arg" ]; then
      AUTHKEY="$(tr -d '[:space:]' < "$keyfile_arg")"
      echo "==> First run for '$name': using key file $keyfile_arg"
    elif [ -f "$HOME/.ts/${name}.key" ]; then
      AUTHKEY="$(tr -d '[:space:]' < "$HOME/.ts/${name}.key")"
      echo "==> First run for '$name': using ~/.ts/${name}.key"
    else
      [ -n "$keyfile_arg" ] && \
        echo "==> WARNING: key file '$keyfile_arg' not found, ignoring it."
      echo "==> First run for '$name': no key file found; interactive login URL will appear."
      echo "    (Tip: save one at ~/.ts/${name}.key for unattended future runs.)"
    fi
  fi
}

# --- launch an excluded userspace Tailscale session ------------------------
# args: <name> <statedir> <up_args> <teardown_state_cmd>
launch_session() {
  local name="$1" statedir="$2" up_args="$3" teardown_state="$4"
  local sock="$SESSION_SOCK" log="/tmp/ts-session-$$.log"
  local envfile="${SESSION_DIR}/${name}.env"
  local socks_port
  if [ -z "$TAILSCALED_BIN" ]; then
    echo "ERROR: tailscaled binary not found (checked PATH, /usr/sbin," >&2
    echo "       /usr/local/sbin, /sbin). Install tailscale first." >&2
    exit 1
  fi
  socks_port="$(pick_socks_port)"
  mkdir -p "$(dirname "$statedir")" "$SESSION_DIR"
  exec mullvad-exclude bash --rcfile <(cat <<RC
export TS_SESSION_NAME="${name}"
export TS_SOCK="${sock}"
export TS_SOCKS_PORT="${socks_port}"
ts()   { command tailscale --socket="\$TS_SOCK" "\$@"; }
tssh() { command tailscale --socket="\$TS_SOCK" ssh "\$@"; }
kssh() { command ssh -o ProxyCommand="nc -X 5 -x localhost:\$TS_SOCKS_PORT %h %p" "\$@"; }
export -f ts tssh kssh
echo "--- starting session-scoped tailscaled (userspace, SOCKS5 on ${socks_port}, no root) ---"
"${TAILSCALED_BIN}" --tun=userspace-networking --socks5-server=localhost:${socks_port} --socket="${sock}" --statedir="${statedir}" >"${log}" 2>&1 &
for _ in \$(seq 1 20); do [ -S "${sock}" ] && break; sleep 0.5; done
if [ ! -S "${sock}" ]; then
  echo "ERROR: session tailscaled failed to start; its log says:"
  echo "------------------------------------------------------------"
  cat "${log}"
  echo "------------------------------------------------------------"
  pkill -f "tailscaled.*${sock}" 2>/dev/null
  rm -f "${log}"
  exit 1
fi
echo "Bringing Tailscale up (login URL appears only on first registration):"
tailscale --socket="${sock}" up --shields-up ${up_args}
echo ""
tailscale --socket="${sock}" status || true
printf 'TS_SESSION_NAME=%s\nTS_SOCK=%s\nTS_SOCKS_PORT=%s\nTS_SESSION_PID=%s\n' \
  "${name}" "${sock}" "${socks_port}" "\$\$" > "${envfile}"
echo ""
echo "=== SSH IN THIS SESSION '${name}' (also from any other terminal) ==="
echo "    tssh user@<peer-or-100.x>    Tailscale-managed auth (web login)"
echo "    kssh user@<100.x-ip>         your own SSH keys, via SOCKS5 :${socks_port}"
echo "    ts <cmd>                     tailscale cmd on this session (ts status)"
echo "===================================================================="
echo ""
echo "Type 'exit' when done; the session tailscaled is stopped automatically."
trap 'echo "--- tearing down session tailscaled ---"; tailscale --socket="${sock}" down 2>/dev/null; pkill -f "tailscaled.*${sock}" 2>/dev/null; rm -f "${sock}" "${log}" "${envfile}"; ${teardown_state}' EXIT
RC
)
}

# --- same, but non-interactive for a systemd unit (--boot) -----------------
# No shell for a human to sit in: runs tailscaled in the foreground and tears
# down on SIGTERM/SIGINT (what systemd sends on stop) instead of an
# interactive shell's EXIT. Kept separate from launch_session() rather than
# merged: the two heredocs quote very differently (--rcfile vs a plain
# script), so sharing them would cost more than the ~15 duplicated lines.
# State always persists (like --persist); there's no disposable boot mode.
# args: <name> <statedir> <up_args>
launch_session_boot() {
  local name="$1" statedir="$2" up_args="$3"
  local sock="$SESSION_SOCK" log="/tmp/ts-session-$$.log"
  local envfile="${SESSION_DIR}/${name}.env"
  local socks_port
  if [ -z "$TAILSCALED_BIN" ]; then
    echo "ERROR: tailscaled binary not found (checked PATH, /usr/sbin," >&2
    echo "       /usr/local/sbin, /sbin). Install tailscale first." >&2
    exit 1
  fi
  socks_port="$(pick_socks_port)"
  mkdir -p "$(dirname "$statedir")" "$SESSION_DIR"
  exec mullvad-exclude bash <(cat <<RC
set -u
echo "--- starting session-scoped tailscaled (userspace, SOCKS5 on ${socks_port}, no root) ---"
"${TAILSCALED_BIN}" --tun=userspace-networking --socks5-server=localhost:${socks_port} --socket="${sock}" --statedir="${statedir}" >"${log}" 2>&1 &
TAILSCALED_PID=\$!
for _ in \$(seq 1 20); do [ -S "${sock}" ] && break; sleep 0.5; done
if [ ! -S "${sock}" ]; then
  echo "ERROR: session tailscaled failed to start; its log says:"
  cat "${log}"
  exit 1
fi
echo "Bringing Tailscale up (first run with no auth key: grab the login URL from"
echo "this unit's journal and open it once -- journalctl -u ts-session@${name}):"
# Explicit --shields-up=false, not just omitted: unlike launch_session(),
# --boot exists to make this machine reachable FROM elsewhere (the whole
# point of a fleet member). 'tailscale up' refuses to silently drop a
# previously-set non-default flag (it errors asking you to restate it), so
# if this identity was ever brought up with shields-up=true -- e.g. it was
# first registered via --persist before this got added -- merely omitting
# the flag here would leave shields-up stuck on and 'up' would no-op.
tailscale --socket="${sock}" up --shields-up=false ${up_args}
tailscale --socket="${sock}" status || true
printf 'TS_SESSION_NAME=%s\nTS_SOCK=%s\nTS_SOCKS_PORT=%s\nTS_SESSION_PID=%s\n' \
  "${name}" "${sock}" "${socks_port}" "\$\$" > "${envfile}"
echo "--- '${name}' session up; tssh/kssh work from any terminal on this box now ---"
teardown() {
  echo "--- tearing down session tailscaled (signal received) ---"
  tailscale --socket="${sock}" down 2>/dev/null
  kill "\$TAILSCALED_PID" 2>/dev/null
  rm -f "${sock}" "${log}" "${envfile}"
  exit 0
}
trap teardown TERM INT
wait "\$TAILSCALED_PID"
RC
)
}

# --- info banner -----------------------------------------------------------
if command -v mullvad >/dev/null 2>&1; then
  # sed -n 1p, not head -1: head closing the pipe early kills mullvad with
  # SIGPIPE, which pipefail turns into a bogus "unknown" on top of real output.
  mullvad_status="$(mullvad status 2>/dev/null | sed -n '1p')"
  echo "==> Mullvad: ${mullvad_status:-unknown}"
fi
if systemctl is-active --quiet tailscaled 2>/dev/null; then
  echo "==> Note: system tailscaled is ACTIVE (inside Mullvad's tunnel). For"
  echo "    guaranteed exclusion use --robust/--persist, or disable it:"
  echo "        sudo systemctl disable --now tailscaled"
else
  echo "==> system tailscaled daemon is not running (good for --robust/--persist)."
fi
echo ""

mode="${1:-default}"

case "$mode" in
  --switch)
    account="${2:-}"
    chosen="$(pick_account "$account")" || { echo "No account chosen." >&2; exit 1; }
    echo "==> Switching active tailnet to: $chosen"
    tailscale switch "$chosen"
    tailscale switch --list
    exit 0
    ;;

  --robust)
    keyfile_arg="${2:-}"
    echo "==> ROBUST mode (disposable userspace session, full exclusion)."
    AUTHKEY=""
    if [ -n "${TS_AUTHKEY:-}" ]; then
      AUTHKEY="${TS_AUTHKEY}"; echo "==> Using auth key from TS_AUTHKEY."
    elif [ -n "$keyfile_arg" ] && [ -f "$keyfile_arg" ]; then
      AUTHKEY="$(tr -d '[:space:]' < "$keyfile_arg")"; echo "==> Using key file: $keyfile_arg"
    elif [ -n "$keyfile_arg" ] && [[ "$keyfile_arg" == tskey-* ]]; then
      AUTHKEY="$keyfile_arg"
      echo "==> WARNING: raw key on the command line is now in your shell history."
      echo "    Prefer a key file or TS_AUTHKEY, and consider rotating this key."
    else
      echo "==> No key: interactive login URL will appear."
    fi
    SESSION_STATEDIR="/tmp/ts-session-$$-state"
    UP_ARGS=""; [ -n "$AUTHKEY" ] && UP_ARGS="--auth-key=${AUTHKEY}"
    launch_session "robust-$$" "$SESSION_STATEDIR" "$UP_ARGS" "rm -rf \"$SESSION_STATEDIR\""
    ;;

  --persist)
    name="${2:-default}"
    keyfile_arg="${3:-}"
    resolve_persist "$name" "$keyfile_arg"
    echo "==> PERSIST mode: tailnet '$name', state kept at $STATEDIR"
    UP_ARGS=""; [ -n "$AUTHKEY" ] && UP_ARGS="--auth-key=${AUTHKEY}"
    launch_session "$name" "$STATEDIR" "$UP_ARGS" ""   # empty teardown = keep state
    ;;

  --boot)
    name="${2:-}"
    keyfile_arg="${3:-}"
    if [ -z "$name" ]; then
      echo "Usage: $0 --boot <name> [keyfile]" >&2
      exit 1
    fi
    resolve_persist "$name" "$keyfile_arg"
    echo "==> BOOT mode: non-interactive '$name' session for a systemd unit, state kept at $STATEDIR"
    UP_ARGS=""; [ -n "$AUTHKEY" ] && UP_ARGS="--auth-key=${AUTHKEY}"
    launch_session_boot "$name" "$STATEDIR" "$UP_ARGS"
    ;;

  --list)
    found=0
    for f in "$SESSION_DIR"/*.env; do
      [ -e "$f" ] || continue
      sock="$(sed -n 's/^TS_SOCK=//p' "$f")"
      if [ -S "$sock" ]; then
        printf '%-14s socks5=localhost:%-6s pid=%-8s %s\n' \
          "$(sed -n 's/^TS_SESSION_NAME=//p' "$f")" \
          "$(sed -n 's/^TS_SOCKS_PORT=//p' "$f")" \
          "$(sed -n 's/^TS_SESSION_PID=//p' "$f")" \
          "$sock"
        found=1
      else
        rm -f "$f"    # stale entry from a hard-killed session
      fi
    done
    [ "$found" -eq 1 ] || echo "No live sessions. Start one: $0 --persist <name>"
    exit 0
    ;;

  --check)
    account="${2:-}"
    if [ -n "$account" ]; then
      chosen="$(pick_account "$account")" || { echo "No account chosen." >&2; exit 1; }
      echo "==> Switching active tailnet to: $chosen"; tailscale switch "$chosen"
    fi
    echo "==> CHECK mode: excluded shell + verify exclusion is real."
    exec mullvad-exclude bash --rcfile <(cat <<'RC'
echo "--- exclusion check ---"
echo -n "This shell's exit IP: "
curl -s --max-time 8 https://am.i.mullvad.net/ip || echo "(couldn't reach check service)"
echo -n "Mullvad sees this shell as: "
curl -s --max-time 8 https://am.i.mullvad.net/connected || echo "(couldn't reach check service)"
echo "-----------------------"
echo "If 'connected' says NOT using Mullvad, exclusion is working."
RC
)
    ;;

  default)
    account="${1:-}"   # in default mode $1 is the (optional) account itself
    if [ -n "$account" ]; then
      chosen="$(pick_account "$account")" || { echo "No account chosen." >&2; exit 1; }
      echo "==> Switching active tailnet to: $chosen"; tailscale switch "$chosen"
    fi
    echo "==> Opening a Mullvad-excluded shell (Option A, system daemon)."
    echo "==> Type 'exit' when done to restore normal (Mullvad) routing."
    exec mullvad-exclude bash
    ;;

  *)
    # Treat an unknown FIRST token as an account name for default mode.
    if [[ "$mode" != --* ]]; then
      chosen="$(pick_account "$mode")" || { echo "No account chosen." >&2; exit 1; }
      echo "==> Switching active tailnet to: $chosen"; tailscale switch "$chosen"
      echo "==> Opening a Mullvad-excluded shell (Option A, system daemon)."
      exec mullvad-exclude bash
    fi
    echo "Unknown option: $mode" >&2
    echo "Use: [account] | --check [account] | --switch [account] | --list | --robust [keyfile] | --persist <name> [keyfile] | --boot <name> [keyfile]" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# NOTE ON DISABLING THE SYSTEM tailscaled DAEMON (on THIS Mullvad laptop)
# ---------------------------------------------------------------------------
# Because Tailscale is only usable here from inside a Mullvad-excluded shell,
# running the system daemon 24/7 (inside the tunnel, blackholed) buys nothing.
# Disable it, then use --persist (or --robust):
#   sudo systemctl disable --now tailscaled
# Trade-off: incoming connections TO this laptop won't work while idle, and
# the session daemon itself comes up --shields-up (see the LIMITATION note
# above), so inbound is blocked whenever a session is live too. That's fine
# for reaching OUT (home / work). Re-enable the system daemon, or
# `ts set --shields-up=false`, if you ever need inbound.
