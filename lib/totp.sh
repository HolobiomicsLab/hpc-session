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

# Print the stored base32 seed. Fails if the backend holds none.
hs_seed_read() {
  case "$HS_TOTP_BACKEND" in
    keychain) security find-generic-password -s "$HS_TOTP_SERVICE" -a "$HS_TOTP_ACCOUNT" -w 2>/dev/null ;;
    pass)     pass show "$HS_TOTP_PASS_ENTRY" 2>/dev/null | head -1 ;;
    file)     [ -f "$HS_TOTP_FILE" ] && head -1 "$HS_TOTP_FILE" ;;
    *)        return 1 ;;
  esac
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
hs_seed_hint() {
  if [ "$HS_TOTP_BACKEND" = command ]; then
    echo "HS_TOTP_CMD is empty — set it to a command that prints one code"
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
