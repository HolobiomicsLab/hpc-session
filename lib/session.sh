# The session itself: optional VPN, one authenticated SSH master, and the exec wrappers.
#
# Why a master socket is not optional under TOTP 2FA: pam_google_authenticator refuses to
# reuse a code, so two fresh logins inside one time step see the second REJECTED. One
# master authenticates once; every later ssh/scp/rsync multiplexes over it and does not
# authenticate at all.

# ControlPath uses %C (a hash of the connection parameters) to stay well inside the
# ~104-character limit on unix socket paths.
hs_ssh_opts() {
  printf -- '-o ControlMaster=auto -o ControlPath=%s/%%C -o ControlPersist=%s' \
    "$HS_CONTROL_DIR" "$HS_CONTROL_PERSIST"
}

# shellcheck disable=SC2046  # word splitting of the option list is intended
hs_ssh() { ssh $(hs_ssh_opts) "$@"; }

hs_master_up() { hs_ssh -O check "$HS_HOST" >/dev/null 2>&1; }

hs_vpn_up() {
  hs_uses_vpn || return 0
  [ -n "$HS_VPN_STATUS_CMD" ] || return 1
  eval "$HS_VPN_STATUS_CMD" >/dev/null 2>&1
}

# A dropped tunnel kills the TCP under the master but can leave the socket file behind.
hs_clean_stale() {
  hs_master_up && return 0
  hs_ssh -O exit "$HS_HOST" >/dev/null 2>&1
  local path
  path=$(hs_ssh -G "$HS_HOST" 2>/dev/null | awk '/^controlpath /{print $2}')
  [ -n "${path:-}" ] && [ -S "$path" ] && { hs_note "removing stale socket $path"; rm -f "$path"; }
  return 0
}

# Answer ssh's prompt from a PROGRAM, not a TTY — this is what lets a shell with no
# controlling terminal (an agent, a cron job) authenticate at all.
#
# The helper is SINGLE-SHOT on purpose: if it kept answering, a stale code would make ssh
# re-invoke it in a loop and the process would hang for minutes. Printing once and
# destroying the file turns that into a clean fast failure.
hs_write_askpass() {
  local code_file="$1" askpass_file="$2"
  cat > "$askpass_file" <<EOF
#!/bin/sh
[ -f "$code_file" ] || exit 1
cat "$code_file"
rm -f "$code_file"
EOF
  chmod 700 "$askpass_file"
}

# Never hand ssh a code that is about to expire — connect latency can outlive it.
hs_fresh_code() {
  local left
  left=$(hs_step_left)
  if [ "$left" -lt 4 ]; then
    hs_note "code expires in ${left}s — waiting for the next step"
    sleep $((left + 1))
  fi
  hs_code
}

# Run an ssh invocation, showing its stderr and keeping a copy for classification.
HS_SSH_ERROR=""
hs_ssh_capturing() {
  local err_file rc
  err_file=$(mktemp "${TMPDIR:-/tmp}/hserr.XXXXXX") || return 2
  "$@" 2>"$err_file"; rc=$?
  HS_SSH_ERROR=$(cat "$err_file")
  [ -s "$err_file" ] && cat "$err_file" >&2
  rm -f "$err_file"
  return "$rc"
}

# Distinguish "the network or the key is wrong" from "that code was already used".
# Only the latter is worth waiting a time step to retry.
hs_error_is_fatal() {
  case "$HS_SSH_ERROR" in
    *"Could not resolve"*|*"Connection refused"*|*"No route to host"*|\
    *"Network is unreachable"*|*"Operation timed out"*|*"Connection timed out"*|\
    *"Host key verification failed"*|*"Permission denied (publickey)"*) return 0 ;;
    *) return 1 ;;
  esac
}

hs_open_master_plain() {
  hs_ssh_capturing hs_ssh -f -N -M -o ConnectTimeout="$HS_CONNECT_TIMEOUT" "$HS_HOST"
  hs_master_up
}

hs_open_master_totp() {
  local code code_file askpass_file
  code=$(hs_fresh_code) && [ -n "$code" ] || return 2
  # mktemp creates both files 0600; the askpass helper is then chmod 700. Perms never
  # widen, so no umask is set here — changing it would leak into the caller's process.
  code_file=$(mktemp "${TMPDIR:-/tmp}/hscode.XXXXXX") || return 2
  askpass_file=$(mktemp "${TMPDIR:-/tmp}/hsask.XXXXXX") || { rm -f "$code_file"; return 2; }
  printf '%s\n' "$code" > "$code_file"
  unset code
  hs_write_askpass "$code_file" "$askpass_file"
  SSH_ASKPASS="$askpass_file" SSH_ASKPASS_REQUIRE=force \
    hs_ssh_capturing hs_ssh -f -N -M -o NumberOfPasswordPrompts=1 \
      -o ConnectTimeout="$HS_CONNECT_TIMEOUT" "$HS_HOST"
  rm -f "$askpass_file" "$code_file"
  hs_master_up
}

hs_try_open() {
  if [ "$HS_TOTP_BACKEND" = none ] && [ -z "${HS_OTP:-}" ]; then
    hs_open_master_plain
  else
    hs_open_master_totp
  fi
}

hs_vpn_connect() {
  hs_uses_vpn || return 0
  hs_vpn_up && return 0
  hs_note "bringing the VPN up..."
  eval "$HS_VPN_UP_CMD" >&2 || hs_die "VPN connect failed"
}

# Retry on the usual failure: the code was already consumed inside this time step.
hs_open_with_retries() {
  local attempt left
  for attempt in $(seq 1 "$HS_AUTH_ATTEMPTS"); do
    hs_try_open && { hs_note "master UP — ssh/scp/rsync/sbatch now run with no further codes"; return 0; }
    hs_error_is_fatal && hs_die "ssh could not connect (see the error above) — retrying would not help"
    [ -n "${HS_OTP:-}" ] && hs_die "the supplied HS_OTP was rejected (stale or already used)"
    [ "$attempt" = "$HS_AUTH_ATTEMPTS" ] && break
    left=$(hs_step_left)
    hs_note "auth failed (attempt $attempt) — waiting ${left}s for a fresh code"
    sleep $((left + 1))
  done
  hs_die "could not open the master. Check: VPN up? seed correct ('hpc-session code')? enrolled?"
}

hs_open_session() {
  hs_require_host
  mkdir -p "$HS_CONTROL_DIR" && chmod 700 "$HS_CONTROL_DIR"
  hs_clean_stale
  hs_master_up && { hs_note "master already up"; return 0; }
  # Verify a code can be PRODUCED before raising the tunnel — not that it will be
  # accepted, which cannot be tested from here: under a full tunnel the login node is
  # usually unreachable until the tunnel is up. Catching the common failure early is still
  # worth it, because that tunnel monopolises the link, and failing after raising it would
  # strand any other remote access for no reason.
  if [ "$HS_TOTP_BACKEND" != none ] && ! hs_have_seed; then
    hs_die "cannot produce a TOTP code: $(hs_seed_hint)"
  fi
  hs_vpn_connect
  hs_open_with_retries
}

hs_close_session() {
  hs_require_host
  hs_ssh -O exit "$HS_HOST" >/dev/null 2>&1 && hs_note "master closed" || hs_note "no master to close"
  if hs_uses_vpn && hs_vpn_up && [ -n "$HS_VPN_DOWN_CMD" ]; then
    eval "$HS_VPN_DOWN_CMD" >/dev/null 2>&1 && hs_note "VPN disconnected (link freed)"
  fi
  return 0
}

hs_ensure_open() { hs_master_up || hs_open_session || exit 1; }

# Run a command ON THE CLUSTER. BatchMode means a dead master fails fast instead of
# hanging on a prompt nothing can answer.
hs_run() {
  hs_ensure_open
  hs_ssh -o BatchMode=yes "$HS_HOST" "$@"
}

# Run one of THIS TOOL's OWN command strings on the cluster, through an explicit `sh`.
#
# `ssh host "cmd"` hands cmd to the account's LOGIN shell, and csh/tcsh have no `2>`
# operator: they read the `2` as an argument and `>/dev/null` as an ordinary stdout
# redirection. A remote string written in POSIX sh therefore did something else entirely on
# a csh account — `squeue … 2>/dev/null` came back empty and non-zero, which `watch` read as
# a finished job and `fetch` as an empty workdir.
#
# The command travels on STDIN, not in the argument list, so no shell tokenises it except
# the `sh` that runs it. That leaves no quoting scheme to get right — and none that would
# have to be right under sh and csh at once. Remote stdin is consumed as a result; none of
# the tool's own remote commands read it.
#
# `hs_run` stays a raw pass-through: `hpc-session run` is the user's own command line, and
# it belongs to the login shell they chose.
hs_run_sh() {
  # Open BEFORE the pipe. hs_run would open too, but from inside it — and raising the VPN
  # runs an arbitrary user command (eval "$HS_VPN_UP_CMD") that is entitled to read stdin.
  # It would read our command off it, and the remote sh would run whatever was left.
  hs_ensure_open
  printf '%s\n' "$*" | hs_run "exec sh -s"
}

# Run a LOCAL command with the multiplexed ssh exported, for tools that shell out to ssh
# themselves. This is the distinction `run` alone cannot express: `run rsync local_file
# host:/path` would look for local_file ON THE CLUSTER.
#
# Only tools that read RSYNC_RSH or GIT_SSH_COMMAND, which is to say rsync and git.
# sshfs was listed here and honours neither — it takes its transport from `-o ssh_command=`
# — so `hpc-session local sshfs ...` opened a second, unmultiplexed connection, which under
# TOTP means a second authentication: the exact thing this tool exists to avoid. See
# README for the invocation that does share the master.
hs_local() {
  hs_ensure_open
  RSYNC_RSH="ssh $(hs_ssh_opts)" GIT_SSH_COMMAND="ssh $(hs_ssh_opts)" "$@"
}

# shellcheck disable=SC2046  # word splitting of the option list is intended
hs_push() {
  hs_ensure_open
  scp $(hs_ssh_opts) -- "$1" "$HS_HOST:$2"
}

# shellcheck disable=SC2046  # word splitting of the option list is intended
hs_pull() {
  hs_ensure_open
  scp $(hs_ssh_opts) -- "$HS_HOST:$1" "$2"
}

hs_status() {
  hs_master_up && echo "master:  UP" || echo "master:  down"
  if hs_uses_vpn; then
    hs_vpn_up && echo "vpn:     connected" || echo "vpn:     disconnected"
  else
    echo "vpn:     not configured"
  fi
  if [ "$HS_TOTP_BACKEND" = none ]; then
    echo "totp:    disabled (key-only login)"
  else
    hs_have_seed && echo "totp:    seed present ($HS_TOTP_BACKEND)" \
                 || echo "totp:    NO CODE AVAILABLE — $(hs_seed_hint)"
  fi
  echo "profile: $HS_PROFILE -> $HS_HOST"
}
