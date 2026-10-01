# TOTP code generation and seed storage backends.
#
# The seed is a SECOND FACTOR. It is read straight into the generator on stdin, so it
# never appears in argv or the environment where `ps` could see it.

# RFC 6238 TOTP. Reads the base32 seed on stdin, prints one code.
# Parameters arrive as environment variables so the seed stays the only stdin payload.
# HS_TOTP_NOW overrides the clock — test seam, used by tests/run_tests.sh.
HS_TOTP_PY='
import sys, os, base64, hmac, hashlib, struct, time
seed = sys.stdin.read().strip().replace(" ", "").upper()
if not seed:
    sys.exit("empty seed")
seed += "=" * (-len(seed) % 8)
try:
    key = base64.b32decode(seed, casefold=True)
except Exception:
    sys.exit("seed is not valid base32")
# Checked rather than left to raise: an uncaught ValueError or AttributeError here is
# reported by hs_store_seed as "not a valid base32 TOTP seed", sending the user to inspect
# the one thing that was fine.
try:
    digits = int(os.environ.get("HS_TOTP_DIGITS") or 6)
    period = int(os.environ.get("HS_TOTP_PERIOD") or 30)
except ValueError:
    sys.exit("HS_TOTP_DIGITS and HS_TOTP_PERIOD must be whole numbers")
if digits < 1 or period < 1:
    sys.exit("HS_TOTP_DIGITS and HS_TOTP_PERIOD must be positive")
algo = (os.environ.get("HS_TOTP_ALGO") or "sha1").lower()
if algo not in ("sha1", "sha256", "sha512"):
    sys.exit("HS_TOTP_ALGO must be sha1, sha256 or sha512 (got %r)" % algo)
now = int(os.environ.get("HS_TOTP_NOW") or time.time())
mac = hmac.new(key, struct.pack(">Q", now // period), getattr(hashlib, algo)).digest()
offset = mac[-1] & 0x0F
truncated = struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7FFFFFFF
print(str(truncated % (10 ** digits)).zfill(digits))
'

# Seconds remaining in the current TOTP step.
hs_step_left() { echo $(( HS_TOTP_PERIOD - ($(date +%s) % HS_TOTP_PERIOD) )); }

# One read from the backend, with nothing hidden: the seed on stdout, the backend's own
# complaint, if any, on stderr.
hs_seed_fetch() {
  case "$HS_TOTP_BACKEND" in
    keychain) security find-generic-password -s "$HS_TOTP_SERVICE" -a "$HS_TOTP_ACCOUNT" -w ;;
    pass)     pass show "$HS_TOTP_PASS_ENTRY" | head -1 ;;
    file)     [ -f "$HS_TOTP_FILE" ] || { echo "no file at $HS_TOTP_FILE" >&2; return 1; }
              head -1 "$HS_TOTP_FILE" ;;
    *)        echo "backend '$HS_TOTP_BACKEND' stores no seed" >&2; return 1 ;;
  esac
}

# Print the stored base32 seed. Fails if the backend holds none, or will not hand it over.
#
# A failed read used to vanish: the backend's stderr went to /dev/null, and every caller then
# said "no seed — run store-seed", even when the seed was stored and the keychain had merely
# refused this one request. That pointed the user at re-enrolling a second factor that was
# fine, and left a refusal that came and went with nothing to diagnose it from. Now the
# backend's message is appended to HS_TOTP_ERROR_LOG, and the read is tried once more after
# HS_TOTP_READ_RETRY_DELAY seconds, which absorbs a refusal that clears by itself.
#
# Only stderr is ever written down. stdout IS the seed: it is held in a local variable and
# handed on with `printf`, a builtin, so it still reaches no argv, no environment and no file.
#
# No second attempt after a cancelled prompt, which would ask a user who just said no again,
# nor for a file that does not exist, which a few seconds will not create.
hs_seed_read() {
  local attempt seed rc err_file delay="${HS_TOTP_READ_RETRY_DELAY:-2}"
  case "$delay" in ''|*[!0-9]*) delay=2 ;; esac
  for attempt in 1 2; do
    err_file=$(mktemp "${TMPDIR:-/tmp}/hsseed.XXXXXX") || return 1
    seed=$(hs_seed_fetch 2>"$err_file"); rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$seed" ]; then
      rm -f "$err_file" "$(hs_seed_error_log).last"
      printf '%s\n' "$seed"
      return 0
    fi
    seed=""
    hs_seed_error_record "$attempt" "$rc" "$err_file"
    rm -f "$err_file"
    [ "$attempt" = 1 ] || return 1
    case "$HS_TOTP_BACKEND:$HS_SEED_LAST_ERROR" in
      file:*|*[Cc]ancel*) return 1 ;;
    esac
    sleep "$delay"
  done
  return 1
}

hs_seed_error_log() {
  echo "${HS_TOTP_ERROR_LOG:-${HS_CONFIG_DIR:-$HOME/.config/hpc-session}/${HS_PROFILE:-default}.totp-errors.log}"
}

# Append one line per failed read: when, which backend, which attempt, its exit status, the
# macOS session the read ran in, and what the backend said. The latest message is also kept
# beside the log, so the hint printed by open, doctor and status can repeat it; a read that
# succeeds removes it.
#
# The session matters for the keychain. `security` started outside the logged-in GUI
# session cannot show a prompt, so a keychain that would ask the user refuses instead — one
# way a read can work from a terminal and fail from an agent at the same moment.
hs_seed_error_record() {  # attempt, exit status, file holding the backend's stderr
  local why log session=""
  why=$(tr '\n' ' ' < "$3" | sed 's/  */ /g; s/ $//' | cut -c1-300)
  [ -n "$why" ] || why="the backend printed nothing and gave no reason"
  HS_SEED_LAST_ERROR="$why"
  if [ "$HS_TOTP_BACKEND" = keychain ] && command -v launchctl >/dev/null 2>&1; then
    session=" session=$(launchctl managername 2>/dev/null || echo unknown)"
  fi
  log=$(hs_seed_error_log)
  ( umask 077
    mkdir -p "$(dirname "$log")" \
      && printf '%s %s attempt=%s exit=%s%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           "$HS_TOTP_BACKEND" "$1" "$2" "$session" "$why" >> "$log" \
      && printf '%s\n' "$why" > "$log.last" ) 2>/dev/null
  return 0
}

# Can this profile produce a code at all? Asked before the VPN goes up, so a failure is
# cheap rather than stranding the link.
#
# The `command` backend has no stored seed *by design* — it shells out to a user-supplied
# generator. Routing it through hs_seed_read, whose `case` has no `command` arm, meant it
# fell to `*) return 1` and always answered "no seed"; hs_open_session then refused before
# ssh was ever attempted. The whole documented backend could not open a session.
hs_have_seed() {
  [ -n "${HS_OTP:-}" ] && return 0
  [ "$HS_TOTP_BACKEND" = command ] && { [ -n "$HS_TOTP_CMD" ]; return; }
  hs_seed_read | grep -q . 2>/dev/null
}

# Why this profile cannot produce a code, phrased for the setting that is actually missing.
#
# Shared by open, doctor and status because bin/hpc-session documents `doctor` as the last
# step of setup: telling a `command` user to run `store-seed` — for a backend that stores
# nothing, and whose store-seed exits 1 saying exactly that — left them with no way forward
# until they reached `open`, which is the one place the right message used to live.
#
# When the last read left a reason behind, that reason leads. "No seed" is only one of the
# ways a read fails; the keychain refusing this one request is another, and re-enrolling
# does nothing for it.
hs_seed_hint() {
  local last log
  log=$(hs_seed_error_log)
  if [ "$HS_TOTP_BACKEND" = command ]; then
    echo "HS_TOTP_CMD is empty — set it to a command that prints one code"
  elif last=$(cat "$log.last" 2>/dev/null) && [ -n "$last" ]; then
    echo "the seed in '$HS_TOTP_BACKEND' could not be read: $last (history in $log; if no seed was ever stored, run: hpc-session store-seed)"
  else
    echo "no seed in '$HS_TOTP_BACKEND' and no HS_OTP — run: hpc-session store-seed"
  fi
}

hs_seed_to_code() {
  HS_TOTP_DIGITS="$HS_TOTP_DIGITS" HS_TOTP_PERIOD="$HS_TOTP_PERIOD" HS_TOTP_ALGO="$HS_TOTP_ALGO" \
    "$HS_PYTHON" -c "$HS_TOTP_PY"
}

# Print the code for right now, from whichever backend is configured.
hs_code() {
  [ -n "${HS_OTP:-}" ] && { printf '%s\n' "$HS_OTP"; return 0; }
  case "$HS_TOTP_BACKEND" in
    none)    return 1 ;;
    command) eval "$HS_TOTP_CMD" ;;
    *)       hs_seed_read | hs_seed_to_code ;;
  esac
}

hs_seed_store_backend() {
  local seed="$1"
  case "$HS_TOTP_BACKEND" in
    # `security -i` reads its COMMAND from stdin, so the seed travels on a pipe instead of
    # in argv. Passing it as `-w "$seed"` put the permanent second factor in the process
    # argument list for the duration of the exec — visible to `ps` for any process running
    # as this user, and, worse, recorded durably by any EDR/audit agent that logs exec
    # arguments. That contradicted this file's own opening claim, and SECURITY.md's.
    #
    # `-w` with no value is NOT the fix: it consumes the next argument as the password
    # rather than reading stdin, so it silently stores the wrong thing.
    #
    # The seed itself is safe between those quotes: hs_store_seed has already stripped
    # whitespace and proved the value base32-decodes, and [A-Z2-7=] contains no quote.
    # The two identifiers have no such guarantee, and `security -i` re-tokenises the line
    # with its own quote handling, so a quote in either would inject further options into
    # a command that runs against the user's keychain — where argv made them inert tokens.
    # A NEWLINE counts: `security -i` executes one command per line, so a value carrying one
    # does not merely inject options, it appends a whole second command. A single quote does
    # not: both values land inside "%s" fields, where security's parser reads it literally.
    #
    # Refused rather than escaped: `security`'s parser is not documented well enough to
    # invent an escaping scheme against, and no real service or account name needs any of
    # these characters.
    keychain)
      local nl=$'\n'
      case "$HS_TOTP_SERVICE$HS_TOTP_ACCOUNT" in
        *[\"\\]*|*"$nl"*) hs_die "HS_TOTP_SERVICE and HS_TOTP_ACCOUNT must not contain a double quote, a backslash or a newline" ;;
      esac
      printf 'add-generic-password -U -s "%s" -a "%s" -l "%s TOTP seed" -T /usr/bin/security -w "%s"\n' \
        "$HS_TOTP_SERVICE" "$HS_TOTP_ACCOUNT" "$HS_TOTP_SERVICE" "$seed" | security -i ;;
    pass)     printf '%s\n' "$seed" | pass insert -m -f "$HS_TOTP_PASS_ENTRY" >/dev/null ;;
    # umask governs CREATION only. An HS_TOTP_FILE that already existed at 0644 kept its
    # mode, and the seed was written into it — a permanent second factor, world-readable.
    file)     (umask 077; printf '%s\n' "$seed" > "$HS_TOTP_FILE") && chmod 600 "$HS_TOTP_FILE" ;;
    *)        hs_die "backend '$HS_TOTP_BACKEND' stores no seed (use keychain, pass or file)" ;;
  esac
}

# Read a seed from the terminal (or stdin when piped) and hand it to the backend.
hs_store_seed() {
  local seed
  if [ -t 0 ]; then
    read -r -s -p "Paste the base32 TOTP seed (not echoed): " seed; echo >&2
  else
    read -r seed
  fi
  seed=$(printf '%s' "$seed" | tr -d '[:space:]')
  [ -n "$seed" ] || hs_die "empty seed"
  # Keep the generator's own complaint. Discarding it reported every failure as a bad seed,
  # including "HS_TOTP_ALGO must be sha1, sha256 or sha512" — which is not about the seed
  # at all, and sends the user to re-enrol for nothing.
  local why
  why=$(printf '%s' "$seed" | hs_seed_to_code 2>&1 >/dev/null) \
    || hs_die "${why:-not a valid base32 TOTP seed}"
  hs_seed_store_backend "$seed" || hs_die "storing the seed failed"
  unset seed
  hs_note "seed stored via backend '$HS_TOTP_BACKEND'"
  hs_note "current code: $(hs_code) — check it against your phone app now"
}
