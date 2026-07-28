# Security

## Reporting a vulnerability

Please report suspected vulnerabilities privately, through GitHub's
[private vulnerability reporting](https://github.com/HolobiomicsLab/hpc-session/security/advisories/new)
on this repository, rather than in a public issue. Include what you found, how to
reproduce it, and what an attacker would gain. We will confirm receipt and keep you
updated on the fix.

Please do **not** test findings against a cluster you are not authorised to test.

## Scope, and what this tool is for

`hpc-session` automates access to **your own account**, on clusters whose administrators
are willing for you to do so. It is not a way around a control your site has not agreed
to relax, and it should not be configured against shared, service or third-party
accounts. If a policy blocks legitimate work, ask for it to be changed — see
[docs/support-and-feedback.md](docs/support-and-feedback.md).

## What the tool does with secrets

It never handles your SSH key; that stays with `ssh` and your agent. It only touches a
TOTP seed if you configure a backend that stores one.

- **The seed is never stored by the tool itself** unless you run `store-seed`. Backends
  are the macOS Keychain, `pass`, a mode-0600 file, or an external command that prints a
  code (in which case nothing is stored here).
- **The seed never appears in `argv` or the environment.** It is piped into the code
  generator on stdin, so `ps` cannot see it.
- **The generated code** is written to a `mktemp` file (mode 0600) and read exactly once:
  the askpass helper prints it and deletes it. That single-shot behaviour is deliberate —
  a helper that kept answering would let `ssh` retry a stale code in a loop.
- **Profiles** are created mode 0600 in a 0700 directory, and `.gitignore` excludes
  `*.conf` and `*.seed` so a profile or a seed cannot be committed by accident.
- **Nothing is sent anywhere.** There is no telemetry and no network access beyond the
  `ssh` connection you asked for.

## Known trade-offs

These are properties of the design, not bugs. They are documented so you can decide.

- **A stored seed weakens two-factor authentication.** Keeping it on the machine that
  also holds your SSH key means one file read yields both factors. Read
  [docs/2fa-enrollment.md](docs/2fa-enrollment.md) before choosing a storage backend; the
  `command` backend and the `HS_OTP` variable both avoid storing anything.
- **Profiles are sourced as shell.** A profile can run arbitrary code, by design — that
  is what makes the VPN hooks work with any client. Treat a profile like a script: do not
  run one you did not write.
- **The control socket is a live, authenticated connection.** Anyone who can write to
  your `HS_CONTROL_DIR` as your user can use it without authenticating. The directory is
  created 0700; on a shared machine, keep it on local disk, and `close` when you are done.
- **`HS_TOTP_CMD` and the VPN hooks are executed.** They come from your own profile, but
  it means an attacker who can edit your profile can run code as you — the same exposure
  as your shell startup files.

## Supported versions

The `main` branch is the supported version.
