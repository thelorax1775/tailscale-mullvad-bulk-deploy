# Changelog

## Unreleased

### Fixed

- Kill-switch: connections opened through the tunnel no longer leave through the
  physical NIC after the exit node is cleared. `ct state established,related
  accept` sat before any interface check in both chains; when Tailscale removed
  the default route from table 52 (as `mullvad-rotate.sh` does on purpose, and
  as happens when a node dies) the flow was re-routed to `eth0` with its
  `100.64.x.x` source and that rule let it out. The rule is gone from `output`
  and `forward`; every packet is now judged by its interface or destination.
  Reproduced with the leak rig (a TCP client keeps writing while the table-52
  default route is deleted: 29 packets on the physical side before the fix, 0
  after) and with the audit script `tailscale-mullvad-bulk-deploy-repro.sh`
  case 1 (0 packets before the route was removed, 4 after). The forwarded half
  is covered with a container namespace whose traffic is SNATed to the
  Tailscale address; with `masquerade` the kernel already refuses to move such a
  flow. Already-protected guests need `FORCE_REDEPLOY=1` to receive the fix.
- Kill-switch: UDP port 67 is no longer open to the whole internet. `udp dport
  67 accept` had no source port, destination or address family, so any program
  could send UDP to port 67 on any host with the tunnel down. Only the DHCP
  client form (`udp sport 68 udp dport 67 ip daddr 255.255.255.255`) is allowed
  now. Reproduced with the leak rig (UDP from an unprivileged port to
  203.0.113.10:67 and to `2001:db8::10` port 67: 3 and 9 packets on the
  physical side before the fix, 0 after) and with the audit script case 2.
  Already-protected guests need `FORCE_REDEPLOY=1` to receive the fix.
- Kill-switch `output` chain now accepts packets for local container bridges
  (`docker*`, `br-*`, `podman*`, `cni*`), reply direction only (`ct direction
  reply`), so a guest's own replies to a container keep working without the
  established/related rule. Known limitation: on a guest whose physical uplink
  is named like one of these, the `forward` chain's plain accept still applies
  (see README).

### Added

- Automatic checks. `./check.sh` runs `bash -n`, ShellCheck, a bats suite and a
  network-namespace leak rig; `.github/workflows/ci.yml` runs it as job `ci` on
  every pull request and every push to `main`. The bats suite covers the helper
  functions, `ts_classify`, guest selection, end-to-end dry and real runs
  against stub `pvesh`/`pct`/`qm`, and a drift test for the embedded assets. The
  leak rig loads the real templated ruleset and checks that nothing reaches the
  physical NIC while the tunnel is down.
- Test seams (no effect when unset): `BULKVPN_LIB_ONLY=1` defines the functions
  without running `main`; `BULKVPN_LOG_DIR` sets the log directory (default
  `/root`).

### Changed (checks)

- The assets embedded in `bulkvpn-deploy.sh` are now byte-identical to
  `assets/` (the comments that had been stripped are back), as the README says;
  `tests/assets.bats` enforces it.
- Two ShellCheck notes are silenced per line with a reason (SC2016 in
  `assets/mullvad-rotate.sh`, SC2086 in `select_guests`).

### Changed

- The Tailscale auth key no longer appears on any command line. It used to be
  embedded in the `tailscale up --authkey=…` string run through `pct exec` /
  `qm guest exec`, so it was visible in process listings on the host and in
  the guest. It is now written into the guest as `/run/bulkvpn-ts-authkey`
  (0600) via `pct push` or `qm guest exec --pass-stdin`, passed as
  `--auth-key=file:…`, and removed after the join. New `TS_AUTHKEY_FILE`
  reads the key from a file so it stays out of shell history.
- `--help` text now lives in a heredoc inside `usage()` instead of the script's
  comment header, so it prints without `#` prefixes and no longer depends on
  fixed line numbers.

### Fixed

- `DRY_RUN=1` now reports what a real run would actually do. It used to print
  `WOULD deploy` right after the systemd check, before looking at Tailscale or
  Mullvad, so on one node 17 guests that a real run skips (no Mullvad exit node
  visible) were reported as `WOULD deploy`. The dry run now runs the same
  read-only checks as a real run (guest agent, existing kill-switch, systemd,
  Tailscale state, Mullvad exit nodes) and reports `WOULD deploy` (with the LAN
  set it would use), `WOULD enroll`, `WOULD skip: <reason>` or `WOULD fail`,
  with a matching tally.

- Host `tun` check no longer misses a `tun` that is built into the kernel.
  `lsmod | grep ^tun` only sees loadable modules, so on kernels with built-in
  tun the script ran `modprobe` and checked `tun.conf` on every run. It now
  checks `modules.builtin` and `/sys/module/tun` and only loads and persists
  the module when it is actually missing. A dry run no longer loads the module
  or writes `tun.conf`; it reports what it would do.
- Forwarded traffic is now fail-closed. The nftables kill-switch only had an
  `output` chain, so traffic a guest forwarded (Docker containers on a bridge
  network) bypassed it and could leave through the physical NIC when the exit
  node was down. A `forward` chain with a `drop` policy now allows only
  established/related flows, egress via `tailscale0`, the allowed LAN subnets,
  and traffic into local container bridges (`docker*`, `br-*`, `podman*`,
  `cni*`). The `output` chain is unchanged. Already-protected guests need
  `FORCE_REDEPLOY=1` to receive it. The upstream
  `tailscale-mullvad-killswitch` ruleset needs the same change.
- The cross-guest LAN pre-scan no longer runs commands inside unselected
  guests. It used to `pct exec` / `qm guest exec` into every running guest on
  the node, even with `SELECT_GUESTS` set (on one node that included the
  OPNsense router VM). Subnets now come from host-side state: `pct config` /
  `qm config` (`ip=` on `netN`, cloud-init `ipconfigN`) or the host's subnet on
  the guest's bridge / `bridge.tag` VLAN. Selected VMs may additionally be asked
  for their addresses via the read-only guest-agent call
  `network-get-interfaces`. Only private (RFC1918) subnets are accepted from
  the pre-scan; others are logged and ignored.

- A guest that is already on the tailnet is no longer rebooted and
  re-enrolled when `tailscale status` fails. Any failure of the old
  `tailscale status` check sent the guest down the "not on tailnet" path:
  add `/dev/net/tun` to the CT config, reboot the CT, reinstall Tailscale and
  `tailscale up` with whatever `TS_AUTHKEY` was given. The script now probes
  the binary, the `tailscaled` unit, the login profile in
  `/var/lib/tailscale/tailscaled.state` and `BackendState` (with retries), and
  only installs/enrolls guests that have never been logged in. Guests with
  existing state that aren't confirmed `Running` are skipped with a warning.
- `TS_AUTHKEY` is no longer required up front. It is checked per guest at the
  moment a guest actually needs enrollment; that guest fails with a clear
  message and the run continues.

### Added

- `MULLVAD_PREFERRED_NODE`: an exit node the rotator prefers and returns to.
  Rotation tries it first (even when it is already the current node, which the
  tailnet's exit-node list omits); on failure it falls back within
  `MULLVAD_COUNTRY_FILTER`, and each `--check-only` heal moves back to it once
  it works again. Switching to the node already in use clears and re-sets the
  exit node to force a fresh WireGuard handshake, which recovers tunnels left
  stuck after an upstream network change. Connectivity is re-checked once
  before a node is declared dead, so a slow handshake is not mistaken for a
  failure. Applied to both `assets/mullvad-rotate.sh` and the copy embedded in
  `bulkvpn-deploy.sh`.

- `MULLVAD_LAN_SCAN_EXCLUDE`: vmids to leave out of the LAN pre-scan.
- `MULLVAD_LAN_AGENT_QUERY` (default `1`): set `0` to keep the pre-scan to
  host-side config only, with no guest-agent queries even for selected VMs.
