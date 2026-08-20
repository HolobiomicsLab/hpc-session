# VPN hooks

`hpc-session` does not know anything about VPNs. It calls three shell commands from your
profile:

| Key | Must do | Must return |
|---|---|---|
| `HS_VPN_UP_CMD` | bring the tunnel up | non-zero on failure |
| `HS_VPN_DOWN_CMD` | take it down | ignored |
| `HS_VPN_STATUS_CMD` | say whether it is up | **exit 0 when connected**, non-zero otherwise |

Leave `HS_VPN_UP_CMD` empty if your cluster is reachable directly — everything else then
behaves as if no VPN existed.

Before raising the tunnel, the tool checks that it can *produce* a TOTP code — that a
seed is readable, or that `HS_TOTP_CMD` is set. It does not attempt an authentication:
under a full tunnel the login node is usually not reachable until the tunnel is up, so
there is nothing to authenticate against yet.

The check is worth having anyway, because a missing seed is the common failure and it
costs nothing to catch it early: a full-tunnel VPN monopolises the link, so failing
*after* connecting would strand your other remote access for no reason. It is not a
guarantee that the login will succeed. A wrong seed, an unenrolled account or a bad key
still fails after the tunnel is up.

## Etiquette on a full tunnel

While the tunnel is up you may lose every other remote connection. Keep the window short
— `open`, a burst of work, `close` — and close the session during any real wait. See
[cluster-etiquette.md](cluster-etiquette.md#free-the-link-during-waits).

## Worked examples

### Cisco Secure Client / AnyConnect

The CLI binary reads its answers from stdin. Keep the password out of the profile — read
it from your own secret store.

```sh
HS_VPN_UP_CMD='printf "connect vpn.example.edu\n%s\n%s\ny\n" "$VPN_USER" "$(security find-generic-password -s vpn -a "$VPN_USER" -w)" | /opt/cisco/secureclient/bin/vpn -s >>"$HOME/.vpn-connect.log" 2>&1'
HS_VPN_DOWN_CMD='/opt/cisco/secureclient/bin/vpn disconnect'
HS_VPN_STATUS_CMD='/opt/cisco/secureclient/bin/vpn state 2>/dev/null | grep -qi "state: connected"'
```

Two details worth keeping: read the password from a secret store rather than writing it
into the profile, and send the client's output to a **private** file. A world-readable
path such as `/tmp/vpn.log` on a multi-user machine hands your username and the site's
gateway to anyone who looks — and a failed login sometimes echoes more than that.

If a GUI client holds the connection lock, the CLI reports it as unavailable; quit the
GUI application first.

### WireGuard

```sh
HS_VPN_UP_CMD='sudo wg-quick up cluster'
HS_VPN_DOWN_CMD='sudo wg-quick down cluster'
HS_VPN_STATUS_CMD='sudo wg show cluster >/dev/null 2>&1'
```

`sudo` will prompt, which defeats unattended use. Granting yourself a passwordless rule
is a real privilege decision, not a detail: if you do it, scope it to exactly these two
commands with full paths and fixed arguments, never to `wg-quick` in general, and never
to a wrapper script you can edit — that is equivalent to giving yourself root. Better,
where your platform allows it, is to let the network stack bring the interface up without
`sudo` at all.

A split-tunnel WireGuard config is usually the kindest option: it routes only the cluster
and leaves the rest of your network alone.

### OpenVPN (via systemd)

```sh
HS_VPN_UP_CMD='sudo systemctl start openvpn-client@cluster'
HS_VPN_DOWN_CMD='sudo systemctl stop openvpn-client@cluster'
HS_VPN_STATUS_CMD='systemctl is-active --quiet openvpn-client@cluster'
```

### Tailscale

```sh
HS_VPN_UP_CMD='tailscale up'
HS_VPN_DOWN_CMD='tailscale down'
HS_VPN_STATUS_CMD='tailscale status >/dev/null 2>&1'
```

Tailscale is usually left up permanently. If so, set only `HS_VPN_STATUS_CMD` and leave
the other two empty — the tool will then never touch it.

### An interactive VPN you bring up yourself

If your VPN needs a human (a push notification, a smartcard), leave all three empty and
connect it yourself before running `hpc-session open`. The tool will simply assume the
network is reachable.
