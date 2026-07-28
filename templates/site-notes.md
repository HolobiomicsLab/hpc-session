# Site notes — <CLUSTER NAME>

Fill this in once, keep it with the project, and hand it to the next person. Everything
here is site-specific and none of it is guessable; the site's own documentation is the
source for all of it.

Last checked: <DATE> by <NAME>

## Access

| | |
|---|---|
| Login host | `<login.cluster.example.edu>` |
| My login | `<username>` |
| `hpc-session` profile | `<name>` (`~/.config/hpc-session/<name>.conf`) |
| VPN required? | `<no / yes — which client, split or full tunnel>` |
| Two-factor? | `<no / yes — TOTP, per connection or per day>` |
| Transfer host | `<none / transfer.cluster.example.edu>` |
| Jump host | `<none / bastion.example.edu>` |

## Allocation

| | |
|---|---|
| Account / project code | `<account>` |
| Who approves changes | `<name / team>` |
| Renewal or reporting date | `<date>` |
| How usage is charged | `<core-hours / node-hours / fair share only>` |

```bash
sacctmgr show associations user=$USER format=Account,Partition,MaxJobs,GrpTRES
```

## Partitions and limits

| Partition | Max walltime | Nodes / cores | Memory per node | Use for |
|---|---|---|---|---|
| `<name>` | `<hh:mm:ss>` | | | |
| `<name>` | | | | |

```bash
sinfo -o "%20P %10l %6D %8c %10m %N"
```

Queue limits that apply to me: `<max running jobs, max submitted, max array size>`

## Filesystems

| Path | Purpose | Quota | Backed up? | Purged? |
|---|---|---|---|---|
| `<$HOME>` | code, configs | | | never |
| `<scratch>` | job I/O | | no | `<after N days>` |
| `<project/work>` | shared data | | | |
| `<$TMPDIR>` | node-local temp | | no | at job end |

Quota check command: `<site tool>`

`HS_REMOTE_WORKDIR` in my profile points at: `<path>`

## Software

| | |
|---|---|
| Module system | `<Lmod / environment modules>` |
| Hierarchical? | `<yes — load compiler + MPI first / no>` |
| Containers | `<Apptainer allowed? version? any restrictions>` |
| Conda / Python | `<site module? where environments should live>` |
| Do compute nodes have internet? | `<no — pre-download caches / yes>` |
| GPU nodes | `<partition, GPU model, CUDA modules>` |

Modules this project pins:

```
module purge
module load <...>
```

## Support

| | |
|---|---|
| Ticket system | `<URL or address>` |
| Mailing list / forum | |
| Chat | |
| Status page | |
| Office hours | |
| Acknowledgement text for papers | `<exact wording the site asks for>` |

## Local quirks

Things that cost someone a day to discover. Write them down as you hit them — this
section is the reason the file is worth keeping.

- `<e.g. compute nodes cannot resolve external hostnames; pre-fetch everything>`
- `<e.g. the default module version changed on DATE; pin it>`
- `<e.g. small-file I/O on the shared filesystem is very slow; stage to $TMPDIR>`
