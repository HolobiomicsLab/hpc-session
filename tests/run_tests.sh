#!/usr/bin/env bash
# Offline tests. No cluster, no VPN, no network: what cannot be run for real is stubbed —
# ssh, scp, squeue, sacct, security — and the assertion is on what the tool ASKED them to
# do. Runs on bash 3.2, the floor CI holds the tool to.
#
#   tests/run_tests.sh

set -uo pipefail

HS_ROOT=$(cd "$(dirname "$0")/.." && pwd)
export HS_CONFIG_DIR="$HS_ROOT/tests/tmp-config"
HS_PROFILE="test"

. "$HS_ROOT/lib/config.sh"
. "$HS_ROOT/lib/totp.sh"
. "$HS_ROOT/lib/session.sh"
. "$HS_ROOT/lib/slurm.sh"

PASSED=0
FAILED=0

# The real hs_run and friends are not usable offline — they reach hs_require_host and would
# abort the suite — so the stateful blocks below stub them. Leaving a stub behind is worse
# than either: a later test would silently exercise it and pass on nothing. Capture the real
# definitions once, and put them back after every block that replaces one.
HS_REAL_DEFS=$(declare -f hs_run hs_run_sh hs_push hs_pull hs_ensure_open)
restore_lib() { eval "$HS_REAL_DEFS"; }

# hs_run_sh sends the command on STDIN rather than in argv (see lib/session.sh), so a stub
# standing in for the cluster reads it from there.
remote_cmd() { cat; }

check() {  # description, expected, actual
  if [ "$2" = "$3" ]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
  fi
}

# `check` compares strings, so a file-existence assertion has to become one. A helper
# rather than an inline `$([ -f x ]; echo $?)`, because that idiom has a real trap in it:
# one more command between the test and the `echo` and it silently reports the wrong
# status. shellcheck flags it (SC2319) for exactly that reason.
status_of() { if "$@"; then echo 0; else echo 1; fi; }

check_contains() {  # description, needle, haystack
  case "$3" in
    *"$2"*) PASSED=$((PASSED + 1)) ;;
    *) FAILED=$((FAILED + 1)); printf 'FAIL  %s\n      %s not found in: %s\n' "$1" "$2" "$3" ;;
  esac
}

# --- TOTP: the RFC 6238 SHA1 test vectors -------------------------------------------
# Seed is the ASCII string 12345678901234567890 in base32.
RFC_SEED=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
totp_at() {  # unix time, digits
  HS_TOTP_NOW="$1" HS_TOTP_DIGITS="$2" HS_TOTP_PERIOD=30 HS_TOTP_ALGO=sha1 \
    printf '%s' "$RFC_SEED" | HS_TOTP_NOW="$1" HS_TOTP_DIGITS="$2" HS_TOTP_PERIOD=30 \
    HS_TOTP_ALGO=sha1 python3 -c "$HS_TOTP_PY"
}

check "rfc6238 t=59 8 digits"          94287082 "$(totp_at 59 8)"
check "rfc6238 t=59 6 digits"          287082   "$(totp_at 59 6)"
check "rfc6238 t=1111111109 8 digits"  07081804 "$(totp_at 1111111109 8)"
check "rfc6238 t=1234567890 6 digits"  005924   "$(totp_at 1234567890 6)"
check "rfc6238 t=2000000000 6 digits"  279037   "$(totp_at 2000000000 6)"
check "code is zero padded"            6        "$(printf '%s' "$(totp_at 1234567890 6)" | wc -c | tr -d ' ')"

invalid=$(printf '%s' 'not-base32-!!' | HS_TOTP_DIGITS=6 HS_TOTP_PERIOD=30 HS_TOTP_ALGO=sha1 \
  python3 -c "$HS_TOTP_PY" 2>&1)
check_contains "invalid seed is rejected" "not valid base32" "$invalid"

# --- defaults and profile paths ------------------------------------------------------
hs_apply_defaults
check "default totp backend"   none                     "$HS_TOTP_BACKEND"
check "default totp period"    30                       "$HS_TOTP_PERIOD"
check "profile path"           "$HS_CONFIG_DIR/x.conf"  "$(hs_profile_path x)"

HS_CONTROL_PERSIST=2h
check_contains "ssh opts carry ControlPersist" "ControlPersist=2h" "$(hs_ssh_opts)"
check_contains "ssh opts use the %C hash"      "/%C"               "$(hs_ssh_opts)"

HS_VPN_UP_CMD=""
hs_uses_vpn && check "no vpn configured" yes no || PASSED=$((PASSED + 1))
HS_VPN_UP_CMD="true"
hs_uses_vpn && PASSED=$((PASSED + 1)) || check "vpn configured" yes no

# --- error classification: only a consumed code is worth waiting a time step for -------
fatal_verdict() { HS_SSH_ERROR="$1"; hs_error_is_fatal && echo fatal || echo retry; }

check "dns failure is fatal" fatal \
  "$(fatal_verdict 'ssh: Could not resolve hostname login.example.edu')"
check "refused connection is fatal" fatal "$(fatal_verdict 'ssh: connect: Connection refused')"
check "rejected key is fatal" fatal "$(fatal_verdict 'Permission denied (publickey).')"
check "bad verification code is retried" retry \
  "$(fatal_verdict 'Permission denied (keyboard-interactive).')"
check "silence is retried" retry "$(fatal_verdict '')"

# --- SLURM helpers -------------------------------------------------------------------
check "job id parsed" 12345 "$(printf 'Submitted batch job 12345\n' | hs_parse_job_id)"
check "job id ignores noise" 777 \
  "$(printf 'warning: partition busy\nSubmitted batch job 777\n' | hs_parse_job_id)"
check "job id absent" "" "$(printf 'sbatch: error: invalid account\n' | hs_parse_job_id)"

HS_REMOTE_WORKDIR="/scratch/me/jobs"
check "remote path" "/scratch/me/jobs/job.slurm" \
  "$(hs_remote_path /scratch/me/jobs ./local/dir/job.slurm)"

check "empty sbatch line dropped" "#SBATCH --time=1:00" \
  "$(printf '#SBATCH --account=\n#SBATCH --time=1:00\n' | hs_strip_empty_sbatch)"
check "filled sbatch line kept" "#SBATCH --account=abc" \
  "$(printf '#SBATCH --account=abc\n' | hs_strip_empty_sbatch)"

# --- rendering -----------------------------------------------------------------------
HS_SLURM_ACCOUNT=myacct
HS_SLURM_PARTITION=""
HS_SLURM_TIME=02:00:00
HS_SLURM_CPUS=8
HS_SLURM_MEM=16G
HS_SLURM_NODES=1
rendered=$(hs_render "$HS_ROOT/templates/job.slurm.tmpl" JOB_NAME=demo PAYLOAD='echo hi' 2>/dev/null)

check_contains "account substituted"    "--account=myacct"   "$rendered"
check_contains "job name substituted"   "--job-name=demo"    "$rendered"
check_contains "cpus substituted"       "--cpus-per-task=8"  "$rendered"
check_contains "payload substituted"    "echo hi"            "$rendered"
check_contains "workdir substituted"    "/scratch/me/jobs"   "$rendered"
case "$rendered" in
  *"--partition="*) FAILED=$((FAILED + 1)); echo "FAIL  empty partition line should be dropped" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac

# Regression: a value containing a space, a pipe or an ampersand must survive intact —
# all three are sed syntax on the right-hand side of a substitution.
piped=$(hs_render "$HS_ROOT/templates/job.slurm.tmpl" JOB_NAME=demo \
  PAYLOAD='cat in.txt | sort > out.txt && echo done' 2>/dev/null)
check_contains "pipe in payload survives" "cat in.txt | sort > out.txt && echo done" "$piped"

warning=$(hs_render "$HS_ROOT/templates/job.slurm.tmpl" JOB_NAME=demo 2>&1 >/dev/null)
check_contains "unresolved placeholder reported" 'PAYLOAD' "$warning"

# --- regressions from the 2026-08 audit ----------------------------------------------

# Every document promises environment > profile > defaults. Sourcing the profile made it
# the last writer, so `HS_HOST=other hpc-session ...` was silently discarded — and since
# `init` copies config.example, which assigns every key, that covered the whole surface.
mkdir -p "$HS_CONFIG_DIR"
cat > "$HS_CONFIG_DIR/precedence.conf" <<'PROFILE'
HS_HOST="from-profile"
HS_SLURM_PARTITION="from-profile"
HS_SLURM_MEM="8G"
HS_VPN_UP_CMD="from-profile"
PROFILE
precedence_probe() {  # exported value for HS_HOST ("-" to leave it unset), key to print
  ( export HS_PROFILE=precedence
    unset HS_SLURM_PARTITION HS_SLURM_MEM HS_HOST
    [ "$1" = - ] || export HS_HOST="$1"
    . "$HS_ROOT/lib/config.sh"; hs_load_profile; printf '%s' "${!2}" )
}
check "environment beats the profile"     from-env     "$(precedence_probe from-env HS_HOST)"
check "unset falls through to the profile" from-profile "$(precedence_probe - HS_HOST)"
check "profile still sets untouched keys" 8G           "$(precedence_probe from-env HS_SLURM_MEM)"
# Empty is unset, matching the `:=` defaults — an empty override must not blank the profile.
check "an empty override does not blank"  from-profile "$(precedence_probe "" HS_HOST)"

# A non-exported HS_* variable is not "the environment" — the libraries assign several at
# source time, and replaying those over the profile would break the profile instead.
unexported_probe() {
  ( export HS_PROFILE=precedence; unset HS_HOST
    HS_HOST="assigned-not-exported"
    . "$HS_ROOT/lib/config.sh"; hs_load_profile; printf '%s' "$HS_HOST" )
}
check "a non-exported value does not win" from-profile "$(unexported_probe)"

# A multi-line value must not break the replay. Filtering the text of `export -p` keeps
# only the value's first line, and the unterminated quote makes `eval` abandon every
# override after it — so one multi-line HS_VPN_UP_CMD would silently disable precedence
# for all the rest.
multiline_probe() {
  ( export HS_PROFILE=precedence
    export HS_VPN_UP_CMD='sudo vpn connect \
      --profile hpc'
    . "$HS_ROOT/lib/config.sh"; hs_load_profile 2>/dev/null; printf '%s' "$HS_VPN_UP_CMD" )
}
check_contains "a multi-line value survives the replay" "--profile hpc" "$(multiline_probe)"
rm -f "$HS_CONFIG_DIR/precedence.conf"

# scp has spoken SFTP since OpenSSH 9.0 and runs no remote shell, so the workdir must
# reach it already expanded by the cluster. It used to be passed through verbatim, so the
# shipped `/scratch/$USER/jobs` default made `submit` fail on every current client.
HS_HOST=cluster HS_REMOTE_WORKDIR='/scratch/$USER/jobs'
push_log=$(mktemp "${TMPDIR:-/tmp}/hstest.XXXXXX")
hs_ensure_open() { :; }
hs_push() { printf '%s\n' "$2" > "$push_log"; }        # record the copy destination
hs_run() {   # the CLUSTER expands $USER, and its shell startup chatters over the same stdout
  case "$(remote_cmd)" in
    *hs_workdir*) printf 'Loading module gcc/12\nhs_workdir=/scratch/realuser/jobs\n' ;;
    *sbatch*)     printf 'Submitted batch job 4711\n' ;;
    *)            return 0 ;;
  esac
}
job_id=$(hs_submit "$HS_ROOT/templates/job.slurm.tmpl" 2>/dev/null)
check "submit prints only the job id"  4711 "$job_id"
check "workdir reaches scp expanded"   "/scratch/realuser/jobs/job.slurm.tmpl" \
  "$(cat "$push_log" 2>/dev/null)"
rm -f "$push_log"
restore_lib

# `ls -1` on a matching DIRECTORY prints its contents as bare relative names, which scp
# resolves against the remote home — delivering an unrelated file as if it were job output.
run_log=$(mktemp "${TMPDIR:-/tmp}/hstest.XXXXXX")
fetch_dir=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")
hs_run() { remote_cmd > "$run_log"; }
hs_ensure_open() { :; }
hs_fetch 12345 "$fetch_dir" >/dev/null 2>&1
fetch_cmd=$(cat "$run_log" 2>/dev/null)
rm -rf "$fetch_dir" "$run_log"
restore_lib
check_contains "fetch skips directories"    "! -type d"   "$fetch_cmd"
check_contains "fetch does not descend"     "-maxdepth 1" "$fetch_cmd"

# Run it against a real filesystem, because the interesting case is the operand itself:
# find lstats it unless -H is given, so a workdir whose LAST component is a symlink
# (`ln -s /scratch/$USER/jobs ~/jobs`) is never descended and every output silently
# vanishes — reported as "nothing matching", which reads as "the job wrote nothing".
sym_root=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")
mkdir -p "$sym_root/real/out-12345.d"
: > "$sym_root/real/slurm-12345.out"
: > "$sym_root/real/out-12345.d/inner.txt"
ln -s "$sym_root/real" "$sym_root/jobs"
HS_REMOTE_WORKDIR="$sym_root/jobs"
hs_run() { [ -t 0 ] && return 99; /bin/sh; }   # runs the piped command, as the remote sh would
hs_ensure_open() { :; }
hs_pull() { :; }
sym_out=$(hs_fetch 12345 "$sym_root/dest" 2>/dev/null)
restore_lib
check_contains "fetch follows a symlinked workdir" "slurm-12345.out" "$sym_out"
case "$sym_out" in
  *inner.txt*) FAILED=$((FAILED + 1)); echo "FAIL  fetch descended into a job output directory" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac
rm -rf "$sym_root"
case "$fetch_cmd" in
  *"ls -1"*) FAILED=$((FAILED + 1)); echo "FAIL  fetch still lists directory contents" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac

# --- regressions from the 2026-07 audit ----------------------------------------------

# The `command` backend has no stored seed by design. hs_seed_read has no `command` arm,
# so routing the question through it always answered "no seed" and hs_open_session refused
# before ssh was ever tried — the documented backend could not open a session at all.
saved_backend=$HS_TOTP_BACKEND saved_cmd=${HS_TOTP_CMD:-} saved_otp=${HS_OTP:-}
unset HS_OTP
HS_TOTP_BACKEND=command HS_TOTP_CMD="echo 000000"
hs_have_seed && PASSED=$((PASSED + 1)) || check "command backend reports a usable seed" yes no
HS_TOTP_CMD=""
hs_have_seed && check "command backend with no HS_TOTP_CMD is not usable" no yes || PASSED=$((PASSED + 1))
HS_TOTP_BACKEND=none HS_TOTP_CMD=$saved_cmd
HS_OTP=123456
hs_have_seed && PASSED=$((PASSED + 1)) || check "explicit HS_OTP is always usable" yes no
unset HS_OTP
[ -n "$saved_otp" ] && HS_OTP=$saved_otp
HS_TOTP_BACKEND=$saved_backend

# `watch` read empty stdout as "the job finished". Empty stdout is also what a dead master,
# a squeue behind a module, an invalid job id and a csh login shell all produce. The answer
# must therefore carry proof that the controller was reached, and that proof must reach the
# caller through the exit status — the one channel that survives the command substitution
# `state=$(hs_job_state ...)` that hs_watch uses.
#
# Driven through a FAKE squeue on PATH and a stub that executes the piped command locally,
# so the sentinel is really emitted and really parsed rather than asserted about.
fake_bin=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")
cat > "$fake_bin/squeue" <<'SQUEUE'
#!/bin/sh
# squeue's contract for the four replies that matter. -o is honoured, so the tag under test
# comes from the format string the tool sends rather than from this stub.
fmt=; prev=
for arg in "$@"; do [ "$prev" = -o ] && fmt=$arg; prev=$arg; done
case "$FAKE_SQUEUE" in
  running) printf '%s\n' "$fmt" | sed 's/%T/RUNNING/'; exit 0 ;;
  gone)    exit 0 ;;                                     # answered: not in the queue
  invalid) echo 'slurm_load_jobs error: Invalid job id specified' >&2; exit 1 ;;
  missing) echo 'sh: squeue: command not found' >&2; exit 127 ;;
esac
SQUEUE
chmod +x "$fake_bin/squeue"
# Reads the command from stdin, as the remote sh does. The tty guard matters: if the
# transport ever regresses to passing the command in argv, nothing is piped, and a bare
# `/bin/sh` would block on the terminal — and execute whatever the developer typed. Fail
# loudly instead.
hs_run() { [ -t 0 ] && return 99; PATH="$fake_bin:$PATH" /bin/sh; }
# hs_run_sh opens the session before it pipes, so this must be neutralised too or the
# suite would reach the real ssh — and the network. restore_lib puts it back.
hs_ensure_open() { :; }
export FAKE_SQUEUE                             # the fake squeue is a separate process

FAKE_SQUEUE=running; state=$(hs_job_state 12345); rc=$?
check "a queued job reports its state"         RUNNING "$state"
check "a queued job reports status 0"          0       "$rc"
FAKE_SQUEUE=gone;    state=$(hs_job_state 12345); rc=$?
check "an answered absence is status 1"        "|1"    "$state|$rc"
FAKE_SQUEUE=invalid; state=$(hs_job_state 12345); rc=$?
check "an invalid job id is not a completion"  2       "$rc"
check_contains "and its diagnostic comes back" "Invalid job id" "$state"
FAKE_SQUEUE=missing; state=$(hs_job_state 12345); rc=$?
check "an absent squeue is not a completion"   2       "$rc"
hs_run() { return 255; }                       # master gone: no sentinel reaches us at all
state=$(hs_job_state 12345); rc=$?
check "a dead master is not a completion"      2       "$rc"

# Login-shell independence. csh and tcsh have no `2>` operator — they read the `2` as an
# argument and `>/dev/null` as an ordinary stdout redirection — so the tool's own remote
# strings must not be handed to the account's login shell. Skipped where csh is absent.
if command -v csh >/dev/null 2>&1; then
  hs_run() { [ -t 0 ] && return 99; PATH="$fake_bin:$PATH" csh -c "$*"; }
  FAKE_SQUEUE=running; state=$(hs_job_state 12345); rc=$?
  check "a csh login shell still answers"      "RUNNING|0" "$state|$rc"
fi
restore_lib
rm -rf "$fake_bin"

# `watch` itself, which no test used to call — and it is the function the fix changes. Run
# in a subshell because it may hs_die, and with a zero interval so the loop does not sleep.
watch_tick=$(mktemp "${TMPDIR:-/tmp}/hstest.XXXXXX")
watch_replies=$(mktemp "${TMPDIR:-/tmp}/hstest.XXXXXX")
watch_final=""
hs_job_state() {          # serve one scripted `rc:stdout` per poll, then the last forever
  local n reply
  n=$(cat "$watch_tick"); echo $((n + 1)) > "$watch_tick"
  # A watch that believes a broken answer polls forever at interval 0. Cap it, so a
  # regression here fails the assertions below instead of hanging the suite.
  [ "$n" -le 20 ] || return 1
  reply=$(sed -n "${n}p" "$watch_replies")
  [ -n "$reply" ] || reply=$(tail -1 "$watch_replies")
  printf '%s' "${reply#*:}"
  return "${reply%%:*}"
}
hs_job_is_final() {       # 0 + the state only when accounting has a terminal one
  [ -n "$watch_final" ] && hs_state_is_final "$watch_final" && printf '%s\n' "$watch_final"
}
hs_job_accounting()   { echo "accounting for $1"; }
watch_run() {             # space-separated replies, optional accounting state
  printf '%s\n' "$1" | tr ' ' '\n' > "$watch_replies"
  watch_final="${2:-}"
  echo 1 > "$watch_tick"
  ( hs_watch 12345 0 ) 2>&1
}

out=$(watch_run "0:RUNNING 0:RUNNING 1:"); rc=$?
check "watch exits 0 on a real completion"     0 "$rc"
check_contains "and says the job left"         "left the queue" "$out"

out=$(watch_run "0:RUNNING 2:boom"); rc=$?
check "watch fails when the answers stop"      1 "$rc"
case "$out" in
  *"left the queue"*) FAILED=$((FAILED + 1)); echo "FAIL  watch called a lost connection a completion" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac
check_contains "and refuses in so many words"  "NOT reporting it finished" "$out"

# Repeated misses, but accounting holds a TERMINAL state: the controller has merely
# forgotten a job that did finish, which is what squeue does once one ages past MinJobAge.
out=$(watch_run "0:RUNNING 2:gone 2:gone 2:gone" COMPLETED); rc=$?
check "accounting evidence ends the watch"     0 "$rc"
check_contains "and names the state it trusted" "COMPLETED" "$out"

# The same misses with a job accounting still calls RUNNING must not end it.
out=$(watch_run "0:RUNNING 2:gone 2:gone 2:gone" RUNNING); rc=$?
check "a running job is never a completion"    1 "$rc"

rm -f "$watch_tick" "$watch_replies"
unset -f hs_job_state hs_job_is_final hs_job_accounting watch_run
. "$HS_ROOT/lib/slurm.sh"

# hs_job_is_final for real, through a fake sacct. This is the function that supplies the
# positive evidence issue #8 asked for, and the watch harness above stubs it out.
sacct_bin=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")
cat > "$sacct_bin/sacct" <<'SACCT'
#!/bin/sh
printf '%s\n' "$FAKE_SACCT"
SACCT
chmod +x "$sacct_bin/sacct"
export FAKE_SACCT
# The login shell chatters on stdout BEFORE the piped sh starts — the premise this whole
# file is built on. An untagged parser would read "Loading" as the job's state.
hs_run() { [ -t 0 ] && return 99; echo "Loading module gcc/12"; PATH="$sacct_bin:$PATH" /bin/sh; }
hs_ensure_open() { :; }

FAKE_SACCT='COMPLETED';  final=$(hs_job_is_final 12345); rc=$?
check "a finished job is final"                "COMPLETED|0" "$final|$rc"
FAKE_SACCT='CANCELLED by 1234'; final=$(hs_job_is_final 12345); rc=$?
check "CANCELLED keeps only the state"         "CANCELLED|0" "$final|$rc"
# One row per array task. First-row-wins would call this whole array finished while two of
# its three tasks are still running — and this is the fallback for when squeue has stopped
# answering, so it must not be weaker than the squeue path it stands in for.
FAKE_SACCT='COMPLETED
RUNNING
RUNNING'
final=$(hs_job_is_final 12345); rc=$?
check "a partly finished array is not final"   1 "$rc"
FAKE_SACCT='COMPLETED
FAILED'
final=$(hs_job_is_final 12345); rc=$?
check "an array finished throughout is final"  0 "$rc"
hs_run() { [ -t 0 ] && return 99; /bin/sh; }   # no sacct on PATH at all
FAKE_SACCT=''; final=$(hs_job_is_final 12345); rc=$?
check "absent sacct is not evidence"           "|1" "$final|$rc"
rm -rf "$sacct_bin"
restore_lib

check "RUNNING is not terminal"    no  "$(hs_state_is_final RUNNING && echo yes || echo no)"
check "COMPLETED is terminal"      yes "$(hs_state_is_final COMPLETED && echo yes || echo no)"
check "an unknown state is not"    no  "$(hs_state_is_final WEIRD_NEW_STATE && echo yes || echo no)"

# The keychain line is re-tokenised by `security -i`, so a quote or a newline in either
# identifier would inject options — or a whole second command — into something running
# against the user's keychain, where argv made them inert tokens. Refused, not escaped.
#
# `security` is SHADOWED for this block, and that is not belt-and-braces. The assertion is
# safe only while the guard fires, which is precisely the condition it exists to detect: a
# regression here would otherwise write to the login keychain of whoever ran the suite —
# with the injected `-A` that lets any application read the item without a prompt. That
# happened once, during review of this very change.
keychain_bin=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")
keychain_log="$keychain_bin/called"
printf '#!/bin/sh\ncat >> "%s"\necho "argv: $*" >> "%s"\n' "$keychain_log" "$keychain_log" \
  > "$keychain_bin/security"
chmod +x "$keychain_bin/security"
poison_probe() {  # service, account
  ( PATH="$keychain_bin:$PATH"
    HS_TOTP_BACKEND=keychain HS_TOTP_SERVICE="$1" HS_TOTP_ACCOUNT="$2" \
      hs_seed_store_backend AAAAAAAA ) 2>&1
}
poisoned=$(poison_probe 'x" -A -a "x' me); rc=$?
check "a quoted service name is refused"       1 "$rc"
check_contains "and says which keys"           "HS_TOTP_SERVICE" "$poisoned"
# security -i runs one command per LINE, so a newline appends a second command outright.
poisoned=$(poison_probe "svc" "me
delete-keychain login.keychain"); rc=$?
check "a newline in the account is refused"    1 "$rc"
check "and nothing reached security"           0 "$(status_of test ! -s "$keychain_log")"
# A single quote is legitimate: both values land inside "%s" fields, where security reads
# it literally. Refusing it would be a documented rule the code does not need.
poison_probe "o'brien" me >/dev/null 2>&1
check "an apostrophe is accepted"              0 "$(status_of test -s "$keychain_log")"
rm -rf "$keychain_bin"

# `doctor` is documented as the last step of setup, so it must not send a `command` backend
# user to store-seed — a subcommand that exits 1 saying it stores nothing.
#
# Asserted through the SUBCOMMANDS, not through hs_seed_hint alone. Testing only the new
# helper would repeat exactly what issue #14 raised against #1's watch test: an assertion on
# a function that proves nothing about the call sites the fix was actually about.
doc_dir=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")
cat > "$doc_dir/cmdbackend.conf" <<'PROFILE'
HS_HOST="cluster.invalid"
HS_TOTP_BACKEND="command"
HS_TOTP_CMD=""
PROFILE
doc_out=$(HS_CONFIG_DIR="$doc_dir" "$HS_ROOT/bin/hpc-session" -p cmdbackend doctor 2>&1)
check_contains "doctor names the key to set" "HS_TOTP_CMD" "$doc_out"
case "$doc_out" in
  *store-seed*) FAILED=$((FAILED + 1)); echo "FAIL  doctor misdirects the command backend to store-seed" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac
# ...and must not demand an interpreter this backend's code path never reaches.
case "$doc_out" in
  *"needed to generate TOTP codes"*)
     FAILED=$((FAILED + 1)); echo "FAIL  doctor demands python for the command backend" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac
cat > "$doc_dir/filebackend.conf" <<'PROFILE'
HS_HOST="cluster.invalid"
HS_TOTP_BACKEND="file"
HS_TOTP_FILE="/nonexistent/seed"
PROFILE
doc_out=$(HS_CONFIG_DIR="$doc_dir" "$HS_ROOT/bin/hpc-session" -p filebackend doctor 2>&1)
check_contains "a storing backend still hears store-seed" "store-seed" "$doc_out"
rm -rf "$doc_dir"

# status is the other misdirecting call site. Stubbed at hs_master_up so it stays offline.
hs_real_master_up=$(declare -f hs_master_up)
hs_master_up() { return 1; }
status_out=$(HS_TOTP_BACKEND=command HS_TOTP_CMD="" HS_VPN_UP_CMD="" hs_status 2>&1)
check_contains "status names the key to set" "HS_TOTP_CMD" "$status_out"
case "$status_out" in
  *store-seed*) FAILED=$((FAILED + 1)); echo "FAIL  status misdirects the command backend to store-seed" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac
eval "$hs_real_master_up"

# The seed must never be built into an argv. Assert against the executable lines only —
# checking the whole file matches the comment that explains the bug.
totp_code=$(grep -v '^[[:space:]]*#' "$HS_ROOT/lib/totp.sh")
check_contains "keychain backend pipes through security -i" "| security -i" "$totp_code"
case "$totp_code" in
  *'-w "$seed"'*) FAILED=$((FAILED + 1)); echo "FAIL  seed is passed in argv to security" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac

# --- CLI surface ---------------------------------------------------------------------
help_text=$("$HS_ROOT/bin/hpc-session" --help)
check_contains "help mentions open"   "hpc-session open"   "$help_text"
check_contains "help mentions submit" "hpc-session submit" "$help_text"

bad=$("$HS_ROOT/bin/hpc-session" push only-one-arg 2>&1); rc=$?
check "push with one argument fails" 1 "$rc"
check_contains "push explains itself" "usage: push" "$bad"

# `init` ran after the loader, which treats a missing named profile as fatal, so it was
# refused whenever the name arrived BEFORE the subcommand — via `-p`, the only selector
# README documents, or an exported HS_PROFILE. The positional `init <name>` did work.
init_dir=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")/cfg
HS_CONFIG_DIR="$init_dir" "$HS_ROOT/bin/hpc-session" -p bigiron init >/dev/null 2>&1
check "-p <name> init creates the profile" 0 "$(status_of test -f "$init_dir/bigiron.conf")"
rm -rf "$init_dir"
HS_CONFIG_DIR="$init_dir" HS_PROFILE=bigiron "$HS_ROOT/bin/hpc-session" init >/dev/null 2>&1
check "exported HS_PROFILE init creates it" 0 "$(status_of test -f "$init_dir/bigiron.conf")"
rm -rf "$(dirname "$init_dir")"

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
