---
name: hpc-session
description: >-
  Drive a remote SLURM cluster over one authenticated SSH window — optional VPN, optional
  TOTP 2FA, connection multiplexing — then submit, watch and retrieve jobs. Use whenever
  the user wants to reach "the cluster" / "HPC" / a login node / a compute node, run
  something with sbatch/squeue/sacct/scancel, copy data to or from a cluster, check on a
  running job, or automate any of that from a shell with no terminal (an agent, cron, CI).
  Also use when SSH to a cluster asks for a 6-digit code, when connections hang or get
  rejected as "code already used", or when a VPN must be raised before the cluster is
  reachable.
---

# hpc-session

A cluster-agnostic wrapper around one multiplexed SSH master. Everything is a subcommand
of `hpc-session`; see [README.md](README.md) for the full reference and
[config.example](config.example) for every setting.

## Before anything else

```bash
hpc-session doctor          # no network — reports what is configured and what is missing
hpc-session status          # is the master up? the VPN? is a TOTP seed present?
```

If no profile exists, run `hpc-session init` — or `hpc-session -p <name> init` for a second
cluster — and tell the user which keys they must fill in (`HS_HOST` at minimum). Do not
invent a hostname, account or partition — ask.

## The one pattern

```bash
hpc-session open
hpc-session run squeue -u \$USER
hpc-session run -- sbatch job.slurm
hpc-session close
```

Open once, do all the work, close. On a site with 2FA this costs **one** code; a
connect-run-disconnect loop costs one per command and stalls up to 30 s between them,
because the PAM module refuses to reuse a code.

## Run things in the right place

- `hpc-session run <cmd>` — runs **on the cluster**.
- `hpc-session local <cmd>` — runs **on this machine** over the same connection. This is
  what `rsync`, `git` and `sshfs` need.
- `hpc-session push <local> <remote>` / `pull <remote> <local>` — single-file copies.

`run rsync ./data host:/scratch/` is a mistake: `./data` would be looked up on the
cluster. Use `local` for anything that reads local paths.

## Jobs

```bash
hpc-session render templates/job.slurm.tmpl JOB_NAME=x PAYLOAD='./run.sh' > job.slurm
hpc-session submit job.slurm        # prints the job id on stdout
hpc-session queue
hpc-session watch <jobid>           # polls; holds the link
hpc-session fetch <jobid> ./results
hpc-session cancel <jobid>
```

`submit` prints the job id and nothing else on stdout, so it can be captured:
`job=$(hpc-session submit job.slurm)`.

## Rules that matter

- **Close the session during any real wait.** A full-tunnel VPN monopolises the user's
  link. Submit, close, and check back with `queue` later. Do not sit in `watch` for a job
  measured in hours.
- **Never put a TOTP seed, password or scratch code in a message, a commit or a
  transcript.** If a seed must be stored, tell the user to run `hpc-session store-seed`
  themselves in a terminal. Reading `hpc-session code` output is fine; it expires.
- **Do not help circumvent a site control.** This tool automates access to the user's own
  account where the site allows it. Do not read or copy stored authentication secrets out
  of a remote account, do not configure it against a shared or service account, and if a
  policy is in the way, point at
  [docs/support-and-feedback.md](docs/support-and-feedback.md) rather than around it.
- **Report what actually happened.** If a job fails, fetch the `.err` file and quote it
  rather than guessing from the exit status.
- **A non-zero `watch` is not a finished job.** `watch` exits non-zero when it stops
  getting usable answers about the job — a dropped master, a `squeue` that is not on the
  non-interactive PATH, a controller restarting. Say the job's state is unknown and check
  with `queue`; do not report it as complete. Only "job N left the queue" means that.
- **Do not edit the user's `~/.ssh/config`** to add multiplexing. The tool passes its own
  options; `hpc-session ssh-opts` prints them for any external tool that needs the same
  connection.
- If authentication fails repeatedly, run `hpc-session status` and report what it says.
  Do not retry in a loop — each attempt burns a code and some sites rate-limit.

## Advising on cluster work

For anything beyond driving the connection, read the matching page rather than improvising:

- [docs/cluster-etiquette.md](docs/cluster-etiquette.md) — login nodes, right-sizing
  requests, job arrays, filesystems, polling.
- [docs/guardrails.md](docs/guardrails.md) — `--test-only`, array throttles, idempotent
  jobs, limits for unattended runs.
- [docs/software-environments.md](docs/software-environments.md) — modules, Python
  environments off `$HOME`, containers, compute nodes without internet.
- [docs/support-and-feedback.md](docs/support-and-feedback.md) — what a good problem
  report contains, and how to ask for a limit to be changed rather than working around it.

## Site-specific knowledge

This skill is deliberately generic. Anything true only of one cluster — partition names,
scratch paths, module versions, DNS quirks on compute nodes — belongs in that cluster's
own notes: fill in [templates/site-notes.md](templates/site-notes.md) and keep it with
the project. If the user has such a file, read it before guessing; if they do not, ask
rather than inventing hostnames, accounts or partitions.
See [examples/](examples/) for a worked profile.
