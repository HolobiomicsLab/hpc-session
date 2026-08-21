# Changelog

## 0.1.0 — 2026-08-21

First tagged release. The repository has been public since late July 2026 and there was
no tag before this one, so anyone who cloned in between holds a copy with the defects
listed under **Fixed** — several of which are silent. Upgrading is worth it.

Two audits, in July and August, produced the work below. Every fix carries a test, and
each test was checked against the specific defect it guards rather than only against the
previous state of `main`. The suite went from 37 assertions to 194.

### Changed — read before upgrading

- **`submit`'s extra arguments are quoted** and no longer re-parsed by the remote shell.
  `README` always promised they reached `sbatch` unchanged; they now do. An argument that
  relied on remote expansion (a `$VAR`, a backtick) will stop expanding.
- **A remote script path given to `submit` is literal.** `HS_REMOTE_WORKDIR` is still
  expanded by the cluster, deliberately — it is where a profile's `$USER` has to resolve.
- **`watch` clamps its interval** to `HS_WATCH_MIN_INTERVAL` (30 s) and stops at
  `HS_WATCH_MAX_SECONDS` (one hour), saying so in both cases.
- **`watch` has a third exit status.** `0` finished, `1` unknown, **`3` stopped at the cap
  with the job still queued**. Only `0` means the job is done.
- **`queue` prints the whole job id.** The column is ragged now; it used to be truncated,
  which turned the array task `12345678_10` into `12345678_1` — a valid id for a
  different task.
- **`watch`, `fetch`, `cancel` and `submit` reject anything that is not a job id**, before
  it reaches a remote command line.
- **The no-argument subcommands reject trailing arguments.** `open -p bigiron` used to
  open the *default* cluster while appearing to select a profile, and spend a code on it.
- **`local` no longer claims to help `sshfs`**, which reads neither `RSYNC_RSH` nor
  `GIT_SSH_COMMAND`. Use `-o ssh_command="ssh $(hpc-session ssh-opts)"`.
- **A VPN configured with `HS_VPN_STATUS_CMD` alone is recognised**, which is the shape
  `docs/vpn-hooks.md` recommends for a tunnel you raise yourself. It previously reported
  as "not configured".
- **The tool's own remote commands run under `sh`**, whatever login shell the account
  uses. `hpc-session run` is untouched: that is your command line.

### Added

- **CI.** The suite runs on Linux and on macOS's `/bin/bash` 3.2 — the real floor this
  tool is written to — plus `shellcheck`.
- **`hpc-session templates`**, and `render <name>` resolved against `HS_TEMPLATE_DIR`, so
  a skill that owns a job type can own its job shape without hardcoding a path into this
  repository. `SKILL.md` states the contract across that seam.
- `HS_WATCH_INTERVAL`, `HS_WATCH_MIN_INTERVAL`, `HS_WATCH_MAX_SECONDS`,
  `HS_WATCH_MAX_MISSES`, `HS_TEMPLATE_DIR`.
- `SLURM_NTASKS` as a template placeholder. It was hard-coded to 1 while `--nodes` was a
  placeholder, so any `HS_SLURM_NODES` above 1 allocated nodes that then sat idle.
- **`hpc-session version`**, also reported by `doctor`. It answers before the profile
  loads, so a broken setup can still say which copy it is; a test holds it equal to the
  newest heading in this file.
- A second worked example profile, for the ordinary key-only cluster.

### Fixed

- **`watch` reported a running job as finished** whenever a remote query failed with
  anything other than ssh's own 255 — an invalid job id, a `squeue` behind a module, a
  restarting controller, a `csh` login shell. The output was identical to a real
  completion. It now requires positive evidence that the controller was reached.
- **Configuration precedence was inverted.** The profile was sourced last, so every
  documented one-off override (`HS_HOST=other hpc-session status`) was silently discarded.
- **The shipped `HS_REMOTE_WORKDIR` broke `submit` on every OpenSSH ≥ 9.0 client**, which
  speaks SFTP and runs no remote shell to expand `$USER`.
- **`fetch` could deliver an unrelated file** from the remote home: `ls -1` on a matching
  *directory* prints its contents as bare relative names. It also skipped a workdir whose
  last component was a symlink, reporting "nothing matching" — which reads as "the job
  wrote nothing".
- **`fetch` returned 0 on a partial retrieval.** Its status was the last copy's.
- **`init` could not create a profile named with `-p`**, the only selector `README`
  documents, and the error's own suggested remedy failed when `HS_PROFILE` was exported.
- **The `command` TOTP backend could not open a session at all** — it was asked for a
  stored seed it has none of by design.
- **A bad key under `AuthenticationMethods publickey,keyboard-interactive`** was retried
  three times over ~90 s instead of failing at once.
- **A local code-generation failure waited out three full time steps** for something that
  could never change, judging a stale error string.
- **A failed control-directory `mkdir` was swallowed**, so the session opened and simply
  never multiplexed — which looks like a slow cluster, not a broken setup.
- **A mistyped `HS_TOTP_ALGO` or `HS_TOTP_PERIOD` was reported as an invalid seed**,
  sending the user to re-enrol over a typo.
- **`--help` printed executable code**, having sliced a line range that had drifted.
- `sbatch`'s federated message form made `submit` return the **cluster name** as the job
  id; `--parsable` made it fail *after* the job was queued.
- `config.example` omitted `HS_CONTROL_DIR`, `HS_CONFIG_DIR` and `HS_OTP`. A test now
  holds every default to appearing there.
- Four documentation claims the code did not honour, including two in `SECURITY.md`.

### Security

- **The TOTP seed no longer passes through `argv`** on the keychain path, where `ps` and
  any exec-logging agent could see it. It travels on stdin.
- **A live code no longer survives a signal.** A trap removes the temporary file on
  `EXIT`, `INT`, `TERM` and `HUP`; previously a Ctrl-C between writing it and `ssh`
  reading it left a valid second factor on disk with nothing left to delete it.
- **The keychain identifiers are refused if they contain a quote, a backslash or a
  newline.** `security -i` re-tokenises the storing command and runs one command per line,
  so either could inject options — or a whole second command — into something running
  against the user's keychain.
- **The `file` backend enforces mode 0600** on an existing file. `umask` governs creation
  only, so a seed written into a file that was already 0644 stayed world-readable.
- `SECURITY.md` now records what `-T /usr/bin/security` costs: any process running as you
  can read the seed back without a prompt, which is what makes unattended `open` work.

### Known limitations

- `README` states OpenSSH 6.7+, which is correct for multiplexing. The unattended TOTP
  path additionally needs `SSH_ASKPASS_REQUIRE`, which is newer
  ([#13](https://github.com/HolobiomicsLab/hpc-session/issues/13)). A caller with a
  terminal is unaffected.
- Multi-cluster (federated) submission is out of scope. `submit` says so when `sbatch`
  reports another cluster.
- Everything above is verified offline, against stubs. No part of this release has been
  exercised against a live SLURM controller.
