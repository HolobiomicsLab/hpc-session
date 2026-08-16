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
  case "$*" in
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
unset -f hs_ensure_open hs_push hs_run

# `ls -1` on a matching DIRECTORY prints its contents as bare relative names, which scp
# resolves against the remote home — delivering an unrelated file as if it were job output.
run_log=$(mktemp "${TMPDIR:-/tmp}/hstest.XXXXXX")
fetch_dir=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")
hs_run() { printf '%s\n' "$*" > "$run_log"; }
hs_fetch 12345 "$fetch_dir" >/dev/null 2>&1
fetch_cmd=$(cat "$run_log" 2>/dev/null)
rm -rf "$fetch_dir" "$run_log"
unset -f hs_run
check_contains "fetch skips directories"    "! -type d"   "$fetch_cmd"
check_contains "fetch does not descend"     "-maxdepth 1" "$fetch_cmd"
case "$fetch_cmd" in
  *"ls -1"*) FAILED=$((FAILED + 1)); echo "FAIL  fetch still lists directory contents" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac

# --- CLI surface ---------------------------------------------------------------------
help_text=$("$HS_ROOT/bin/hpc-session" --help)
check_contains "help mentions open"   "hpc-session open"   "$help_text"
check_contains "help mentions submit" "hpc-session submit" "$help_text"

bad=$("$HS_ROOT/bin/hpc-session" push only-one-arg 2>&1); rc=$?
check "push with one argument fails" 1 "$rc"
check_contains "push explains itself" "usage: push" "$bad"

# `init` ran after the loader, which treats a missing named profile as fatal — so the one
# subcommand whose job is to create a profile was refused for every profile but `default`.
init_dir=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")/cfg
HS_CONFIG_DIR="$init_dir" "$HS_ROOT/bin/hpc-session" -p bigiron init >/dev/null 2>&1
check "-p <name> init creates the profile" 0 "$([ -f "$init_dir/bigiron.conf" ]; echo $?)"
rm -rf "$init_dir"
HS_CONFIG_DIR="$init_dir" HS_PROFILE=bigiron "$HS_ROOT/bin/hpc-session" init >/dev/null 2>&1
check "exported HS_PROFILE init creates it" 0 "$([ -f "$init_dir/bigiron.conf" ]; echo $?)"
rm -rf "$(dirname "$init_dir")"

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
