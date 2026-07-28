# Guardrails

Etiquette is what you intend to do. Guardrails are what saves you when you are tired,
in a hurry, or automating something that will run while you sleep. Set them once.

The theme throughout: **make the small mistake cheap, and make the large one impossible.**

## Before you scale

| Guardrail | How |
|---|---|
| Validate the script without running it | `hpc-session run -- sbatch --test-only job.slurm` |
| Run one item before five hundred | submit with `--array=1-1`, read the output, then widen |
| Cap how much of the queue you occupy | `--array=1-500%20` — at most 20 tasks at once |
| Submit held, release when you are sure | `sbatch --hold`, then `scontrol release <jobid>` |
| Stop the chain when a step fails | `--dependency=afterok:<jobid>` rather than `afterany` |
| Never rerun a failed job unchanged | read the `.err` first: `hpc-session fetch <jobid>` |

## Inside the job script

```bash
set -euo pipefail                      # stop at the first error, not the last
trap 'rm -rf "$TMPDIR/work"' EXIT      # clean up even when the job fails
```

Four more that repay themselves quickly:

- **Fail fast on missing inputs.** A guard at the top (`[ -f "$INPUT" ] || exit 1`) beats
  a job that runs for six hours and writes an empty result.
- **Write to node-local disk, copy back at the end.** Intense small-file I/O on a shared
  parallel filesystem is slow for you and for everyone else.
- **Never write into the directory you are reading from** when tasks run in parallel;
  give each array task its own output path.
- **Make the job idempotent** — safe to rerun. If it appends to a file or increments a
  counter, a requeue after a node failure will quietly corrupt your results.

## Resource limits are a safety net, not a wish

Ask for what you measured (`sacct --format=MaxRSS,Elapsed`, or `seff`), plus a margin.
Two failure modes to keep apart:

- **Too little memory** → the job is killed as `OUT_OF_MEMORY`. Loud, quick, harmless.
- **Too much of everything** → the job waits in the queue, occupies resources it does not
  use, and eats your fair share. Quiet, slow, expensive.

A walltime you honestly expect to need is a guardrail in both directions: it lets the
scheduler backfill you into gaps, and it caps the damage of a job stuck in a loop.

## Automation and unattended runs

Anything that runs without you watching needs stricter limits than anything you supervise.

- **Bound the blast radius.** A submission loop should know its own maximum: a counter, a
  `%N` array throttle, or a check of `squeue -u $USER | wc -l` before submitting more.
- **Never retry authentication in a loop.** Each attempt burns a one-time code and many
  sites rate-limit or lock the account. `hpc-session` retries a consumed code a bounded
  number of times (`HS_AUTH_ATTEMPTS`) and fails immediately on a network or key error.
- **Close the session when idle.** `HS_CONTROL_PERSIST` bounds how long a forgotten master
  lingers; on a full-tunnel VPN keep it short.
- **Log what was submitted**, with job ids, somewhere you will find it later. An
  unattended run you cannot reconstruct is not reproducible, whatever else it is.
- **Give the automation its own scratch directory** so a bad cleanup cannot reach data you
  care about.

## Data guardrails

- Keep your only copy off any purged filesystem. Scratch is a workbench, not an archive.
- Prefer `rsync -a --partial` to `scp` for large transfers: it resumes and does not resend.
- Use `--dry-run` before any `rsync` that deletes (`--delete`), and before any recursive
  removal. Type the path twice rather than once with a wildcard.
- Check your quota before a large run, not after it fails halfway.

## Guardrails against yourself

The most expensive mistakes are the confident ones. Two habits help more than any flag:

- **Write down the command you are about to run at scale**, then read it once more. Most
  catastrophic deletions are a correct command aimed at the wrong path.
- **Ask before working around a limit.** If a queue limit, a quota or an authentication
  requirement is in your way, the administrators would rather hear about your use case
  than discover the workaround. See
  [support-and-feedback.md](support-and-feedback.md).
