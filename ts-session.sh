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
# Put the standalone ones on PATH once:
#   ln -s "$(pwd)"/{tssh,kssh} ~/.local/bin/
# With several sessions live at once, pick one: tssh -s work user@peer
# (or TS_SESSION=<name>); default is the most recently started live session.
# Each concurrent session gets its own SOCKS5 port automatically (1055, 1056…).
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
# DISPOSABLE vs PERSISTENT: --robust leaves no trace (ephemeral key + /tmp state
# wiped on exit). --persist registers each tailnet once and reappears as the
# same stable node every time (non-ephemeral key + kept state). Different
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
#     install -m 600 /dev/stdin ~/.ts/work.key  # paste key, Ctrl-D
#
# SECURITY: never pass the raw key as an argument (it lands in shell history).
# Use a key file (auto-found at ~/.ts/<name>.key, or pass a path) or TS_AUTHKEY.
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

# --- launch an excluded userspace Tailscale session ------------------------
# args: <name> <statedir> <up_args> <teardown_state_cmd>
launch_session() {
  local name="$1" statedir="$2" up_args="$3" teardown_state="$4"
  local sock="$SESSION_SOCK" log="/tmp/ts-session-$$.log"
  local envfile="${SESSION_DIR}/${name}.env"
  local socks_port
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
echo "--- starting session-scoped tailscaled (userspace, SOCKS5 on ${socks_port}) ---"
# Prime sudo NOW, in the foreground: the backgrounded tailscaled below has its
# output redirected, so a sudo password prompt there would silently hang/fail.
sudo -v || echo "WARNING: sudo auth failed; tailscaled will not start."
sudo tailscaled --tun=userspace-networking --socks5-server=localhost:${socks_port} --socket="${sock}" --statedir="${statedir}" >"${log}" 2>&1 &
for _ in \$(seq 1 20); do [ -S "${sock}" ] && break; sleep 0.5; done
[ -S "${sock}" ] || echo "WARNING: tailscaled socket never appeared; check ${log}"
echo "Bringing Tailscale up (login URL appears only on first registration):"
sudo tailscale --socket="${sock}" up ${up_args}
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
trap 'echo "--- tearing down session tailscaled ---"; sudo tailscale --socket="${sock}" down 2>/dev/null; sudo pkill -f "tailscaled.*${sock}" 2>/dev/null; rm -f "${sock}" "${log}" "${envfile}"; ${teardown_state}' EXIT
RC
)
}

# --- info banner -----------------------------------------------------------
if command -v mullvad >/dev/null 2>&1; then
  echo "==> Mullvad: $(mullvad status 2>/dev/null | head -1 || echo unknown)"
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
    launch_session "robust-$$" "$SESSION_STATEDIR" "$UP_ARGS" "sudo rm -rf \"$SESSION_STATEDIR\""
    ;;

  --persist)
    name="${2:-default}"
    keyfile_arg="${3:-}"
    STATEDIR="$HOME/.config/ts-session/${name}-state"
    echo "==> PERSIST mode: tailnet '$name', state kept at $STATEDIR"
    # Two daemons on one statedir end badly; point at the live session instead.
    if [ -e "$SESSION_DIR/${name}.env" ] &&
       [ -S "$(sed -n 's/^TS_SOCK=//p' "$SESSION_DIR/${name}.env")" ]; then
      echo "==> WARNING: a '$name' session already looks LIVE. Instead of a second"
      echo "    session, just run tssh/kssh from this terminal, they'll find it."
    fi
    AUTHKEY=""
    if [ -s "$STATEDIR/tailscaled.state" ]; then
      echo "==> Reusing stored '$name' identity (no re-auth needed)."
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
        echo "==> First run for '$name': no key file found; interactive login URL will appear."
        echo "    (Tip: save one at ~/.ts/${name}.key for unattended future runs.)"
      fi
    fi
    UP_ARGS=""; [ -n "$AUTHKEY" ] && UP_ARGS="--auth-key=${AUTHKEY}"
    launch_session "$name" "$STATEDIR" "$UP_ARGS" ""   # empty teardown = keep state
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
    echo "Use: [account] | --check [account] | --switch [account] | --robust [keyfile] | --persist <name> [keyfile]" >&2
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
# Trade-off: incoming connections TO this laptop won't work while idle. That's
# fine for reaching OUT (home / work). Re-enable if you ever need inbound.
