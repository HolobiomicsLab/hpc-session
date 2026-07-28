# Using a shared cluster well

A cluster is a shared instrument. Almost everything that annoys administrators and
slows down your colleagues comes from a handful of habits, and all of them are easy to
avoid once you know them.

**Your site's own documentation and policies always win over this page.** Read them
first; this is the general shape of good behaviour, not a substitute.

## The login node is not a compute node

It is a doorway: edit files, submit jobs, move data, inspect results. Nothing more.
Running an analysis, a compilation marathon or a big archive extraction there degrades
the machine for everyone trying to get in, and many sites will kill the process — or
your session — without warning.

If you need a shell on real hardware to test something, ask the scheduler for one:

```bash
hpc-session run -- salloc --time=00:30:00 --cpus-per-task=4
```

## Ask for what you need, then check what you used

Over-requesting is the most common waste. A job asking for 64 cores and 500 GB waits
far longer in the queue, and if it uses four cores and 8 GB, the rest sat idle while
someone else's job waited.

Measure instead of guessing. After a representative job finishes:

```bash
hpc-session run -- sacct -j <jobid> --format=JobID,State,Elapsed,MaxRSS,AllocCPUS
hpc-session run -- seff <jobid>        # where the site provides it
```

Then set `HS_SLURM_CPUS`, `HS_SLURM_MEM` and `HS_SLURM_TIME` in your profile from what
you actually measured, with a sensible margin.

The same applies to walltime. A short, honest time limit gets your job **backfilled**
into gaps the scheduler cannot otherwise use — asking for 7 days "to be safe" can mean
waiting days for a job that runs in an hour.

## Test small before you scale

Run one sample, one file, one chromosome, on a short partition, and read the output.
A typo discovered by 500 failed array tasks costs the queue far more than it costs you.

## Many similar jobs: use an array

A loop that calls `sbatch` a thousand times gives the scheduler a thousand independent
problems and often trips submission-rate limits. A job array is one submission the
scheduler understands as a family:

```bash
#SBATCH --array=1-500%20     # 500 tasks, at most 20 running at once
INPUT=$(sed -n "${SLURM_ARRAY_TASK_ID}p" filelist.txt)
```

The `%20` throttle is good manners on a busy machine, and often required.

## Put data where it belongs

Sites differ, but the pattern is nearly universal:

| Location | For | Not for |
|---|---|---|
| `home` | code, scripts, small configs; usually backed up, small quota | job I/O, thousands of small files |
| `scratch` / `work` | active job data; large, fast, **usually purged** | anything you cannot regenerate |
| node-local disk (`$TMPDIR`) | temporary files a single job writes and rereads | anything needed after the job ends |

Two specific habits matter most on a shared parallel filesystem: keep intense
small-file I/O off it — write to node-local disk and copy the result back at the end —
and never leave your only copy of anything on a purged filesystem.

Set `HS_REMOTE_WORKDIR` to a scratch path, not to your home directory.

## Do not hammer the scheduler

`squeue` in a tight loop is a surprisingly effective way to slow down the controller
for every user on the machine. Poll on the order of a minute, not a second.

```bash
hpc-session watch <jobid> 60      # the interval is yours to choose; default 30 s
```

For anything longer than a coffee, do not poll at all: submit, close the session, and
check back later.

```bash
hpc-session submit job.slurm
hpc-session close
# ... later ...
hpc-session queue
```

Better still, let the scheduler tell you: `--mail-type=END,FAIL` in the job script, or
chain dependent work with `--dependency=afterok:<jobid>` instead of waiting by hand.

## Free the link during waits

If you reach the cluster through a **full-tunnel** VPN, the tunnel monopolises your
connection while it is up — you may lose access to everything else, including other
machines you need. Jobs keep running whether or not you are connected; only your
monitoring needs the link, and only briefly.

So: `open`, a burst of work, `close`. `hpc-session close` drops the SSH master and the
VPN together. Services reachable over ordinary HTTPS — a git forge, an object store —
usually need no VPN at all; check before assuming.

## Move data deliberately

- Use the site's dedicated transfer host if there is one; login nodes are not built for
  sustained throughput.
- `rsync` over `scp` for anything large: it resumes, and it will not re-send what is
  already there. `hpc-session local rsync -a --partial ./data/ mycluster:/scratch/...`
- Compress before transferring, and prefer one archive to a hundred thousand small files.
- Move data once. Copying the same dataset per job wastes the filesystem everyone shares.

## Clean up after yourself

Delete scratch directories when a project ends, and have jobs remove their own temporary
files — a `trap 'rm -rf "$TMPDIR/work"' EXIT` in the job script survives most failures.
Cancel jobs you no longer need rather than letting them run to the wall clock:

```bash
hpc-session cancel <jobid>
```

## Software

Use the site's modules and containers before installing anything yourself. If you do
need your own environment, put it where the site tells you to, and prefer one shared
environment per project over one per person. Compiling large toolchains belongs in a
job, not on the login node.

## When something breaks

Read the job's own output before resubmitting — that is what `fetch` is for:

```bash
hpc-session fetch <jobid> ./results
```

`sacct` distinguishes the common endings: `OUT_OF_MEMORY` needs more memory, `TIMEOUT`
needs more walltime, `FAILED` means your program returned non-zero and the `.err` file
will say why. Resubmitting unchanged rarely helps.

When you do need the administrators, make it easy for them: the job id, the submission
script, the error output, and what you already tried. They cannot guess any of it, and a
well-formed question is usually answered the same day.

## Be a good neighbour

- Announce large campaigns before you launch them, especially near deadlines.
- Do not work around a queue limit by fragmenting a job; the limit is someone's fair
  share, and administrators do notice.
- Acknowledge the facility in your papers if it asks you to — that funding is what keeps
  the machine you are using alive.
