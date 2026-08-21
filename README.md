# hpc-session

[![tests](https://github.com/HolobiomicsLab/hpc-session/actions/workflows/tests.yml/badge.svg)](https://github.com/HolobiomicsLab/hpc-session/actions/workflows/tests.yml)

One authenticated window to a SLURM cluster — for a person at a keyboard, and for a
script or an agent that has no keyboard at all.

`hpc-session` opens a single multiplexed SSH master connection, bringing a VPN up first
if your site needs one and answering a TOTP prompt if your site enforces two-factor
authentication. Every later command, file copy and job submission rides that one
connection and authenticates again **not at all**.

It exists because three ordinary site policies compose badly:

- **Per-connection 2FA.** `pam_google_authenticator` refuses to reuse a code. Two fresh
  logins inside one 30-second step and the second is rejected — so a script that runs
  `ssh`, then `scp`, then `sbatch` stalls or fails halfway.
- **No controlling terminal.** A cron job, a CI runner or a coding agent cannot type six
  digits into a prompt. `ssh` will happily take them from a *program* instead, which is
  the mechanism this tool is built around.
- **Full-tunnel VPNs.** While the tunnel is up it monopolises the link. Anything that
  keeps it up "just in case" quietly costs you every other remote connection.

## Requirements

`bash`, `ssh` (OpenSSH 6.7+, for the `%C` control path), and `python3` — the last one
only if your cluster uses TOTP. No other dependencies. Tested on macOS and Linux.

## Install

```bash
git clone https://github.com/HolobiomicsLab/hpc-session.git ~/git/hpc-session
ln -sf ~/git/hpc-session/bin/hpc-session ~/bin/hpc-session   # anywhere on $PATH
hpc-session init                                             # writes ~/.config/hpc-session/default.conf
$EDITOR ~/.config/hpc-session/default.conf                   # at minimum, set HS_HOST
hpc-session doctor                                           # checks everything, touches no network
```

`HS_HOST` is best set to an `ssh_config` Host alias, so your key, user and any jump host
stay in `~/.ssh/config` where every other tool can see them too:

```
Host mycluster
    HostName login.cluster.example.edu
    User yourlogin
```

You do **not** need to add `ControlMaster` lines to `~/.ssh/config` — `hpc-session`
passes its own multiplexing options on every call. For an external tool that must share
the same connection, hand it `$(hpc-session ssh-opts)`.

## Use

```bash
hpc-session open                          # VPN up + one authenticated master
hpc-session run squeue -u \$USER           # runs ON the cluster
hpc-session run -- sacct -j 12345
hpc-session close                         # drop master + VPN, freeing the link
```

`open` … `run` … `run` … `close` is the pattern that matters. Everything between the
first and last call is free.

### Running things, in the right place

The distinction that bites people:

| Command | Runs where | Use for |
|---|---|---|
| `hpc-session run <cmd>` | on the cluster | `squeue`, `sbatch`, `ls`, a compute job |
| `hpc-session local <cmd>` | on your machine, over the shared connection | `rsync`, `git` |
| `hpc-session push <local> <remote>` | copy up | one file |
| `hpc-session pull <remote> <local>` | copy down | one file |

`run rsync ./data host:/scratch/` would look for `./data` **on the cluster** and fail.
That is what `local` is for:

```bash
hpc-session local rsync -a ./data/ mycluster:/scratch/$USER/data/
```

`local` works by exporting `RSYNC_RSH` and `GIT_SSH_COMMAND`, so it helps exactly the
tools that read them. A tool that takes its transport some other way needs to be told
directly — `sshfs`, for instance, reads neither, and would otherwise open a second
connection, which under 2FA costs a second code:

```bash
sshfs -o ssh_command="ssh $(hpc-session ssh-opts)" mycluster:/scratch/$USER ~/mnt
```

### SLURM

```bash
hpc-session templates                     # job types this installation can render
hpc-session render job JOB_NAME=align PAYLOAD='./run.sh in.fa' > job.slurm
hpc-session submit job.slurm              # copies it up, sbatch, prints the job id
hpc-session queue                         # your jobs
hpc-session watch 12345                   # poll until it leaves the queue
hpc-session fetch 12345 ./results         # bring back everything named after the job id
hpc-session cancel 12345
```

`submit` copies a local script to `HS_REMOTE_WORKDIR` and submits it there; a path that
is not a local file is taken to be already on the cluster, and used literally. Extra
arguments go to `sbatch` unchanged — properly quoted, so a space or a `$` in one reaches
`sbatch` as you wrote it: `hpc-session submit job.slurm --dependency=afterok:12344`.

A job id is checked before it becomes part of a remote command line, so `watch`, `fetch`
and `cancel` refuse anything that is not one. `submit` applies the same check to what
`sbatch` printed, and if the reply is unreadable it says the job may nonetheless be
queued — resubmitting on a non-zero exit is how you end up running it twice.

`render` takes either a path or a bare **name**, which it resolves to
`$HS_TEMPLATE_DIR/<name>.slurm.tmpl` (`templates/` by default). The name form is what lets
something else own a job type without owning a path — see *Use as a Claude Code skill*
below. Template placeholders come from your profile, and any extra `KEY=VALUE` argument
becomes another substitution. The shipped template is a single-node job by default; `SLURM_NTASKS`
is a placeholder, and a job that asks for more than one node has to launch its own work
(`PAYLOAD='srun ./run.sh'`), because the script body runs on the first node only. A placeholder left empty removes its whole `#SBATCH` line, so an
unset account does not become an `--account=` that SLURM rejects. Keep `%j` in the
`--output`/`--error` patterns — that is how `fetch` finds the files.

`watch` never reports a completion it cannot evidence. It stops only when the controller
answers that the job is not in the queue — or, if the queries themselves start failing,
when `sacct` reports a state that is actually terminal. When neither happens it exits
non-zero saying so, rather than printing the same "left the queue" line a real completion
would print. A dropped connection, a `squeue` behind a module and a mistyped job id all
used to be indistinguishable from a finished job.

Its exit status is the contract, which matters most when the caller is a script:

| | |
|---|---|
| `0` | the job left the queue — the only status that means finished |
| `1` | refused, or lost track of the job: its state is **unknown**, not final |
| `3` | stopped at `HS_WATCH_MAX_SECONDS`; the job is still queued and still running |

**On a full-tunnel VPN, do not leave `watch` running for a long job.** Close the session
and come back to `hpc-session queue` later; the job does not care whether you are
connected. That is a limit the tool now keeps rather than merely recommends: polling has a
floor (`HS_WATCH_MIN_INTERVAL`, 30 s) and the whole watch has a cap
(`HS_WATCH_MAX_SECONDS`, an hour). Ask for something tighter and `watch` says what it
clamped instead of silently obeying or silently ignoring you.

## Working with a cluster

The tool is the easy part. [`docs/`](docs/README.md) is the entry point for the rest:
knowing your site, staying inside sensible limits, installing software, and talking to
the people who run the machine.

| | |
|---|---|
| [Cluster etiquette](docs/cluster-etiquette.md) | the habits that keep a shared machine usable |
| [Guardrails](docs/guardrails.md) | limits and safety nets, especially for unattended runs |
| [Software and environments](docs/software-environments.md) | modules, Python, R, containers, building your own |
| [Support and feedback](docs/support-and-feedback.md) | which channel, what to include, how to ask for a policy change |
| [Site notes template](templates/site-notes.md) | fill in once per cluster; answers most future questions |

## Profiles

One file per cluster in `~/.config/hpc-session/`, selected with `-p`:

```bash
hpc-session -p bigiron init          # create it
hpc-session -p bigiron open
hpc-session -p bigiron submit job.slurm
```

Every key is documented in [`config.example`](config.example). Anything already set in
the environment wins over the file, so one-off overrides need no edit:

```bash
HS_HOST=other-login hpc-session status
HS_SLURM_PARTITION=gpu hpc-session render templates/job.slurm.tmpl JOB_NAME=x PAYLOAD='./run.sh'
```

An empty value counts as unset, the same way an empty key in the profile falls back to the
default, so an empty override falls back to the profile rather than clearing it.

Note which command reads what: the `HS_SLURM_*` keys are consumed by `render`, when it
fills in a template. `submit` sends the script exactly as it stands on disk, so overriding
`HS_SLURM_PARTITION` around a `submit` changes nothing — pass the flag to `sbatch` instead,
which `submit` forwards unchanged: `hpc-session submit job.slurm --partition=gpu`.

## VPN

Any VPN works, because the hooks are just shell commands — `HS_VPN_UP_CMD`,
`HS_VPN_DOWN_CMD`, and `HS_VPN_STATUS_CMD` (which must exit 0 when the tunnel is up).
Leave them empty if your cluster is reachable directly. Setting `HS_VPN_STATUS_CMD` alone
is a supported shape, for a tunnel you raise yourself: the tool then reports the tunnel's
state and refuses to open while it is down, rather than trying to raise it. Worked examples for Cisco Secure
Client, WireGuard, OpenVPN and Tailscale are in [docs/vpn-hooks.md](docs/vpn-hooks.md).

## Two-factor authentication

Set `HS_TOTP_BACKEND` to `none` (the default, key-only login) or to one of `keychain`,
`pass`, `file`, `command`. Enrollment, daily use and failure modes are in
[docs/2fa-enrollment.md](docs/2fa-enrollment.md).

**Read that page before storing a seed.** A TOTP seed on the same disk as your SSH key
means one file read yields both factors — it is one-factor authentication wearing a
two-factor costume. Sometimes that trade is worth it for unattended automation;
it should never be made by accident. The `command` backend exists so you can keep the
seed in a hardware token or an external agent and never store it here at all.

### Responsible use

This tool automates access to **your own account, on clusters whose administrators are
willing for you to do so**. It is not a way around a control your site has not agreed to
relax, and it has no business on a shared, service or third-party account. If a policy
is blocking legitimate work, the productive move is to ask for it to be changed — the
wording that tends to work is in
[docs/support-and-feedback.md](docs/support-and-feedback.md).

What the tool does with a seed it holds: reads it straight into the generator on stdin,
so it never appears in `argv` or the environment where `ps` could see it; writes the
generated code to a mode-0600 temporary file that the askpass helper destroys after a
single read. That helper is deliberately single-shot — if it kept answering, a stale
code would make `ssh` re-invoke it in a loop and hang for minutes.

[SECURITY.md](SECURITY.md) states this in full, along with the known trade-offs and how
to report a vulnerability.

## Tests

```bash
tests/run_tests.sh
```

Offline and fast — no cluster, no network, no credential store. What cannot be run for
real is stubbed (`ssh`, `scp`, `squeue`, `sacct`, `security`) and the assertion is on what
the tool *asked* them to do.

CI runs the same suite on Linux and on macOS, the latter under the `/bin/bash` Apple
ships — version 3.2, which is the floor this tool is written to.

## Limitations

- One master per host alias. Two profiles pointing at the same alias share it.
- `render` substitutes single-line values only; give `${PAYLOAD}` a script for anything
  longer.
- `fetch` matches regular files directly in `HS_REMOTE_WORKDIR` whose name contains the
  job id. A job that writes into a per-job *directory*, or names its outputs otherwise,
  needs `pull`. It prints the files it retrieved and exits non-zero if any copy failed —
  a partial retrieval is not a success.
- `sacct` is absent on some sites; `watch` then prints nothing after the job ends, and
  loses the fallback it would otherwise use to confirm a completion `squeue` stopped
  answering for. On such a site a `watch` that loses its answers fails rather than
  guessing, which is the intended direction.
- The tool's own remote commands run under `sh` on the cluster, whatever login shell the
  account uses. `hpc-session run` is left alone: that is your command line, and it belongs
  to your login shell.
- Multi-cluster (federated) submission is out of scope. `submit` reads the job id out of
  either form of `sbatch`'s reply, but nothing here passes `-M`, so `watch`, `fetch` and
  `cancel` query `HS_HOST` only. When `sbatch` reports another cluster, `submit` says so.
- `HS_REMOTE_WORKDIR` is expanded by the cluster, which is what makes a `$USER` in it work.
  A remote script path given to `submit` is not: it is passed literally.

## Use as a Claude Code skill

`SKILL.md` at the repository root makes this directory usable as a skill, so an agent
picks the right subcommand and respects the etiquette rules:

```bash
ln -s ~/git/hpc-session ~/.claude/skills/hpc-session
```

It is deliberately a **transport** skill: it owns the connection and the job lifecycle, and
knows nothing about what a job computes. A skill that owns a job *type* — an annotation
tool, an aligner, a simulation — sits on top and keeps the science, delegating the
connection here. Neither has to know about the other in advance; both are selected from
their own description, in the ordinary way.

What the one on top needs is a job shape, and it should not have to hardcode a path to get
one. Ship `<jobtype>.slurm.tmpl` in your own assets and point `HS_TEMPLATE_DIR` at them:

```bash
HS_TEMPLATE_DIR=~/git/my-skill/assets hpc-session render myjob JOB_NAME=x PAYLOAD='./run.sh'
```

`SKILL.md` states the rest of the contract — open once, capture the job id from `submit`'s
stdout, read `watch`'s exit status, and keep site facts in that cluster's notes rather than
in either skill.

## Contributing

Issues and pull requests are welcome, particularly worked profiles for other clusters
(as `examples/<site>.conf`, with placeholders instead of real logins) and VPN hooks for
clients not yet covered. Please keep `tests/run_tests.sh` green and add a case for any
behaviour you change — CI runs it on Linux and on macOS's bash 3.2, plus `shellcheck`.

## Authors

Developed at the [HolobiomicsLab](https://github.com/HolobiomicsLab) — CNRS and
Université Côte d'Azur.

## License

MIT — see [LICENSE](LICENSE). Copyright CNRS and Université Côte d'Azur.
