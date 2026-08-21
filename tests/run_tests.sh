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

# `$NF` took the CLUSTER NAME from sbatch's second documented form, and hs_submit printed
# it on stdout as the job id — the value SKILL.md tells an agent to capture and then watch,
# fetch and cancel.
check "job id, not the cluster name" 12345 \
  "$(printf 'Submitted batch job 12345 on cluster tiger\n' | hs_parse_job_id)"
check "job id behind a plugin prefix" 999 \
  "$(printf 'sbatch: Submitted batch job 999\n' | hs_parse_job_id)"
# --parsable prints no message at all, so requiring the phrase killed submit AFTER the job
# was queued — and a caller retrying on non-zero submitted it twice.
check "job id from --parsable"         4242 "$(printf '4242\n' | hs_parse_job_id)"
check "job id from --parsable cluster" 4242 "$(printf '4242;tiger\n' | hs_parse_job_id)"

# What may reach a remote command line as a job id: SLURM's own forms, and nothing else.
valid_id() { hs_valid_job_id "$1" && echo yes || echo no; }
check "a plain job id"        yes "$(valid_id 12345)"
check "an array task"         yes "$(valid_id 12345_7)"
check "a pending array range" yes "$(valid_id '12345_[1-3]')"
check "a het component"       yes "$(valid_id 12345+0)"
check "a job step"            yes "$(valid_id 12345.0)"
check "a cluster name"        no  "$(valid_id tiger)"
check "a trailing command"    no  "$(valid_id '12345; rm -rf /')"
check "an embedded quote"     no  "$(valid_id "12345'")"
check "a substitution"        no  "$(valid_id '$(id -u)')"
check "nothing at all"        no  "$(valid_id '')"
unset -f valid_id

# Round-tripped through a REAL sh, the way hs_run_sh delivers it. An assertion on the
# quoted string alone would pass for a scheme sh happens to read differently.
shq=$(printf 'for a in%s\ndo printf "<%%s>" "$a"\ndone\n' \
  "$(hs_shquote "a b" '$(echo SUBSTITUTED)' "it's" 'x;y')" | /bin/sh -s)
check "shquote survives a real sh" "<a b><\$(echo SUBSTITUTED)><it's><x;y>" "$shq"

HS_REMOTE_WORKDIR="/scratch/me/jobs"
check "remote path" "/scratch/me/jobs/job.slurm" \
  "$(hs_remote_path /scratch/me/jobs ./local/dir/job.slurm)"

check "empty sbatch line dropped" "#SBATCH --time=1:00" \
  "$(printf '#SBATCH --account=\n#SBATCH --time=1:00\n' | hs_strip_empty_sbatch)"
check "filled sbatch line kept" "#SBATCH --account=abc" \
  "$(printf '#SBATCH --account=abc\n' | hs_strip_empty_sbatch)"

# --- rendering -----------------------------------------------------------------------

# A template argument is a PATH or a bare NAME. The name form is what lets a skill that
# owns a job TYPE avoid owning a path: it points HS_TEMPLATE_DIR at its own assets.
tmpl_dir=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")
printf '#SBATCH --job-name=${JOB_NAME}\nOWN TEMPLATE\n' > "$tmpl_dir/sirius.slurm.tmpl"
printf 'ignored\n' > "$tmpl_dir/notes.md"
check "a bare name resolves in the template dir" "$tmpl_dir/sirius.slurm.tmpl" \
  "$( HS_TEMPLATE_DIR="$tmpl_dir" hs_template_path sirius )"
check "a path is used as given"       "templates/job.slurm.tmpl" \
  "$( HS_TEMPLATE_DIR="$tmpl_dir" hs_template_path templates/job.slurm.tmpl )"
check "a bare .tmpl file is a path"   "job.slurm.tmpl" \
  "$( HS_TEMPLATE_DIR="$tmpl_dir" hs_template_path job.slurm.tmpl )"
check_contains "render finds a template by name" "OWN TEMPLATE" \
  "$( HS_TEMPLATE_DIR="$tmpl_dir" hs_render sirius JOB_NAME=x 2>/dev/null )"
# `templates` lists NAMES, since a name is what render takes, and only job templates.
check "templates lists what render can take" "sirius" \
  "$( HS_TEMPLATE_DIR="$tmpl_dir" hs_templates 2>/dev/null )"
out=$( HS_TEMPLATE_DIR="$tmpl_dir/empty" hs_templates 2>&1 ); rc=$?
check "an empty template dir is not an error" 0 "$rc"
check_contains "but says so"                  "no job templates" "$out"
out=$( HS_TEMPLATE_DIR="$tmpl_dir" hs_render nosuch 2>&1 ); rc=$?
check "an unknown name fails"                 1 "$rc"
check_contains "and points at the list"       "hpc-session templates" "$out"
rm -rf "$tmpl_dir"

# The shipped template is reachable by its own name, which is what the docs quote.
check "the shipped template is named job" "job" \
  "$(hs_templates 2>/dev/null | grep -x job)"

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
submit_log=$(mktemp "${TMPDIR:-/tmp}/hstest.XXXXXX")
submit_reply='Submitted batch job 4711'
hs_run() {   # the CLUSTER expands $USER, and its shell startup chatters over the same stdout
  local cmd; cmd=$(remote_cmd)
  case "$cmd" in
    *hs_workdir*) printf 'Loading module gcc/12\nhs_workdir=/scratch/realuser/jobs\n' ;;
    *sbatch*)     printf '%s\n' "$cmd" > "$submit_log"; printf '%s\n' "$submit_reply" ;;
    *)            return 0 ;;
  esac
}
job_id=$(hs_submit "$HS_ROOT/templates/job.slurm.tmpl" 2>/dev/null)
check "submit prints only the job id"  4711 "$job_id"
check "workdir reaches scp expanded"   "/scratch/realuser/jobs/job.slurm.tmpl" \
  "$(cat "$push_log" 2>/dev/null)"

# README promises extra arguments reach sbatch unchanged. `sbatch $*` handed every one of
# them to the remote shell to re-parse: double quotes there do not suppress command
# substitution, and $* had already lost the boundaries between arguments.
job_id=$(hs_submit "$HS_ROOT/templates/job.slurm.tmpl" '--comment=$(id -u)' 'a b' 2>/dev/null)
submit_cmd=$(cat "$submit_log" 2>/dev/null)
check_contains "an argument with a space stays one" "'a b'" "$submit_cmd"
check_contains "a substitution reaches sbatch inert" "'--comment=\$(id -u)'" "$submit_cmd"
check_contains "the script path is quoted too" "'/scratch/realuser/jobs/job.slurm.tmpl'" "$submit_cmd"
# The workdir is the one value still expanded by the cluster, because a profile's $USER can
# only be resolved there.
check_contains "but the workdir still expands remotely" 'cd "/scratch/$USER/jobs"' "$submit_cmd"

# Whatever comes back out of the parser is the value SKILL.md tells an agent to capture and
# then hand to watch, fetch and cancel. Anything that is not a job id has to be refused
# HERE — and the refusal has to say the job is probably queued, because a caller that reads
# a non-zero submit as "it did not happen" will submit it again.
submit_reply='Submitted batch job array 4711'
out=$( hs_submit "$HS_ROOT/templates/job.slurm.tmpl" 2>&1 ); rc=$?
check "a non-id from sbatch is refused"        1 "$rc"
check_contains "and the queue is not assumed empty" "hpc-session queue" "$out"

submit_reply='sbatch: submitted, have a nice day'
out=$( hs_submit "$HS_ROOT/templates/job.slurm.tmpl" 2>&1 ); rc=$?
check "an unreadable reply is refused"         1 "$rc"
check_contains "and warns against resubmitting" "before resubmitting" "$out"

# Federated submission is out of scope — nothing here passes -M, so the id would be queried
# against the default cluster and match nothing. Say so rather than failing silently later.
submit_reply='Submitted batch job 4711 on cluster tiger'
out=$( hs_submit "$HS_ROOT/templates/job.slurm.tmpl" 2>&1 >/dev/null ); rc=$?
check "a federated submit still succeeds"      0 "$rc"
check_contains "and warns which cluster is queried" "another cluster" "$out"
check "and still prints the job id" 4711 "$(hs_submit "$HS_ROOT/templates/job.slurm.tmpl" 2>/dev/null)"

rm -f "$push_log" "$submit_log"
unset submit_reply
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

# fetch and cancel take a caller-supplied id straight into a remote string. The caller is
# increasingly an agent passing a value it read out of a file or an API response, so the
# id is checked before it can become part of a command line — not after.
refuse_log=$(mktemp "${TMPDIR:-/tmp}/hstest.XXXXXX")
hs_run() { remote_cmd > "$refuse_log"; }
hs_ensure_open() { :; }
hs_pull() { :; }
: > "$refuse_log"
out=$( hs_cancel "12345' ; touch /tmp/hs-pwned" 2>&1 ); rc=$?
check "cancel refuses a non-id"             1 "$rc"
check "and asked the cluster nothing"       0 "$(status_of test ! -s "$refuse_log")"
: > "$refuse_log"
out=$( hs_fetch '$(id -u)' "$TMPDIR" 2>&1 ); rc=$?
check "fetch refuses a non-id"              1 "$rc"
check "and fetched nothing either"          0 "$(status_of test ! -s "$refuse_log")"
rm -f "$refuse_log"
restore_lib

# `%.10i` hard-cuts rather than elides, so the array task 12345678_10 was DISPLAYED as
# 12345678_1 — a valid id for a different task of the same array, which a reader would then
# have passed to cancel.
queue_log=$(mktemp "${TMPDIR:-/tmp}/hstest.XXXXXX")
hs_run() { remote_cmd > "$queue_log"; }
hs_ensure_open() { :; }
hs_queue >/dev/null 2>&1
queue_cmd=$(cat "$queue_log" 2>/dev/null)
rm -f "$queue_log"
restore_lib
check_contains "queue asks for the whole job id" "'%i " "$queue_cmd"
case "$queue_cmd" in
  *%.[0-9]*i*) FAILED=$((FAILED + 1)); echo "FAIL  queue still truncates the job id" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac

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

# --- claims the documentation makes ---------------------------------------------------

# `local` helps exactly the tools that read these two variables. The docs listed sshfs
# among them; sshfs reads neither, takes its transport from `-o ssh_command=`, and would
# therefore have opened a SECOND unmultiplexed connection — under TOTP, a second code,
# which is the one thing this tool exists to prevent.
hs_ensure_open() { :; }
local_env=$(hs_local /bin/sh -c 'printf "%s|%s" "${RSYNC_RSH:-none}" "${GIT_SSH_COMMAND:-none}"')
restore_lib
check_contains "local exports RSYNC_RSH"       "ControlMaster=auto" "${local_env%%|*}"
check_contains "local exports GIT_SSH_COMMAND" "ControlMaster=auto" "${local_env##*|}"

# The check before the tunnel. docs/vpn-hooks.md used to say the tool verifies it can
# authenticate, which it cannot — under a full tunnel the login node is unreachable until
# the tunnel is up. What it does verify is that a code can be PRODUCED, and that has to
# happen before HS_VPN_UP_CMD runs, because a full tunnel monopolises the link.
vpn_log=$(mktemp "${TMPDIR:-/tmp}/hstest.XXXXXX")
vpn_ctl=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")
hs_master_up()        { return 1; }
hs_clean_stale()      { :; }
hs_have_seed()        { return 1; }
hs_open_with_retries()  { echo "AUTHENTICATED"; }
: > "$vpn_log"
out=$( HS_HOST=cluster HS_CONTROL_DIR="$vpn_ctl" HS_TOTP_BACKEND=keychain \
       HS_VPN_UP_CMD="echo ran > $vpn_log" HS_VPN_STATUS_CMD=false \
       hs_open_session 2>&1 ); rc=$?
check "open refuses without a code"          1 "$rc"
check "and the VPN was never raised"         0 "$(status_of test ! -s "$vpn_log")"
check_contains "and says what is missing"    "store-seed" "$out"

# ...and with a code available it gets past the check, raising the tunnel first.
hs_have_seed() { return 0; }
: > "$vpn_log"
out=$( HS_HOST=cluster HS_CONTROL_DIR="$vpn_ctl" HS_TOTP_BACKEND=keychain \
       HS_VPN_UP_CMD="echo ran > $vpn_log" HS_VPN_STATUS_CMD=false \
       hs_open_session 2>&1 ); rc=$?
check "open proceeds when a code exists"     0 "$rc"
check "and the VPN went up first"            0 "$(status_of test -s "$vpn_log")"
rm -rf "$vpn_log" "$vpn_ctl"
restore_lib
# hs_have_seed lives in totp.sh, the other three in session.sh. Both have to come back:
# HS_REAL_DEFS holds only the transport functions, so restore_lib alone would leave this
# block's stubs standing for the rest of the suite — the exact leak #14 raised against #1.
. "$HS_ROOT/lib/totp.sh"
. "$HS_ROOT/lib/session.sh"

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
# in a subshell because it may hs_die.
#
# `sleep` and `date` are shadowed for this block. The interval floor means a zero interval
# is no longer honoured by default, so without a stub the suite would sit out a real 30
# seconds per poll; and the duration cap is measured in wall-clock seconds, which a test
# must be able to move without spending any. Neither is used anywhere else in this path.
sleep() { :; }
watch_clock=$(mktemp "${TMPDIR:-/tmp}/hstest.XXXXXX")
echo 0 > "$watch_clock"
date() {                  # every reading is 100s after the last
  local n; n=$(cat "$watch_clock"); echo $((n + 100)) > "$watch_clock"; printf '%s\n' "$n"
}
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
watch_run() {             # replies, [accounting state], [interval]
  printf '%s\n' "$1" | tr ' ' '\n' > "$watch_replies"
  watch_final="${2:-}"
  echo 1 > "$watch_tick"
  echo 0 > "$watch_clock"
  ( hs_watch 12345 "${3:-0}" ) 2>&1
}
# The completion assertions below are about the completion logic, so they opt out of the
# polling limits; each limit has its own assertions further down.
HS_WATCH_MIN_INTERVAL=0
HS_WATCH_MAX_SECONDS=0

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

# The polling limits. docs/cluster-etiquette.md and SKILL.md state both of these as rules,
# and SKILL.md is read by an agent, which will assume a stated rule is enforced. Until now
# `watch 12345 0` was a busy-wait against the controller holding an authenticated master
# open — from a tool whose own documentation forbids exactly that.
out=$( HS_WATCH_MIN_INTERVAL=30 watch_run "0:RUNNING 1:" "" 5 ); rc=$?
check "a completion still ends the watch"      0 "$rc"
check_contains "a short interval is raised"    "polling every 30s, not 5s" "$out"

out=$( HS_WATCH_MIN_INTERVAL=30 watch_run "0:RUNNING 1:" "" 60 ); rc=$?
case "$out" in
  *"polling every"*) FAILED=$((FAILED + 1)); echo "FAIL  watch clamped an interval it should have honoured" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac

# The cap. The replies never end, so only the cap can stop this.
out=$( HS_WATCH_MAX_SECONDS=60 watch_run "0:RUNNING" ); rc=$?
check "watch stops at the duration cap"        3 "$rc"
check_contains "and names the key that did it" "HS_WATCH_MAX_SECONDS" "$out"
check_contains "and says how to come back"     "hpc-session queue" "$out"
case "$out" in
  *"left the queue"*) FAILED=$((FAILED + 1)); echo "FAIL  the duration cap reported a completion" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac

# ...and zero means no cap, which is what the endless replies then run into: the harness's
# own 20-poll guard, which answers 1 and so reads as a completion.
out=$( HS_WATCH_MAX_SECONDS=0 watch_run "0:RUNNING" ); rc=$?
check "a zero cap keeps polling"               0 "$rc"

# Arguments, before any of it reaches the cluster.
out=$( watch_run "0:RUNNING 1:" "" abc ); rc=$?
check "a non-numeric interval is refused"      1 "$rc"
check_contains "and says what it wanted"       "whole number of seconds" "$out"

out=$( hs_watch '12345; touch /tmp/hs-pwned' 0 2>&1 ); rc=$?
check "watch refuses a non-id"                 1 "$rc"
check_contains "and says why"                  "not a job id" "$out"
check "and no command ran"                     0 "$(status_of test ! -e /tmp/hs-pwned)"

rm -f "$watch_tick" "$watch_replies" "$watch_clock"
unset -f hs_job_state hs_job_is_final hs_job_accounting watch_run sleep date
unset HS_WATCH_MIN_INTERVAL HS_WATCH_MAX_SECONDS
hs_apply_defaults
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

# --- the 2026-07 audit's remaining findings --------------------------------------------

# fetch ran its per-file copy on the right of a pipe, so the function's status was the LAST
# copy's: every earlier scp failure was invisible in both the output and the exit code, and
# a caller saw a clean 0 for a partial retrieval.
fetch_root=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")
: > "$fetch_root/good-12345.out"
: > "$fetch_root/bad-12345.err"
HS_REMOTE_WORKDIR="$fetch_root"
hs_run() { [ -t 0 ] && return 99; /bin/sh; }
hs_ensure_open() { :; }
hs_pull() { case "$1" in *bad-*) return 1 ;; *) return 0 ;; esac; }
partial=$( hs_fetch 12345 "$fetch_root/dest" 2>/dev/null ); rc=$?
check "a partial fetch is not a success"     1 "$rc"
check_contains "and the copies that worked are still reported" "good-12345.out" "$partial"
# ...while an entirely successful one still is.
hs_pull() { :; }
partial=$( hs_fetch 12345 "$fetch_root/dest" 2>/dev/null ); rc=$?
check "a complete fetch succeeds"            0 "$rc"
rm -rf "$fetch_root"
restore_lib


# A live TOTP code must not outlive the process that generated it. Falling through to
# `rm -f` covered the normal path only: a SIGINT between writing the file and ssh reading
# it left an unused, still-valid code on disk with nothing left to delete it.
trap_dir=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")
cat > "$trap_dir/probe.sh" <<PROBE
. "$HS_ROOT/lib/config.sh"
. "$HS_ROOT/lib/totp.sh"
. "$HS_ROOT/lib/session.sh"
f=\$(mktemp "$trap_dir/code.XXXXXX")
echo 424242 > "\$f"
hs_temp_track "\$f"
echo "\$f" > "$trap_dir/path"
kill -INT \$\$
sleep 30
PROBE
/bin/bash "$trap_dir/probe.sh" >/dev/null 2>&1
trap_left=$(cat "$trap_dir/path" 2>/dev/null)
check "a SIGINT takes the code file with it" 0 "$(status_of test ! -e "${trap_left:-/nonexistent}")"
check "and there was a file to take"         0 "$(status_of test -n "$trap_left")"
rm -rf "$trap_dir"

# The askpass helper is single-shot on purpose: if it kept answering, a stale code would
# make ssh re-invoke it in a loop and hang for minutes.
ask_dir=$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")
echo 424242 > "$ask_dir/code"
hs_write_askpass "$ask_dir/code" "$ask_dir/ask"
ask_first=$("$ask_dir/ask" 2>/dev/null)
"$ask_dir/ask" >/dev/null 2>&1; ask_rc=$?
check "the askpass helper answers once"      424242 "$ask_first"
check "and fails on the second call"         1 "$ask_rc"
check "and the code file is gone"            0 "$(status_of test ! -e "$ask_dir/code")"
rm -rf "$ask_dir"

# A bad key on a site running AuthenticationMethods publickey,keyboard-interactive — the
# setup this tool exists for — does not produce a bare "(publickey)", so it was retried
# three times over ~90s instead of failing at once.
check "a key failure under 2FA is fatal"   fatal "$(fatal_verdict 'Permission denied (publickey,keyboard-interactive).')"
check "too many failures is fatal"         fatal "$(fatal_verdict 'Received disconnect: Too many authentication failures')"
# ...while the consumed-code case stays retryable, which is the whole point of the retry.
check "a rejected code is still retried"   retry "$(fatal_verdict 'Permission denied (keyboard-interactive).')"

# A LOCAL failure — no seed, no code — cannot be fixed by waiting a time step, but returning
# 2 without running ssh left HS_SSH_ERROR holding the previous attempt's text, so the loop
# judged a stale string and sat out three of them.
try_log=$(mktemp "${TMPDIR:-/tmp}/hstest.XXXXXX")
sleep() { :; }
hs_step_left() { echo 1; }
hs_try_open() { echo TRIED >> "$try_log"; return 2; }
: > "$try_log"
out=$( HS_AUTH_ATTEMPTS=3 hs_open_with_retries 2>&1 ); rc=$?
check "a local failure is not retried"       1 "$rc"
check "and ssh was attempted once only"      1 "$(grep -c TRIED "$try_log")"
check_contains "and it names the setting"    "store-seed" "$out"

hs_try_open() { echo TRIED >> "$try_log"; HS_SSH_ERROR="Permission denied (keyboard-interactive)."; return 1; }
: > "$try_log"
out=$( HS_AUTH_ATTEMPTS=3 hs_open_with_retries 2>&1 ); rc=$?
check "a consumed code is retried in full"   3 "$(grep -c TRIED "$try_log")"
rm -f "$try_log"
unset -f sleep hs_step_left hs_try_open
. "$HS_ROOT/lib/totp.sh"
. "$HS_ROOT/lib/session.sh"

# `set -uo pipefail` has no -e, so a control directory that cannot be created let the open
# proceed and simply never multiplex — indistinguishable from a slow cluster.
#
# The two functions after the mkdir are stubbed so that a REGRESSION cannot reach the
# network: without the guard, hs_open_session runs on to hs_clean_stale and the real ssh.
hs_clean_stale() { :; }
hs_open_with_retries() { echo "REACHED THE OPEN"; }
out=$( HS_HOST=cluster HS_CONTROL_DIR=/dev/null/nope hs_open_session 2>&1 ); rc=$?
check "an uncreatable control dir is fatal"  1 "$rc"
check_contains "and says what it costs"      "multiplexes" "$out"
case "$out" in
  *"REACHED THE OPEN"*) FAILED=$((FAILED + 1)); echo "FAIL  open continued past an unusable control directory" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac
unset -f hs_clean_stale hs_open_with_retries
. "$HS_ROOT/lib/session.sh"

# docs/vpn-hooks.md recommends setting only HS_VPN_STATUS_CMD for a tunnel you keep up
# yourself. Keying "is there a VPN" off HS_VPN_UP_CMD alone made that configuration report
# "not configured" — the user's own status command was never run.
vpn_verdict() { ( HS_VPN_UP_CMD="$1" HS_VPN_STATUS_CMD="$2"; hs_uses_vpn && echo yes || echo no ); }
check "status-only counts as a VPN"          yes "$(vpn_verdict '' 'true')"
check "both hooks count as a VPN"            yes "$(vpn_verdict 'up' 'true')"
check "neither hook is no VPN"               no  "$(vpn_verdict '' '')"
# ...and with no way to raise it, a down tunnel is refused rather than `eval ""`-ed.
out=$( HS_VPN_UP_CMD='' HS_VPN_STATUS_CMD='false' hs_vpn_connect 2>&1 ); rc=$?
check "a down status-only tunnel is refused" 1 "$rc"
check_contains "and says to raise it"        "bring it up yourself" "$out"
unset -f vpn_verdict

# umask governs creation only, so a seed written into an HS_TOTP_FILE that already existed
# at 0644 kept that mode — a permanent second factor, readable by anyone on the machine.
file_mode() { ls -l "$1" | cut -c2-10; }
seed_file="$HS_CONFIG_DIR/loose.seed"
: > "$seed_file"; chmod 644 "$seed_file"
( HS_TOTP_BACKEND=file HS_TOTP_FILE="$seed_file" hs_seed_store_backend GEZDGNBVGY3TQOJQ )
check "an existing seed file is tightened"   "rw-------" "$(file_mode "$seed_file")"
rm -f "$seed_file"
unset -f file_mode

# `getattr(hashlib, algo)` and `int(...)` were unguarded, and hs_store_seed discarded the
# stderr that said so — every failure was reported as an invalid seed, sending the user to
# re-enrol over a mistyped parameter.
out=$(printf 'GEZDGNBVGY3TQOJQ' | HS_TOTP_ALGO=md5 hs_seed_to_code 2>&1); rc=$?
check "a bad algorithm fails"                1 "$rc"
check_contains "and names the algorithm"     "sha1, sha256 or sha512" "$out"
out=$(printf 'GEZDGNBVGY3TQOJQ' | HS_TOTP_PERIOD=30s hs_seed_to_code 2>&1); rc=$?
check_contains "a bad period says so"        "whole numbers" "$out"
out=$(printf 'GEZDGNBVGY3TQOJQ\n' | HS_TOTP_BACKEND=file HS_TOTP_FILE="$HS_CONFIG_DIR/x.seed" \
      HS_TOTP_ALGO=md5 hs_store_seed 2>&1); rc=$?
check "store-seed fails on a bad algorithm"  1 "$rc"
check_contains "and does not blame the seed" "sha1, sha256 or sha512" "$out"
rm -f "$HS_CONFIG_DIR/x.seed"

# hs_usage sliced lines 2-25 out of its own source while the header ended at 19, so
# `--help` printed executable code as if it were documentation.
help_out=$(/bin/bash "$HS_ROOT/bin/hpc-session" --help 2>&1)
check_contains "help shows the usage"        "hpc-session open" "$help_out"
case "$help_out" in
  *"set -uo pipefail"*|*"hs_script_dir"*) FAILED=$((FAILED + 1)); echo "FAIL  --help printed executable code" ;;
  *) PASSED=$((PASSED + 1)) ;;
esac

# Every key hs_apply_defaults knows about should be findable in config.example — that file
# is what `init` copies, and README calls it the reference for every setting.
undocumented=""
for key in $(sed -n 's/^  : "${\(HS_[A-Z_]*\):=.*/\1/p' "$HS_ROOT/lib/config.sh"); do
  grep -q "$key" "$HS_ROOT/config.example" || undocumented="$undocumented $key"
done
check "every default is in config.example"   "" "$undocumented"

# The no-argument subcommands ignored trailing arguments, so `open -p bigiron` opened the
# DEFAULT cluster while appearing to select a profile — and spent a TOTP code doing it.
out=$(/bin/bash "$HS_ROOT/bin/hpc-session" status -p bigiron 2>&1); rc=$?
check "a no-argument subcommand refuses extras" 1 "$rc"
check_contains "and says where -p goes"      "goes first" "$out"

# --- CLI surface ---------------------------------------------------------------------
help_text=$("$HS_ROOT/bin/hpc-session" --help)
check_contains "help mentions open"   "hpc-session open"   "$help_text"
check_contains "help mentions submit" "hpc-session submit" "$help_text"

# A release whose tool cannot say which release it is leaves a caller — an agent most of
# all — no way to know which side of a behaviour change it is on. The version has to
# survive a profile that does not load, and it has to match the newest CHANGELOG heading,
# or the tag, the notes and the tool drift apart silently.
ver_out=$("$HS_ROOT/bin/hpc-session" version 2>&1); rc=$?
check "version exits 0"                      0 "$rc"
check_contains "version names the tool"      "hpc-session" "$ver_out"
ver_num=${ver_out##* }
changelog_num=$(sed -n 's/^## \([0-9][0-9.]*\) .*/\1/p' "$HS_ROOT/CHANGELOG.md" | head -1)
check "version matches the changelog"        "$changelog_num" "$ver_num"

# It must answer with a profile that does not exist, which is when someone is diagnosing.
ver_broken=$(HS_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")" \
  "$HS_ROOT/bin/hpc-session" -p nosuchprofile version 2>&1); rc=$?
check "version survives a missing profile"   0 "$rc"
check "and still reports the version"        "hpc-session $changelog_num" "$ver_broken"

doc_ver=$(HS_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hstest.XXXXXX")" \
  "$HS_ROOT/bin/hpc-session" doctor 2>&1)
check_contains "doctor reports the version"  "hpc-session $changelog_num" "$doc_ver"

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
