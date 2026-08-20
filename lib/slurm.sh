# SLURM helpers. Every one of them rides the master opened by session.sh, so a whole
# submit/watch/fetch cycle costs at most one authentication.

# Extract the job id from sbatch's chatter.
#
# Not `$NF`. sbatch's message has a second documented form — "Submitted batch job 12345
# on cluster tiger" — where the last field is the CLUSTER NAME, and hs_submit would then
# print `tiger` on stdout as the job id. That is the value SKILL.md tells callers to
# capture with `job=$(hpc-session submit job.slurm)`, so an agent would go on to `watch
# tiger` and `fetch tiger`. Reading the field after the word "job" also survives a site
# plugin or `sbatch -v` prefixing the line.
#
# The second rule is `--parsable`, which prints the bare id (or "id;cluster") and no
# message at all. Requiring the exact phrase meant hs_submit died AFTER the job was
# queued, and a caller that retries on non-zero submitted it twice.
hs_parse_job_id() {
  awk '
    /Submitted batch job/ { for (i = 1; i < NF; i++) if ($i == "job") { print $(i + 1); exit } }
    /^[0-9]+(;[^;]*)?$/   { sub(/;.*/, "", $0); print; exit }
  '
}

# Quote arguments for the REMOTE shell: wrap each in single quotes, closing and reopening
# the quoting around any single quote inside it. POSIX, and therefore correct under the
# `sh` hs_run_sh pipes into — `printf %q` is not, since bash emits $'...' for control
# characters, which plain sh reads as a literal dollar sign.
hs_shquote() {
  # sq and esc are variables because the escaping needed to write '\'' as a literal inside
  # a double-quoted ${var//pat/rep} is its own trap: a backslash before a single quote is
  # NOT special in double quotes, so the obvious spelling ships a stray backslash.
  local arg out="" sq="'" esc="'\\''"
  for arg in "$@"; do
    out="$out '${arg//$sq/$esc}'"
  done
  printf '%s' "$out"
}

# What may reach a remote command line as a job id.
#
# SLURM's own forms are a plain number, an array task (12345_7), a pending array range
# (12345_[1-3]), a job step (12345.0) and a het component (12345+0), so the whitelist has
# to admit the punctuation SLURM itself prints — and nothing else. What it excludes is the
# point: no quote, no backslash, no `$`, no semicolon, so the value stays inert inside the
# single quotes every remote string in this file wraps it in.
#
# This matters more than it used to. The caller is increasingly an agent passing a value
# it derived from a file, an API response, or the output of a previous command.
hs_valid_job_id() {
  [ -n "${1:-}" ] || return 1
  case "$1" in [0-9]*) ;; *) return 1 ;; esac
  [ -z "$(printf '%s' "$1" | tr -d '0-9_.+,[]-')" ]
}

hs_require_job_id() {
  hs_valid_job_id "${1:-}" && return 0
  hs_die "not a job id: '${1:-}' — expected a number, optionally with an array task (12345_7), a step (12345.0) or a het component (12345+0)"
}

# Extract the workdir hs_submit asked the cluster to expand. Tagged rather than taken
# verbatim for the same reason the job id is parsed rather than read whole: a login node's
# shell startup may print module chatter onto the very same stdout.
hs_parse_workdir() { sed -n 's/^hs_workdir=//p' | tail -1; }

# Where a local script lands on the cluster: an already-resolved workdir, plus its basename.
# The workdir is passed in rather than read from the profile because it must be the value
# the CLUSTER expanded — see hs_submit.
hs_remote_path() { echo "$1/$(basename "$2")"; }

# Substitute the documented ${PLACEHOLDER}s in a job template. Extra KEY=VALUE pairs
# become extra substitutions, so a template can carry job-specific fields too.
hs_render() {
  local template="$1"; shift
  [ -f "$template" ] || hs_die "no such template: $template"
  local expressions=() pair key value
  for pair in \
    "SLURM_ACCOUNT=$HS_SLURM_ACCOUNT" "SLURM_PARTITION=$HS_SLURM_PARTITION" \
    "SLURM_TIME=$HS_SLURM_TIME" "SLURM_CPUS=$HS_SLURM_CPUS" "SLURM_MEM=$HS_SLURM_MEM" \
    "SLURM_NODES=$HS_SLURM_NODES" "SLURM_NTASKS=$HS_SLURM_NTASKS" \
    "REMOTE_WORKDIR=$HS_REMOTE_WORKDIR" "$@"; do
    key=${pair%%=*}
    value=$(hs_escape_replacement "${pair#*=}")
    expressions+=(-e "s|\${$key}|$value|g")
  done
  sed "${expressions[@]}" "$template" | hs_strip_empty_sbatch | hs_warn_unresolved
}

# Make a value safe on the right-hand side of `s|...|...|`: backslash first, then the
# characters sed reads as syntax there. A value spanning several lines is not supported —
# point ${PAYLOAD} at a script instead.
hs_escape_replacement() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//&/\\&}
  value=${value//|/\\|}
  printf '%s' "$value"
}

# A placeholder nobody filled would reach SLURM verbatim. Say so, on stderr, while still
# emitting the script — the caller may be rendering in stages.
hs_warn_unresolved() {
  local rendered; rendered=$(cat)
  printf '%s\n' "$rendered"
  local left; left=$(printf '%s\n' "$rendered" | grep -o '\${[A-Z_]*}' | sort -u | tr '\n' ' ')
  [ -n "$left" ] && hs_note "unresolved placeholders: $left (pass them as KEY=VALUE)"
  return 0
}

# Drop the #SBATCH lines a placeholder left empty, so an unset account or partition does
# not become a literal `--account=` that SLURM rejects.
hs_strip_empty_sbatch() { grep -v '^#SBATCH --[a-z-]*=[[:space:]]*$'; }

hs_submit_usage() { hs_die "usage: submit <script> [sbatch args...]"; }

# Copy a local job script to the cluster and submit it. A path that is not a local file
# is assumed to already live on the cluster.
hs_submit() {
  [ $# -ge 1 ] || hs_submit_usage
  local script="$1"; shift
  local remote="$script" workdir output
  if [ -f "$script" ]; then
    # Create the workdir and read it back in one round trip. Double quotes on purpose: the
    # REMOTE shell expands a workdir like /scratch/$USER, and only it can — since OpenSSH
    # 9.0 scp speaks SFTP and runs no remote shell, so an unexpanded $USER would reach the
    # copy verbatim and submit would fail on every current client.
    workdir=$(hs_run_sh "mkdir -p \"$HS_REMOTE_WORKDIR\" && printf 'hs_workdir=%s\n' \"$HS_REMOTE_WORKDIR\"" \
      | hs_parse_workdir) || hs_die "cannot create $HS_REMOTE_WORKDIR"
    [ -n "$workdir" ] || hs_die "could not resolve $HS_REMOTE_WORKDIR on $HS_HOST"
    remote=$(hs_remote_path "$workdir" "$script")
    hs_push "$script" "$remote" >/dev/null || hs_die "copying $script failed"
  fi
  # `sbatch $*` let the REMOTE shell re-parse every extra argument: double quotes do not
  # suppress command substitution there, and $* had already lost the argument boundaries.
  # README promises these reach sbatch "unchanged", and now they do.
  #
  # The script path is quoted too, so it is taken literally. HS_REMOTE_WORKDIR is the one
  # value still expanded by the cluster — deliberately, because it is where a `$USER` in a
  # profile has to be resolved, and only the far end can do that.
  output=$(hs_run_sh "cd \"$HS_REMOTE_WORKDIR\" && sbatch$(hs_shquote "$@" "$remote")") \
    || hs_die "sbatch failed: $output"
  local job_id; job_id=$(printf '%s\n' "$output" | hs_parse_job_id)
  # The job is QUEUED by now. Saying so matters: a caller that treats a non-zero submit as
  # "it did not happen" and retries would submit it twice.
  [ -n "$job_id" ] || hs_die "sbatch ran but printed no job id I could read, so the job may well be queued — check with 'hpc-session queue' before resubmitting. It said: $output"
  hs_valid_job_id "$job_id" || hs_die "sbatch printed something that is not a job id ('$job_id') — the job may be queued; check with 'hpc-session queue'. It said: $output"
  # Multi-cluster submission is out of scope: nothing else here passes -M, so the id would
  # be queried against the default cluster and quietly match nothing.
  case "$output" in
    *" on cluster "*)
      hs_note "sbatch reports job $job_id on another cluster — watch, fetch and cancel query $HS_HOST only" ;;
  esac
  hs_note "submitted job $job_id ($remote)"
  echo "$job_id"
}

# No width on the id. SLURM hard-cuts rather than eliding, so `%.10i` displayed the array
# task 12345678_10 as 12345678_1 — a valid id for a DIFFERENT task, which `cancel` would
# then have killed. A ragged column is the lesser problem.
hs_queue() { hs_run_sh "squeue -u \$USER -o '%i %.20j %.9T %.10M %.6D %R'"; }

# Ask the controller for a job's state, and prove it was actually asked.
#
#   status 0 — the job is in the queue; its state is on stdout
#   status 1 — the controller answered and the job is NOT in the queue: a real completion
#   status 2 — no usable answer; whatever the remote said is on stdout. Never a completion.
#
# Empty stdout used to be the entire completion signal, and empty stdout is also what a
# dropped master, a squeue hidden behind a module (127), an invalid job id (1), a
# restarting slurmctld and a csh login shell mangling `2>` all produce — every one of them
# reported as "job N left the queue", with exit 0 and output identical to the real thing.
#
# So the remote prints a SENTINEL carrying squeue's own status, and it is the sentinel's
# ABSENCE that separates "nobody answered" from "no such job in the queue". The state is
# tagged through squeue's own -o format for the same reason hs_parse_job_id and
# hs_parse_workdir exist: a login node's shell startup chatters over this same stdout.
#
# Deliberately signalled through the exit status: `state=$(hs_job_state …)` runs this in a
# subshell, where a variable it set would be discarded. Command substitution does propagate
# the status, so it is the only channel that survives how hs_watch invokes this.
hs_job_state() {
  local answer squeue_rc state
  # stderr is folded in and redirected LOCALLY, not with a `2>` inside the remote string:
  # the diagnostic is worth quoting back, and it should not be discarded on the cluster.
  answer=$(hs_run_sh "squeue -h -j '$1' -o 'hs_state:%T'; printf 'hs_squeue_rc:%s\n' \$?" 2>&1)
  squeue_rc=$(printf '%s\n' "$answer" | sed -n 's/^hs_squeue_rc://p' | tail -1)
  if [ -z "$squeue_rc" ] || [ "$squeue_rc" != 0 ]; then
    printf '%s\n' "$answer" | sed '/^hs_state:/d; /^hs_squeue_rc:/d'
    return 2
  fi
  state=$(printf '%s\n' "$answer" | sed -n 's/^hs_state://p' | tail -1)
  [ -n "$state" ] || return 1
  printf '%s\n' "$state"
}

# Does accounting say this job is OVER? Prints the state it saw, and returns 0 only then.
#
# Per ALLOCATION, not per job: `sacct -X -j <id>` prints one row for every task of an array
# and every component of a het job. Reading only the first row would call a three-task array
# finished the moment task 1 completed — and this is the fallback for the case where squeue
# has stopped answering, so it must not be weaker than the squeue path, which treats any
# task still listed as "still queued". Every row has to be terminal, and there has to be one.
#
# Tagged, like every other value this file reads back from the cluster: ssh runs the
# account's LOGIN shell, whose rc files print to this very stdout before the piped `sh` ever
# starts, so an untagged first line is the banner and not the answer. `2>/dev/null` sits in
# the REMOTE string, where it silences sacct alone — folding it in locally would swallow
# ssh's own diagnostics too.
hs_job_is_final() {
  local rows row seen=0 first=""
  rows=$(hs_run_sh "command -v sacct >/dev/null && sacct -n -X -P -j '$1' -o State 2>/dev/null \
    | sed 's/^/hs_final:/'" | sed -n 's/^hs_final://p')
  [ -n "$rows" ] || return 1
  # A here-doc, not a pipe: a pipe would run the loop in a subshell, where `return` decides
  # nothing and the whole guard would silently pass.
  while IFS= read -r row; do
    row=${row%% *}                      # "CANCELLED by 1234" -> CANCELLED
    [ -n "$row" ] || continue
    hs_state_is_final "$row" || return 1
    seen=1
    [ -n "$first" ] || first=$row
  done <<HS_ROWS
$rows
HS_ROWS
  [ "$seen" = 1 ] || return 1
  printf '%s\n' "$first"
}

# Is that outcome terminal? Listed positively, so a state this list has never heard of is
# treated as "still unknown" rather than silently as a finished job — which is the whole
# failure mode this file is guarding against.
hs_state_is_final() {
  case "${1:-}" in
    COMPLETED|FAILED|CANCELLED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|PREEMPTED|BOOT_FAIL|DEADLINE|REVOKED)
      return 0 ;;
    *) return 1 ;;
  esac
}

# sacct is not enabled on every site, so its absence must not look like a failure.
hs_job_accounting() {
  hs_run_sh "command -v sacct >/dev/null && sacct -j '$1' --format=JobID,JobName%20,State,Elapsed,MaxRSS 2>/dev/null || true"
}

# Poll until the job leaves the queue, then print what accounting knows about it.
#
# Polling holds the link. On a full-tunnel VPN, prefer `close` and come back later with
# `queue` for anything longer than a coffee.
#
# Exit status is the contract, because the caller may be an agent:
#   0 — the job left the queue. The only status that means "finished".
#   1 — refused, or lost track of the job. Its state is UNKNOWN, not final.
#   3 — stopped at the duration cap. The job is still queued and still running.
#
# The floor and the cap exist because docs/cluster-etiquette.md and SKILL.md state both as
# rules ("poll on the order of a minute, not a second"; "do not sit in watch for a job
# measured in hours") and nothing enforced either. `watch 12345 0` was a busy-wait against
# the controller, holding an authenticated master open, from a tool whose own documentation
# forbids it. A rule written in an agent-facing skill is a rule the agent will assume is
# enforced.
hs_watch() {
  [ -n "${1:-}" ] || hs_die "usage: watch <jobid> [interval_seconds]"
  hs_require_job_id "$1"
  local job_id="$1" interval="${2:-$HS_WATCH_INTERVAL}" state rc final misses=0
  local max_misses="$HS_WATCH_MAX_MISSES" cap="$HS_WATCH_MAX_SECONDS" started elapsed=0
  case "$interval" in
    ''|*[!0-9]*) hs_die "watch interval must be a whole number of seconds, not '$interval'" ;;
  esac
  # Say what was clamped. Silently obeying leaves the caller polling far harder than it
  # believes; silently ignoring leaves it believing a number that never took effect.
  if [ "$interval" -lt "$HS_WATCH_MIN_INTERVAL" ]; then
    hs_note "polling every ${HS_WATCH_MIN_INTERVAL}s, not ${interval}s — the floor is HS_WATCH_MIN_INTERVAL"
    interval="$HS_WATCH_MIN_INTERVAL"
  fi
  started=$(date +%s)
  while :; do
    state=$(hs_job_state "$job_id"); rc=$?
    case "$rc" in
      0) misses=0; hs_note "job $job_id: $state" ;;
      1) break ;;   # the controller answered, and the job is not in its queue
      *)
        misses=$((misses + 1))
        if [ "$misses" -ge "$max_misses" ]; then
          # Positive evidence, or nothing. Accounting reporting a TERMINAL state means the
          # controller has merely forgotten the job, which is what squeue does once a
          # finished job ages out. Anything else — including a job sacct still calls
          # RUNNING while squeue sits behind a module — is not a completion.
          if final=$(hs_job_is_final "$job_id"); then
            hs_note "squeue stopped answering for job $job_id, but accounting reports $final"
            break
          fi
          hs_die "lost track of job $job_id on $HS_HOST after $misses attempts — NOT reporting it finished. Last reply: ${state:-nothing}. Check with: hpc-session queue"
        fi
        hs_note "job $job_id: no usable answer from $HS_HOST ($misses/$max_misses): ${state:-no output}"
        ;;
    esac
    # Checked here rather than in the `while` condition so the cap can never cut short a
    # poll that was about to report a genuine completion.
    if [ "$cap" -gt 0 ]; then
      elapsed=$(( $(date +%s) - started ))
      if [ "$elapsed" -ge "$cap" ]; then
        hs_note "job $job_id is still queued after ${elapsed}s of polling, which is the HS_WATCH_MAX_SECONDS cap — stopping."
        hs_note "the job does not need you connected. Free the link with 'hpc-session close' and come back to 'hpc-session queue'."
        return 3
      fi
    fi
    sleep "$interval"
  done
  hs_note "job $job_id left the queue"
  # Explicitly 0: accounting is a courtesy, and its status — ssh's, if the master dropped
  # after the last poll — would otherwise become watch's, contradicting the rule that a
  # non-zero watch means the job's state is unknown.
  hs_job_accounting "$job_id"
  return 0
}

# Bring back everything the job wrote whose name carries the job id — which is what the
# %j in the template's --output/--error patterns produces.
hs_fetch() {
  [ -n "${1:-}" ] || hs_die "usage: fetch <jobid> [destination_dir]"
  hs_require_job_id "$1"
  local job_id="$1" dest="${2:-.}" files file
  mkdir -p "$dest" || hs_die "cannot write to $dest"
  # `find`, not `ls`: given a matching DIRECTORY, ls prints its contents as bare relative
  # names, which scp then resolves against the remote home instead of the workdir — quietly
  # fetching an unrelated file and reporting it as job output.
  #
  # `-H` because find otherwise lstats its own operand, so a workdir whose last component
  # is a symlink — `ln -s /scratch/$USER/jobs ~/jobs`, an ordinary layout — would never be
  # descended and every output would vanish. The glob this replaces resolved it silently.
  # `! -type d` rather than `-type f` so a symlinked output, which ls did return, still comes.
  files=$(hs_run_sh "find -H \"$HS_REMOTE_WORKDIR\" -maxdepth 1 ! -type d -name '*$job_id*' 2>/dev/null")
  [ -n "$files" ] || { hs_note "nothing matching '$job_id' in $HS_REMOTE_WORKDIR"; return 1; }
  # A here-doc, not a pipe: on the right of a pipe the loop runs in a subshell, so `failed`
  # would be discarded and the function's status would be the LAST copy's — every earlier
  # scp failure invisible in both the output and the exit code.
  local failed=0
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if hs_pull "$file" "$dest/" >/dev/null; then
      echo "$dest/$(basename "$file")"
    else
      failed=$((failed + 1))
      hs_note "could not fetch $file"
    fi
  done <<HS_FILES
$files
HS_FILES
  [ "$failed" = 0 ] || hs_die "$failed of the job's files could not be fetched"
}

hs_cancel() {
  [ -n "${1:-}" ] || hs_die "usage: cancel <jobid>"
  hs_require_job_id "$1"
  hs_run_sh "scancel '$1'" && hs_note "cancelled $1"
}
