# Two-factor authentication

Some clusters require a 6-digit TOTP code **in addition to** your SSH key, on every new
connection. This page covers enrolling once, letting `hpc-session` answer the prompt, and
what that costs you in security.

## Read this first

**Scope.** This is for automating access to **your own account, on a cluster whose
administrators have agreed to it**. Do not use it on shared, service or another person's
account, and do not use it to work around a control your site has not agreed to relax.
If you are not sure the site would agree, you do not yet have agreement — ask.

Storing a TOTP seed on the machine that also holds your SSH key puts **both factors on
one disk**. One file read then yields both. That is one-factor authentication wearing a
two-factor costume, and no amount of care in this tool changes it.

It is still the right call sometimes — unattended job submission has to authenticate
somehow. Make it deliberately, in this order:

1. **Ask for the supported path first** (below). Administrators can often solve this
   properly, and would much rather be asked than discover a workaround.
2. **Prefer the `command` backend** if you can generate codes from a hardware token or an
   external agent — then no seed is stored by this tool at all.
3. If you only ever run `hpc-session` at the keyboard, use `HS_OTP=123456 hpc-session open`
   and store nothing.
4. Only then consider a stored seed — and if you do, **encrypt your disk** and protect
   your SSH key with a passphrase held in an agent.

### The better ask — try this before storing anything

Send your administrator something like:

> Would it be possible to exempt the VPN subnet from `keyboard-interactive`
> authentication — a `Match Address` block restricting `AuthenticationMethods` to
> `publickey` — or to document an exception for unattended job submission? I automate
> SLURM submissions, and a 6-digit code cannot be typed by a non-interactive process.

That gives unattended access **without** collapsing your own second factor. If they
agree, set `HS_TOTP_BACKEND="none"` and delete the seed.

## 1. Enroll (needs a real terminal)

Enrollment is interactive, so it cannot be done from a tool without a TTY. In a normal
terminal:

```bash
ssh mycluster
```

On first login the site's enrollment tool draws a QR code and prints:

- `Your new secret key is: XXXXXXXXXXXXXXXX` — the **base32 seed**
- `Your emergency scratch codes are:` — one-time codes

**Capture both before closing the window.**

1. **Scan the QR with a phone app** (any authenticator). You want a factor that survives
   this laptop dying, and that you can use from other machines.
2. **Put the scratch codes in a password manager.** They are single-use and work in place
   of the code. Without them, a lost phone *and* a lost seed means only an administrator
   can restore your access.

If the window closed before you captured it, ask your administrator to re-enroll you.
Do not go looking for the stored secret: on most sites it sits in a file in your account,
and getting into the habit of reading it — or teaching a script to — is precisely the
habit that makes a second factor worthless.

## 2. Store the seed

Pick a backend in your profile and store it. **Do not paste a seed into a chat window or
an agent transcript** — type it into the tool directly, in a terminal.

| Backend | Set in the profile | Notes |
|---|---|---|
| `keychain` | `HS_TOTP_SERVICE`, `HS_TOTP_ACCOUNT` | macOS login Keychain. `store-seed` grants `security` standing access, so reads do not prompt — see SECURITY.md. Neither value may contain a double quote, a backslash or a newline. |
| `pass` | `HS_TOTP_PASS_ENTRY` | The standard unix password manager; GPG-encrypted at rest. |
| `file` | `HS_TOTP_FILE` | A mode-0600 file. Simplest, weakest. Never inside a repository. |
| `command` | `HS_TOTP_CMD` | Run anything that prints six digits, e.g. `oathtool --totp -b @~/.seed`, or a hardware token. Nothing is stored by this tool. |

```bash
hpc-session store-seed        # paste the base32 seed; it is not echoed
hpc-session code              # compare with your phone before trusting it
```

## 3. Daily use

```bash
hpc-session open              # one code, generated locally
hpc-session run squeue -u $USER
hpc-session run -- sbatch job.slurm
hpc-session close
```

One code per **window**, not per command. This is not an optimisation — it is required:
the PAM module refuses to reuse a code, so two separate logins inside the same 30-second
step would see the second rejected. Multiplexing authenticates once and reuses the
connection.

For that reason, avoid connect-run-disconnect in a loop. Two such cycles back to back
stall for up to 30 seconds waiting for a fresh step.

## 4. When it stops working

| Symptom | Cause | Fix |
|---|---|---|
| `auth failed … waiting Ns for a fresh code` | the previous code was already consumed | it retries by itself; wait one step |
| `could not open the master`, repeatedly | VPN down, or wrong seed | `hpc-session status`; compare `hpc-session code` with the phone |
| Commands hang instead of failing | stale socket after the tunnel dropped | `hpc-session close` then `open` (it also cleans up on its own) |
| Every code rejected | clock skew — TOTP is time-based | check the machine's clock is NTP-synced |
| Codes rejected only sometimes | your site may not use the default profile | set `HS_TOTP_DIGITS` / `HS_TOTP_PERIOD` / `HS_TOTP_ALGO` |
| Phone **and** seed lost | — | use an emergency scratch code, then contact your administrator |
