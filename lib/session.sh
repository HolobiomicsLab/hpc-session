# The session itself: optional VPN, one authenticated SSH master, and the exec wrappers.
#
# Why a master socket is not optional under TOTP 2FA: pam_google_authenticator refuses to
# reuse a code, so two fresh logins inside one time step see the second REJECTED. One
# master authenticates once; every later ssh/scp/rsync multiplexes over it and does not
# authenticate at all.

# Temporary files this process creates, and a trap that removes them however it ends.
#
# hs_open_master_totp writes a LIVE TOTP code to a file for the askpass helper to read.
# Falling through to `rm -f` covered the normal path only: a SIGINT between writing the
# file and ssh consuming it — an impatient Ctrl-C, a CI timeout, an agent's supervisor —
# left an unused, still-valid code on disk with nothing left to delete it. The window is
# HS_CONNECT_TIMEOUT plus the retry sleeps. SECURITY.md says the code is read once and
# then deleted; this is what makes that true.
#
# An array, not a string: a TMPDIR containing a space would otherwise word-split into
# `rm -f` and take the wrong paths with it.
HS_TEMP_FILES=()
hs_temp_track() { HS_TEMP_FILES+=("$1"); }

hs_temp_clean() {
  [ ${#HS_TEMP_FILES[@]} -gt 0 ] && rm -f "${HS_TEMP_FILES[@]}"
  HS_TEMP_FILES=()
  return 0
}

# Remove one file and forget it, so a long-lived session does not accumulate a list of
# paths it has already deleted.
hs_temp_drop() {
  rm -f "$1"
  local kept=() f
  for f in ${HS_TEMP_FILES[@]+"${HS_TEMP_FILES[@]}"}; do
    [ "$f" = "$1" ] || kept+=("$f")
  done
  HS_TEMP_FILES=(${kept[@]+"${kept[@]}"})
}

# EXIT is what actually removes the files: bash runs it even when the shell is ending
# because of a signal. The three signal traps are still worth writing — they make the exit
# status the conventional 128+signal instead of the EXIT trap's own, and they state the
# intent rather than resting on that behaviour of bash. What matters is that SOME trap
# exists; before this, none did.
#
# The open lock (see "one open at a time" below) leaves with the temp files, and for the
# same reason: an opener stopped while its VPN was coming up — the caller's timeout, a
# Ctrl-C — must not leave the next opener waiting on a lock nobody will release.
hs_cleanup() { hs_open_lock_release; hs_temp_clean; }
trap 'hs_cleanup' EXIT
trap 'hs_cleanup; exit 130' INT
trap 'hs_cleanup; exit 143' TERM
trap 'hs_cleanup; exit 129' HUP

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
  hs_temp_track "$err_file"
  "$@" 2>"$err_file"; rc=$?
  HS_SSH_ERROR=$(cat "$err_file")
  [ -s "$err_file" ] && cat "$err_file" >&2
  hs_temp_drop "$err_file"
  return "$rc"
}

# Distinguish "the network or the key is wrong" from "that code was already used".
# Only the latter is worth waiting a time step to retry.
hs_error_is_fatal() {
  case "$HS_SSH_ERROR" in
    *"Could not resolve"*|*"Connection refused"*|*"No route to host"*|\
    *"Network is unreachable"*|*"Operation timed out"*|*"Connection timed out"*|\
    *"Host key verification failed"*|*"Too many authentication failures"*) return 0 ;;
    # sshd names the methods that were left unsatisfied. A bare "(publickey)" only appears
    # where keyboard-interactive is not in the list at all — so on the very sites this tool
    # is built for, running AuthenticationMethods publickey,keyboard-interactive, a
    # genuinely bad key produced "(publickey,keyboard-interactive)" and was retried three
    # times over ~90s. Matching the open parenthesis catches both, and still leaves
    # "(keyboard-interactive)" alone: that one IS the consumed-code case worth retrying.
    *"Permission denied (publickey"*) return 0 ;;
    *) return 1 ;;
  esac
}

hs_open_master_plain() {
  hs_ssh_capturing hs_ssh -f -N -M -o ConnectTimeout="$HS_CONNECT_TIMEOUT" "$HS_HOST"
  hs_master_up
}

# Status 2 means the failure was LOCAL and ssh was never run. HS_SSH_ERROR is cleared with
# it: leaving the previous attempt's text there had hs_error_is_fatal judging a stale
# string, so the retry loop sat out three full time steps waiting for a code that was never
# going to be generated.
hs_open_master_totp() {
  local code code_file askpass_file
  HS_SSH_ERROR=""
  code=$(hs_fresh_code) && [ -n "$code" ] || return 2
  # mktemp creates both files 0600; the askpass helper is then chmod 700. Perms never
  # widen, so no umask is set here — changing it would leak into the caller's process.
  code_file=$(mktemp "${TMPDIR:-/tmp}/hscode.XXXXXX") || return 2
  hs_temp_track "$code_file"
  askpass_file=$(mktemp "${TMPDIR:-/tmp}/hsask.XXXXXX") || { hs_temp_drop "$code_file"; return 2; }
  hs_temp_track "$askpass_file"
  printf '%s\n' "$code" > "$code_file"
  unset code
  hs_write_askpass "$code_file" "$askpass_file"
  SSH_ASKPASS="$askpass_file" SSH_ASKPASS_REQUIRE=force \
    hs_ssh_capturing hs_ssh -f -N -M -o NumberOfPasswordPrompts=1 \
      -o ConnectTimeout="$HS_CONNECT_TIMEOUT" "$HS_HOST"
  hs_temp_drop "$askpass_file"; hs_temp_drop "$code_file"
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
  # Status-only: the profile can tell whether the tunnel is up but not how to raise it,
  # which is the documented shape for a VPN needing a human (a push, a smartcard). Saying
  # so beats `eval ""` succeeding and letting the open fail later as a name-resolution error.
  [ -n "$HS_VPN_UP_CMD" ] || hs_die "the VPN is not up and HS_VPN_UP_CMD is empty — bring it up yourself, then run this again"
  hs_note "bringing the VPN up..."
  eval "$HS_VPN_UP_CMD" >&2 || hs_die "VPN connect failed"
}

# Retry on the usual failure: the code was already consumed inside this time step.
hs_open_with_retries() {
  local attempt left
  for attempt in $(seq 1 "$HS_AUTH_ATTEMPTS"); do
    hs_try_open; local rc=$?
    [ "$rc" = 0 ] && { hs_note "master UP — ssh/scp/rsync/sbatch now run with no further codes"; return 0; }
    # 2 is a local failure — no seed, no code, no temp file — and waiting out a time step
    # changes none of those.
    [ "$rc" = 2 ] && hs_die "could not produce a code to authenticate with: $(hs_seed_hint)"
    hs_error_is_fatal && hs_die "ssh could not connect (see the error above) — retrying would not help"
    [ -n "${HS_OTP:-}" ] && hs_die "the supplied HS_OTP was rejected (stale or already used)"
    [ "$attempt" = "$HS_AUTH_ATTEMPTS" ] && break
    left=$(hs_step_left)
    hs_note "auth failed (attempt $attempt) — waiting ${left}s for a fresh code"
    sleep $((left + 1))
  done
  hs_die "could not open the master. Check: VPN up? seed correct ('hpc-session code')? enrolled?"
}

# --- who holds the link ---------------------------------------------------------------
#
# One master and one tunnel serve every process on the machine that uses the profile, and
# `close` used to tear both down unconditionally. Two sessions sharing the link — two
# agents, a wrapper script and a shell — therefore took each other's connection away: the
# other side's next command failed on a dead socket, or on a tunnel that was no longer up,
# and under 2FA the reopen cost a code it could not always produce. A holder file per
# opener fixes that: `open` (and the implicit open under run, push, pull and local) records
# who holds the link, `close` removes its own record and tears the link down only when no
# live holder remains. `status` lists them.
#
# A holder is named by HS_LEASE when set, otherwise by the pid of the process that invoked
# the tool — a wrapper script, an interactive shell. The file records that pid and the
# time. A pid holder is live while its process is; a named holder is live until it closes,
# because its pid is usually a transient shell (an agent runs each command in a new one).
# Both expire HS_LEASE_TTL seconds after their last open — the backstop against a session
# that ended without closing — and every open refreshes the stamp, so the expiry is an idle
# time, not a lifetime. HS_CLOSE_FORCE=1 tears down regardless and clears every holder.
hs_lease_name() {
  local name="${HS_LEASE:-$PPID}"
  case "$name" in
    ""|*[!A-Za-z0-9._-]*) hs_die "HS_LEASE must be made of letters, digits, '.', '_' and '-' (got '$name')" ;;
  esac
  printf '%s' "$name"
}

hs_pid_alive() { [ "${1:-0}" -gt 1 ] 2>/dev/null && kill -0 "$1" 2>/dev/null; }

hs_lease_take() {
  local dir="$HS_CONTROL_DIR/holders" name named=no
  name=$(hs_lease_name) || exit 1
  [ -n "${HS_LEASE:-}" ] && named=yes
  mkdir -p "$dir" || hs_die "cannot create $dir"
  printf 'pid=%s\nnamed=%s\nsince=%s\n' "$PPID" "$named" "$(date +%s)" > "$dir/$name" \
    || hs_die "cannot record the holder $dir/$name"
}

hs_lease_drop() {
  local name
  name=$(hs_lease_name) || exit 1
  rm -f "$HS_CONTROL_DIR/holders/$name"
}

# Print the live holders, one per line, and remove the rest.
hs_lease_live() {
  local dir="$HS_CONTROL_DIR/holders" f key value pid named since now
  [ -d "$dir" ] || return 0
  now=$(date +%s)
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    pid='' named='' since=''
    while IFS='=' read -r key value; do
      case "$key" in pid) pid=$value ;; named) named=$value ;; since) since=$value ;; esac
    done < "$f"
    if [ $((now - ${since:-0})) -lt "$HS_LEASE_TTL" ] && { [ "$named" = yes ] || hs_pid_alive "$pid"; }; then
      printf '%s\n' "${f##*/}"
    else
      rm -f "$f"
    fi
  done
}

# --- one open at a time ------------------------------------------------------------------
#
# The holders above coordinate sessions once the link is UP. Bringing it up was not
# coordinated at all: two sessions that ran `open` half a minute apart from a VPN-down
# state each found no master and no tunnel, and each ran HS_VPN_UP_CMD. One VPN client
# serves the whole machine, so the second connect met the first in flight — it stalled at
# the gateway until its caller's timeout, or was told the client was held by something
# else, or dropped the half-raised tunnel to "reconnect" — and neither session got a link.
# Between an open's start and its master coming up there is no holder to see; that is the
# window the holders cannot close.
#
# A lock under the control directory does. `open` takes it before looking for a master and
# keeps it until its holder is recorded. A second opener waits, says whom it waits for, and
# then finds the master up and joins it as a holder — one tunnel, one authentication, two
# sessions, which is what the holders were built for. The wait is bounded by
# HS_OPEN_LOCK_WAIT seconds; past it the opener fails, naming the pid that holds the lock.
# A lock is stale, and taken over, when its owner's process is gone or when it is older
# than HS_OPEN_LOCK_STALE seconds — the backstop against a VPN connect that hangs while its
# process lives on. `close` keeps the link while an open is in progress: the opener has no
# holder yet, and the tunnel it is raising is about to be its own.
#
# The lock is a SYMLINK, not a directory. `ln -s` either creates it or fails because it
# exists, as atomically as mkdir, but its target is written in the same step — so a reader
# never meets a lock whose owner is not recorded yet, which a directory plus an owner file
# would allow. The target IS the record, `pid=N since=S holder=H`, and readlink returns it
# without opening anything. The pid is this process, $$, not the holder's PPID: it is the
# process that will release the lock, and the one a waiter may check for life.
HS_OPEN_LOCK_HELD=""

hs_open_lock_path() { printf '%s/open.lock' "$HS_CONTROL_DIR"; }

# The lock's record as three words — pid, since, holder — or nothing when there is no lock.
# A target that does not parse yields pid 0, which no process has, so a stray symlink at
# the path is cleared like a dead owner's instead of blocking every open.
hs_open_lock_record() {
  local target pid since holder
  target=$(readlink "$(hs_open_lock_path)" 2>/dev/null) || return 0
  pid=${target#pid=}; pid=${pid%% *}
  since=${target#*since=}; since=${since%% *}
  holder=${target#*holder=}
  case "$pid"   in ''|*[!0-9]*) pid=0 ;; esac
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  printf '%s %s %s\n' "$pid" "$since" "${holder:-?}"
}

# The pid of a live, unexpired open in progress, or nothing (and status 1).
hs_open_in_progress() {
  local pid since holder
  read -r pid since holder <<< "$(hs_open_lock_record)"
  [ -n "${pid:-}" ] && hs_pid_alive "$pid" \
    && [ $(( $(date +%s) - since )) -lt "$HS_OPEN_LOCK_STALE" ] || return 1
  printf '%s\n' "$pid"
}

hs_open_lock_acquire() {
  local lock holder err pid since owner age waited=0 told=no
  lock=$(hs_open_lock_path)
  holder=$(hs_lease_name) || exit 1
  while :; do
    if err=$(ln -s "pid=$$ since=$(date +%s) holder=$holder" "$lock" 2>&1); then
      HS_OPEN_LOCK_HELD="$lock"
      # A subshell starts with none of the parent's traps, and the tool's own implicit opens
      # run in one — `answer=$(hs_run_sh ...)` in watch, submit and fetch. An hs_die in
      # there ends the subshell without the release above, and leaves the lock recorded
      # under $$, the PARENT's pid, which is alive: the next opener, this process included,
      # would wait the whole of HS_OPEN_LOCK_WAIT for it. So the subshell arms its own.
      [ "${BASH_SUBSHELL:-0}" -gt 0 ] && trap 'hs_open_lock_release' EXIT
      [ "$told" = yes ] && hs_note "the other open finished after ${waited}s"
      return 0
    fi
    read -r pid since owner <<< "$(hs_open_lock_record)"
    if [ -z "${pid:-}" ]; then
      case "$err" in
        # It existed for the ln and was gone for the readlink: its owner just released it.
        # Anything that is not a symlink at that path is not a lock this tool made.
        *"File exists"*) [ -e "$lock" ] && hs_die "$lock is in the way and is not an open lock — move it aside"; continue ;;
        *) hs_die "cannot take the open lock $lock: $err" ;;
      esac
    fi
    age=$(( $(date +%s) - since ))
    if ! hs_pid_alive "$pid"; then
      hs_note "clearing an open lock left by pid $pid, which is gone"
      rm -f "$lock"; continue
    fi
    if [ "$age" -ge "$HS_OPEN_LOCK_STALE" ]; then
      hs_note "clearing an open lock pid $pid has held for ${age}s — past HS_OPEN_LOCK_STALE ($HS_OPEN_LOCK_STALE)"
      rm -f "$lock"; continue
    fi
    [ "$waited" -lt "$HS_OPEN_LOCK_WAIT" ] \
      || hs_die "another session's open (pid $pid, holder $owner) has held $lock for ${age}s and the ${HS_OPEN_LOCK_WAIT}s wait (HS_OPEN_LOCK_WAIT) is over — if that process is hung, stop it; the lock then clears itself"
    if [ "$told" = no ]; then
      hs_note "waiting for another session's open (pid $pid) — holder $owner, ${age}s in; up to ${HS_OPEN_LOCK_WAIT}s (HS_OPEN_LOCK_WAIT), then joining the link it raises"
      told=yes
    fi
    sleep 1; waited=$((waited + 1))
  done
}

# Only this process's own record is removed: a lock taken over as stale and since re-taken
# by another opener is that opener's, not ours.
hs_open_lock_release() {
  [ -n "$HS_OPEN_LOCK_HELD" ] || return 0
  case "$(readlink "$HS_OPEN_LOCK_HELD" 2>/dev/null)" in
    "pid=$$ "*) rm -f "$HS_OPEN_LOCK_HELD" ;;
  esac
  HS_OPEN_LOCK_HELD=""
  return 0
}

hs_open_session() {
  hs_require_host
  # Not swallowed: `set -uo pipefail` has no -e, so a failure here used to let the open
  # proceed and simply never multiplex — which looks like a slow cluster, not a broken setup.
  mkdir -p "$HS_CONTROL_DIR" && chmod 700 "$HS_CONTROL_DIR" \
    || hs_die "cannot create the control directory $HS_CONTROL_DIR — without it nothing multiplexes"
  hs_open_lock_acquire
  hs_open_locked; local rc=$?
  hs_open_lock_release
  return "$rc"
}

# Everything between looking for a master and recording a holder, under the open lock. The
# master check is inside it on purpose: a waiter that had checked before waiting would
# raise a second master over the one the first opener just brought up — and spend a code.
hs_open_locked() {
  hs_clean_stale
  hs_master_up && { hs_lease_take; hs_note "master already up — joined it as holder $(hs_lease_name)"; return 0; }
  # Verify a code can be PRODUCED before raising the tunnel — not that it will be
  # accepted, which cannot be tested from here: under a full tunnel the login node is
  # usually unreachable until the tunnel is up. Catching the common failure early is still
  # worth it, because that tunnel monopolises the link, and failing after raising it would
  # strand any other remote access for no reason.
  if [ "$HS_TOTP_BACKEND" != none ] && ! hs_have_seed; then
    hs_die "cannot produce a TOTP code: $(hs_seed_hint)"
  fi
  hs_vpn_connect
  hs_open_with_retries && hs_lease_take
}

hs_close_session() {
  hs_require_host
  local others opener
  hs_lease_drop
  others=$(hs_lease_live | tr '\n' ' ')
  if [ -n "$others" ] && [ "$HS_CLOSE_FORCE" != 1 ]; then
    hs_note "link kept — still held by: ${others}(HS_CLOSE_FORCE=1 closes it anyway)"
    return 0
  fi
  # An open in progress has no holder yet: it is between raising the tunnel and recording
  # one, and taking the tunnel down under it is the collision the open lock exists to end.
  opener=$(hs_open_in_progress)
  if [ -n "$opener" ] && [ "$HS_CLOSE_FORCE" != 1 ]; then
    hs_note "link kept — another session's open is in progress (pid $opener; HS_CLOSE_FORCE=1 closes it anyway)"
    return 0
  fi
  [ "$HS_CLOSE_FORCE" = 1 ] && rm -rf "$HS_CONTROL_DIR/holders"
  hs_ssh -O exit "$HS_HOST" >/dev/null 2>&1 && hs_note "master closed" || hs_note "no master to close"
  if hs_uses_vpn && hs_vpn_up && [ -n "$HS_VPN_DOWN_CMD" ]; then
    eval "$HS_VPN_DOWN_CMD" >/dev/null 2>&1 && hs_note "VPN disconnected (link freed)"
  fi
  return 0
}

# An implicit open joins the link as a holder too: a session that only ever runs commands
# over a master someone else raised is still a user of it.
hs_ensure_open() {
  if hs_master_up; then hs_lease_take; else hs_open_session || exit 1; fi
}

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
  local holders opener
  hs_master_up && echo "master:  UP" || echo "master:  down"
  holders=$(hs_lease_live | tr '\n' ' ')
  echo "holders: ${holders:-none}"
  opener=$(hs_open_in_progress) && echo "open:    in progress (pid $opener)"
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
