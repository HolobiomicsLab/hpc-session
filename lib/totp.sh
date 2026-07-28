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
digits = int(os.environ.get("HS_TOTP_DIGITS") or 6)
period = int(os.environ.get("HS_TOTP_PERIOD") or 30)
algo = (os.environ.get("HS_TOTP_ALGO") or "sha1").lower()
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

hs_have_seed() { [ -n "${HS_OTP:-}" ] && return 0; hs_seed_read | grep -q . 2>/dev/null; }

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
    keychain) security add-generic-password -U -s "$HS_TOTP_SERVICE" -a "$HS_TOTP_ACCOUNT" \
                -l "$HS_TOTP_SERVICE TOTP seed" -T /usr/bin/security -w "$seed" ;;
    pass)     printf '%s\n' "$seed" | pass insert -m -f "$HS_TOTP_PASS_ENTRY" >/dev/null ;;
    file)     (umask 077; printf '%s\n' "$seed" > "$HS_TOTP_FILE") ;;
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
  printf '%s' "$seed" | hs_seed_to_code >/dev/null 2>&1 || hs_die "not a valid base32 TOTP seed"
  hs_seed_store_backend "$seed" || hs_die "storing the seed failed"
  unset seed
  hs_note "seed stored via backend '$HS_TOTP_BACKEND'"
  hs_note "current code: $(hs_code) — check it against your phone app now"
}
