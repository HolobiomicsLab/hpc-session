# Profile loading and defaults.
#
# A profile is a shell fragment of KEY=value lines, sourced from
# ${HS_CONFIG_DIR}/<profile>.conf. Anything set in the environment beforehand wins,
# so one-off overrides need no edit: HS_HOST=other-cluster hpc-session status

HS_CONFIG_DIR="${HS_CONFIG_DIR:-$HOME/.config/hpc-session}"

hs_die()  { echo "hpc-session: $*" >&2; exit 1; }
hs_note() { echo "hpc-session: $*" >&2; }

hs_profile_path() { echo "$HS_CONFIG_DIR/${1}.conf"; }

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
  : "${HS_SLURM_ACCOUNT:=}"
  : "${HS_SLURM_PARTITION:=}"
  : "${HS_SLURM_TIME:=01:00:00}"
  : "${HS_SLURM_CPUS:=1}"
  : "${HS_SLURM_MEM:=4G}"
  : "${HS_SLURM_NODES:=1}"
  : "${HS_PYTHON:=python3}"
}

# Source the profile, then fill the gaps. Absent profile is fatal unless it is the
# built-in default one, which lets `hpc-session init` and `--help` work on a fresh box.
hs_load_profile() {
  HS_PROFILE="${HS_PROFILE:-default}"
  local path; path=$(hs_profile_path "$HS_PROFILE")
  if [ -f "$path" ]; then
    # shellcheck disable=SC1090  # user-owned config, sourced on purpose
    . "$path"
  elif [ "$HS_PROFILE" != default ]; then
    hs_die "no profile '$HS_PROFILE' at $path (run: hpc-session init $HS_PROFILE)"
  fi
  hs_apply_defaults
}

hs_require_host() {
  [ -n "$HS_HOST" ] || hs_die "HS_HOST is unset — run 'hpc-session init $HS_PROFILE' and set it"
}

hs_uses_vpn() { [ -n "$HS_VPN_UP_CMD" ]; }

# Copy the annotated example into the profile path, never clobbering an existing one.
hs_init_profile() {
  local path; path=$(hs_profile_path "$HS_PROFILE")
  [ -f "$path" ] && hs_die "$path already exists — edit it, or pick another profile name"
  mkdir -p "$HS_CONFIG_DIR" && chmod 700 "$HS_CONFIG_DIR"
  cp "$HS_ROOT/config.example" "$path" && chmod 600 "$path" || hs_die "could not write $path"
  echo "$path"
  hs_note "profile created — edit it, then run: hpc-session -p $HS_PROFILE doctor"
}
