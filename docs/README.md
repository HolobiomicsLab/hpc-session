# Working with a cluster — start here

`hpc-session` is a small tool for reaching a SLURM cluster. Most of what makes cluster
work go well is not the tool, though — it is knowing your site, staying inside sensible
limits, and talking to the people who run the machine. That is what these pages are for.

| Page | Read it when |
|---|---|
| [cluster-etiquette.md](cluster-etiquette.md) | before your first real job — the habits that keep a shared machine usable |
| [guardrails.md](guardrails.md) | before scaling up, or automating anything unattended |
| [software-environments.md](software-environments.md) | you need a tool, a library or a Python environment on the cluster |
| [support-and-feedback.md](support-and-feedback.md) | you are stuck, something is broken, or you want a policy changed |
| [vpn-hooks.md](vpn-hooks.md) | your cluster is only reachable through a VPN |
| [2fa-enrollment.md](2fa-enrollment.md) | your cluster asks for a 6-digit code on every connection |
| [../templates/site-notes.md](../templates/site-notes.md) | fill it in once per cluster; it answers most future questions for you |

## Know your site first

Every cluster differs in the details that matter: partition names, walltime ceilings,
memory per core, which filesystem is purged and when, whether there is a transfer host,
how software is provided, and who to ask. **None of it is guessable, and all of it is
documented by your site.** Find these before anything else:

- the site's user documentation and its acceptable-use policy;
- the partitions and limits you may use (`sinfo -o "%20P %10l %10L %6D %C"`, and
  `sacctmgr show associations user=$USER` for your own allocation);
- the filesystems, their quotas, and their purge policy (`quota`, or the site's own tool);
- how software is provided — modules (`module avail`), containers, or your own builds;
- the support channel and its hours (see [support-and-feedback.md](support-and-feedback.md)).

Write the answers into [templates/site-notes.md](../templates/site-notes.md) and keep it
next to your project. Six months later it is the difference between a two-minute job and
an afternoon of rediscovery — and it is what a new colleague needs on day one.

## The short version

- The login node is a doorway, not a computer. Run work through the scheduler.
- Ask for the resources you measured, not the ones that feel safe.
- Test on one sample, then scale — with a throttle.
- Keep job I/O off your home directory; keep your only copy off scratch.
- Do not poll the queue in a tight loop. Submit, disconnect, come back.
- Read the `.err` file before resubmitting.
- When you ask for help, bring the job id, the script, and the error.

## External resources

Starting points that are not site-specific:

- **SLURM documentation** — <https://slurm.schedmd.com/documentation.html>; in
  particular [`sbatch`](https://slurm.schedmd.com/sbatch.html),
  [job arrays](https://slurm.schedmd.com/job_array.html) and
  [`sacct`](https://slurm.schedmd.com/sacct.html).
- **HPC Carpentry** — <https://www.hpc-carpentry.org/> — lesson material for people new
  to clusters, aimed at researchers rather than system administrators.
- **Apptainer** — <https://apptainer.org/docs/> — containers on HPC, where sites allow
  them; usually the cleanest answer to "my software will not build here".
- **Spack** — <https://spack.readthedocs.io/> and **EasyBuild** —
  <https://docs.easybuild.io/> — how many sites build their module trees, and how to
  build your own without fighting the system compiler.
- **OpenSSH `ssh_config`** — <https://man.openbsd.org/ssh_config> — the `ControlMaster`,
  `ControlPath` and `ControlPersist` options this tool is built on.

Your site's own documentation outranks every link above.
