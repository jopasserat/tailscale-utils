# shellcheck shell=bash
# ts-session-lib.sh - shared session discovery, sourced by tssh and kssh.
#
# A running ts-session.sh session registers itself in
#   ${XDG_RUNTIME_DIR:-/tmp}/ts-session/<name>.env
# with its TS_SOCK, TS_SOCKS_PORT and shell PID. This lib finds a live session
# and exports those variables, which is what lets tssh/kssh work from ANY
# terminal (localhost SOCKS + the unix socket are reachable regardless of the
# Mullvad exclusion cgroup), not just inside the session shell.
#
# Selection order for ts_find_session [name]:
#   1. $TS_SOCK already set and live (you're inside a session shell) unless a
#      name was requested explicitly
#   2. the session registered as <name> (arg, or $TS_SESSION), if live
#   3. otherwise the most recently registered live session
# Stale registry entries (socket gone, e.g. after a hard kill) are pruned as
# they're encountered. Returns 1 if no live session is found.

ts_session_dir() { echo "${XDG_RUNTIME_DIR:-/tmp}/ts-session"; }

ts_find_session() {
  local want="${1:-${TS_SESSION:-}}"
  if [ -z "$want" ] && [ -n "${TS_SOCK:-}" ] && [ -S "${TS_SOCK}" ]; then
    return 0
  fi
  local dir f sock best=""
  dir="$(ts_session_dir)"
  for f in "$dir"/*.env; do
    [ -e "$f" ] || continue
    if [ -n "$want" ] && [ "$f" != "$dir/$want.env" ]; then continue; fi
    sock="$(sed -n 's/^TS_SOCK=//p' "$f")"
    if [ ! -S "$sock" ]; then rm -f "$f" 2>/dev/null; continue; fi
    if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best="$f"; fi
  done
  [ -n "$best" ] || return 1
  TS_SESSION_NAME="$(sed -n 's/^TS_SESSION_NAME=//p' "$best")"
  TS_SOCK="$(sed -n 's/^TS_SOCK=//p' "$best")"
  TS_SOCKS_PORT="$(sed -n 's/^TS_SOCKS_PORT=//p' "$best")"
  export TS_SESSION_NAME TS_SOCK TS_SOCKS_PORT
}
