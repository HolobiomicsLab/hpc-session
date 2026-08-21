# Profile loading and defaults.
#
# A profile is a shell fragment of KEY=value lines, sourced from
# ${HS_CONFIG_DIR}/<profile>.conf. Anything set in the environment beforehand wins,
# so one-off overrides need no edit: HS_HOST=other-cluster hpc-session status

HS_CONFIG_DIR="${HS_CONFIG_DIR:-$HOME/.config/hpc-session}"

hs_die()  { echo "hpc-session: $*" >&2; exit 1; }
hs_note() { echo "hpc-session: $*" >&2; }

hs_profile_path() { echo "$HS_CONFIG_DIR/${1}.conf"; }

# Serialise the HS_* variables the caller put in the environment, as statements that
# restore them. Only EXPORTED names are captured, which is precisely what "the environment"
# means: a library assigning HS_SSH_ERROR at source time is not in it.
#
# Names come from `compgen -e` and values are quoted with `%q`, one statement per line.
# Filtering the text of `export -p` instead would split a multi-line value — an
# HS_VPN_UP_CMD spanning two lines is ordinary — leaving an unterminated quote that makes
# `eval` abandon every override after it, silently.
#
# `export`, not `declare -x`: `declare` inside a function creates a FUNCTION-LOCAL
# variable, so the replay would restore nothing and the bug this guards against would
# come back unnoticed.
#
# An empty value counts as unset, which is how `:=` in hs_apply_defaults already treats
# one; otherwise a bare `HS_HOST= hpc-session ...` would blank the profile's host.
hs_env_overrides() {
  local name
  for name in $(compgen -e); do
    case "$name" in HS_*) ;; *) continue ;; esac
    [ -n "${!name}" ] || continue
    printf 'export %s=%q\n' "$name" "${!name}"
  done
  return 0
}

# Defaults for every key a profile may set. Applied after the profile is sourced,
# so a profile only states what it changes.
hs_apply_defaults() {
  : "${HS_HOST:=}"
  : "${HS_CONTROL_DIR:=$HOME/.ssh/hpc-session}"
  : "${HS_CONTROL_PERSIST:=8h}"
  : "${HS_CONNECT_TIMEOUT:=25}"
  : "${HS_AUTH_ATTEMPTS:=3}"
  : "${HS_VPN_UP_CMD:=}"
  : "${HS_VPN_DOWN_CMD:=}"
  : "${HS_VPN_STATUS_CMD:=}"
  : "${HS_TOTP_BACKEND:=none}"
  : "${HS_TOTP_SERVICE:=hpc-session-totp}"
  : "${HS_TOTP_ACCOUNT:=$HS_PROFILE}"
  : "${HS_TOTP_PASS_ENTRY:=hpc-session/$HS_PROFILE}"
  : "${HS_TOTP_FILE:=$HS_CONFIG_DIR/$HS_PROFILE.seed}"
  : "${HS_TOTP_CMD:=}"
  : "${HS_TOTP_DIGITS:=6}"
  : "${HS_TOTP_PERIOD:=30}"
  : "${HS_TOTP_ALGO:=sha1}"
  : "${HS_REMOTE_WORKDIR:=.}"
  # Where `render <name>` looks. Point it at another skill's assets and that skill owns its
  # own job shapes without owning any paths — see "Composing with other skills" in SKILL.md.
  : "${HS_TEMPLATE_DIR:=${HS_ROOT:-.}/templates}"
  # Polling limits. The floor and the cap are the enforcement of what
  # docs/cluster-etiquette.md and SKILL.md already state as rules; see hs_watch.
  : "${HS_WATCH_INTERVAL:=30}"
  : "${HS_WATCH_MIN_INTERVAL:=30}"
  : "${HS_WATCH_MAX_SECONDS:=3600}"
  : "${HS_WATCH_MAX_MISSES:=3}"
  : "${HS_SLURM_ACCOUNT:=}"
  : "${HS_SLURM_PARTITION:=}"
  : "${HS_SLURM_TIME:=01:00:00}"
  : "${HS_SLURM_CPUS:=1}"
  : "${HS_SLURM_MEM:=4G}"
  : "${HS_SLURM_NODES:=1}"
  : "${HS_SLURM_NTASKS:=1}"
  : "${HS_PYTHON:=python3}"
}

# Source the profile, replay the environment over it, then fill the gaps — the documented
# precedence of environment > profile > defaults. Absent profile is fatal unless it is the
# built-in default one, which lets `--help` work on a fresh box.
#
# The replay is what makes the precedence real. A profile is a shell fragment of plain
# assignments, so sourcing it overwrites whatever the caller exported; `hs_apply_defaults`
# cannot undo that, because `:=` skips any name the profile has just set.
hs_load_profile() {
  HS_PROFILE="${HS_PROFILE:-default}"
  local path overrides
  path=$(hs_profile_path "$HS_PROFILE")
  overrides=$(hs_env_overrides)
  if [ -f "$path" ]; then
    # shellcheck disable=SC1090  # user-owned config, sourced on purpose
    . "$path"
  elif [ "$HS_PROFILE" != default ]; then
    hs_die "no profile '$HS_PROFILE' at $path (run: hpc-session init $HS_PROFILE)"
  fi
  eval "$overrides"
  hs_apply_defaults
}

hs_require_host() {
  [ -n "$HS_HOST" ] || hs_die "HS_HOST is unset — run 'hpc-session init $HS_PROFILE' and set it"
}

# Is a VPN part of this profile at all? Keyed off either hook, not only the one that
# raises it: docs/vpn-hooks.md explicitly recommends setting HS_VPN_STATUS_CMD alone for a
# tunnel you keep up yourself, and that configuration made every VPN report read
# "not configured" — the user's own status command was never run.
hs_uses_vpn() { [ -n "$HS_VPN_UP_CMD" ] || [ -n "$HS_VPN_STATUS_CMD" ]; }

# Copy the annotated example into the profile path, never clobbering an existing one.
hs_init_profile() {
  local path; path=$(hs_profile_path "$HS_PROFILE")
  [ -f "$path" ] && hs_die "$path already exists — edit it, or pick another profile name"
  mkdir -p "$HS_CONFIG_DIR" && chmod 700 "$HS_CONFIG_DIR"
  cp "$HS_ROOT/config.example" "$path" && chmod 600 "$path" || hs_die "could not write $path"
  echo "$path"
  hs_note "profile created — edit it, then run: hpc-session -p $HS_PROFILE doctor"
}
