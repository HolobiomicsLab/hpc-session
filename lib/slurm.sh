# SLURM helpers. Every one of them rides the master opened by session.sh, so a whole
# submit/watch/fetch cycle costs at most one authentication.

# Extract the job id from sbatch's chatter ("Submitted batch job 12345").
hs_parse_job_id() { awk '/Submitted batch job/{print $NF; exit}'; }

hs_remote_path() { echo "$HS_REMOTE_WORKDIR/$(basename "$1")"; }

# Substitute the documented ${PLACEHOLDER}s in a job template. Extra KEY=VALUE pairs
# become extra substitutions, so a template can carry job-specific fields too.
hs_render() {
  local template="$1"; shift
  [ -f "$template" ] || hs_die "no such template: $template"
  local expressions=() pair key value
  for pair in \
    "SLURM_ACCOUNT=$HS_SLURM_ACCOUNT" "SLURM_PARTITION=$HS_SLURM_PARTITION" \
    "SLURM_TIME=$HS_SLURM_TIME" "SLURM_CPUS=$HS_SLURM_CPUS" "SLURM_MEM=$HS_SLURM_MEM" \
    "SLURM_NODES=$HS_SLURM_NODES" "REMOTE_WORKDIR=$HS_REMOTE_WORKDIR" "$@"; do
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
  local remote="$script" output
  if [ -f "$script" ]; then
    remote=$(hs_remote_path "$script")
    # Double quotes on purpose: the REMOTE shell must expand a workdir like /scratch/$USER.
    hs_run "mkdir -p \"$HS_REMOTE_WORKDIR\"" || hs_die "cannot create $HS_REMOTE_WORKDIR"
    hs_push "$script" "$remote" >/dev/null || hs_die "copying $script failed"
  fi
  output=$(hs_run "cd \"$HS_REMOTE_WORKDIR\" && sbatch $* \"$remote\"") || hs_die "sbatch failed: $output"
  local job_id; job_id=$(printf '%s\n' "$output" | hs_parse_job_id)
  [ -n "$job_id" ] || hs_die "could not read a job id from: $output"
  hs_note "submitted job $job_id ($remote)"
  echo "$job_id"
}

hs_queue() { hs_run "squeue -u \$USER -o '%.10i %.20j %.9T %.10M %.6D %R'"; }

# The state SLURM reports for a job on stdout; the TRANSPORT's status as the exit code.
#
# Callers must read both. Empty stdout means "not in the queue" only when the exit status
# says the question was actually answered — a dropped master, an unreachable controller or
# a mistyped job id all produce empty stdout too. `watch` used to read empty as proof of
# completion, so an agent whose connection died was told its job had finished and stopped
# looking at work that may still have been running.
#
# Deliberately not a global: `state=$(hs_job_state ...)` runs this in a subshell, where any
# variable it sets is discarded. Command substitution does propagate the exit status, so
# the status is the only channel that survives the way callers actually invoke this.
hs_job_state() { hs_run "squeue -h -j '$1' -o '%T' 2>/dev/null"; }

# sacct is not enabled on every site, so its absence must not look like a failure.
hs_job_accounting() {
  hs_run "command -v sacct >/dev/null && sacct -j '$1' --format=JobID,JobName%20,State,Elapsed,MaxRSS 2>/dev/null || true"
}

# Poll until the job leaves the queue, then print what accounting knows about it.
#
# Polling holds the link. On a full-tunnel VPN, prefer `close` and come back later with
# `queue` for anything longer than a coffee.
hs_watch() {
  [ -n "${1:-}" ] || hs_die "usage: watch <jobid> [interval_seconds]"
  local job_id="$1" interval="${2:-30}" state rc
  while :; do
    state=$(hs_job_state "$job_id"); rc=$?
    # 255 is ssh's own "I could not run anything" — the master went away, the VPN dropped,
    # the host became unreachable. Never a statement about the job, so never a completion.
    [ "$rc" -eq 255 ] && hs_die \
      "lost the connection to $HS_HOST while watching job $job_id — not reporting it finished. Reopen and 'watch $job_id' again."
    [ -n "$state" ] || break
    hs_note "job $job_id: $state"
    sleep "$interval"
  done
  hs_note "job $job_id left the queue"
  hs_job_accounting "$job_id"
}

# Bring back everything the job wrote whose name carries the job id — which is what the
# %j in the template's --output/--error patterns produces.
hs_fetch() {
  [ -n "${1:-}" ] || hs_die "usage: fetch <jobid> [destination_dir]"
  local job_id="$1" dest="${2:-.}" files file
  mkdir -p "$dest" || hs_die "cannot write to $dest"
  files=$(hs_run "ls -1 \"$HS_REMOTE_WORKDIR\"/*$job_id* 2>/dev/null")
  [ -n "$files" ] || { hs_note "nothing matching '$job_id' in $HS_REMOTE_WORKDIR"; return 1; }
  printf '%s\n' "$files" | while IFS= read -r file; do
    [ -n "$file" ] || continue
    hs_pull "$file" "$dest/" >/dev/null && echo "$dest/$(basename "$file")"
  done
}

hs_cancel() {
  [ -n "${1:-}" ] || hs_die "usage: cancel <jobid>"
  hs_run "scancel '$1'" && hs_note "cancelled $1"
}
