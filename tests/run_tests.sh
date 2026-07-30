#!/usr/bin/env bash
# Offline tests. No cluster, no VPN, no network — every function exercised here is pure.
#
#   tests/run_tests.sh

set -uo pipefail

HS_ROOT=$(cd "$(dirname "$0")/.." && pwd)
export HS_CONFIG_DIR="$HS_ROOT/tests/tmp-config"
HS_PROFILE=test

. "$HS_ROOT/lib/config.sh"
. "$HS_ROOT/lib/totp.sh"
. "$HS_ROOT/lib/session.sh"
. "$HS_ROOT/lib/slurm.sh"

PASSED=0
FAILED=0

check() {  # description, expected, actual
  if [ "$2" = "$3" ]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
  fi
}

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
check "remote path" "/scratch/me/jobs/job.slurm" "$(hs_remote_path ./local/dir/job.slurm)"

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

# `watch` read empty stdout as "the job finished". A dead master produces empty stdout too.
# The transport status must reach the caller through the one channel that survives command
# substitution — the exit code — because that is how hs_watch invokes it.
hs_run() { return 255; }                       # master gone
state=$(hs_job_state 12345); rc=$?
check "transport failure surfaces as 255"      255 "$rc"
check "transport failure yields no state"      ""  "$state"
hs_run() { printf 'RUNNING\n'; }               # job is queued
state=$(hs_job_state 12345); rc=$?
check "running job reports its state"          RUNNING "$state"
check "running job reports a clean status"     0       "$rc"
hs_run() { return 0; }                         # left the queue: empty stdout, status 0
state=$(hs_job_state 12345); rc=$?
check "finished job is empty at status 0"      "|0" "$state|$rc"
unset -f hs_run

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

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
