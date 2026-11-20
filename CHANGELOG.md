# Changelog

## Unreleased

### Fixed
- The watchdog (`assets/mullvad-rotate.sh` and the embedded copy in `bulkvpn-deploy.sh`) keeps healing the Mullvad exit node tunnel even when its log file cannot be written (e.g., full disk, missing directory, read-only filesystem). The `log()` function now prints to stdout and appends to the log file on a best-effort basis: a failed append does not make `log()` or `die()` return non-zero, and at most one warning per run is printed to stderr. Previously, `tee -a "$LOG_FILE"` under `set -euo pipefail` caused the whole script to exit at the first log line, leaving the guest with a blocked tunnel and no self-healing.
- `MULLVAD_COUNTRY_FILTER` and `MULLVAD_PREFERRED_NODE` values containing shell metacharacters (`&`, `|`, `"`, `$`, backslash, etc.) are now written literally into the watchdog script without breaking the render or enabling code injection. The fix uses `printf '%q'` quoting in the templating functions and renders the output into variables in `deploy_killswitch`; a failed or empty render logs a `FAILED` line and returns non-zero before any `push_file` call, so an empty file never overwrites a working watchdog.
- Guest auto-detected LAN subnets are now filtered through `private_cidr_filter`: non-private subnets (e.g. a second VPN's `0.0.0.0/1 128.0.0.0/1`) are ignored and logged once per guest with "ignoring non-private subnet(s)". If all auto-detected subnets are dropped, the RFC1918 fallback (`10.0.0.0/8 172.16.0.0/12 192.168.0.0/16`) is used instead of allowing the whole internet.
- `MULLVAD_LAN_SUBNET` extras are validated with `cidr_network` before any guest is touched. Each entry must be a valid IPv4 CIDR with prefix length >= 8. Invalid entries (e.g. `0.0.0.0/0`, `10.0.0.0/33`, `foo/24`) cause the script to exit non-zero with a clear error message and no guest operations are performed.
- The nftables asset comment and the embedded copy in `bulkvpn-deploy.sh` now correctly state that the LAN line is templated from `resolve_lan_list` (auto-detected subnets, other guests' subnets, and `MULLVAD_LAN_SUBNET` extras), not just from `MULLVAD_LAN_SUBNET`.
- README: the "LAN access is automatic" paragraph now documents that guest-detected non-private subnets are ignored and that `MULLVAD_LAN_SUBNET` entries must be valid IPv4 CIDRs with prefix /8 or longer.

- Kill-switch `forward` chain: a physical uplink named like a container bridge
  (`br-*`, `docker*`, `podman*`, `cni*`) no longer opens forwarded traffic. The
  plain `oifname "br-*" accept` is replaced by three narrow accepts for those
  names: `ct direction reply`, `ct status dnat` (published ports) and
  bridge-to-bridge traffic to private addresses. Reproduced with the leak rig
  run with `BULKVPN_LEAK_PHYS=br-up`: after the route was removed 4 packets
  (masquerade) and 30 packets (SNAT, 29 from 100.64/10) left the uplink; a new
  container connection to an internet address leaked 3 packets; 0 after the fix.
  The two forwarded cases are no longer skipped in the br-up run; new cases
  cover a container's new connection, a published port (LAN -> DNAT ->
  container, replies) and container-to-container across two bridges. Already-
  protected guests need `FORCE_REDEPLOY=1` to receive the fix.
  Follow-ups from review: the ruleset no longer puts wildcard interface names
  inside anonymous sets (nft 1.0.2 / Ubuntu 22.04 failed to load the whole file
  with "Byteorder mismatch"; a bats test guards it); `tailscale0` -> container
  (subnet router) keeps working, with a rig case; replies of DNATed connections
  no longer leave a br-* uplink (`ct status ! dnat`), with a rig case; the
  forward-chain comment about `ct direction reply` was inverted and is fixed.
  Documented, not fixed: on a br-* uplink a container's new connection to a
  private non-LAN address still leaves the uplink, and a LAN host with a static
  route to the container subnet is not allowed (add it to `MULLVAD_LAN_SUBNET`).
- README: on a `br-*`-named uplink `output`'s `ct direction reply` accepts let
  the guest's replies to inbound connections from outside the LAN set leave the
  uplink; the caveat now says so instead of claiming they are dropped.

- Enrolling a container no longer writes the `/dev/net/tun` passthrough lines
  into a snapshot. A CT config is the current settings followed by one
  `[name]` section per snapshot, and the lines were appended to the end of the
  file, i.e. into the last snapshot: the CT was rebooted without a tun device,
  the join failed, and every later run (and the dry run) believed tun was
  configured. `lxc_tun_configured`, `enable_tun_lxc` and `lxc_is_unprivileged`
  now look only at the lines before the first `[...]` header, and missing lines
  are inserted at the end of those, before the blank lines that precede the
  first snapshot. Snapshot sections are left byte-identical. New variable
  `PVE_LXC_CONF_DIR` (default `/etc/pve/lxc`) names the config directory.
  If the rewrite fails or yields an unexpected line count, the CT config is left
  untouched and a WARN line says the tun lines were not written.
- Watchdog: `mullvad-rotate.sh` now restores the kill-switch when something has
  removed it. Its connectivity probe counts any successful connect as a working
  tunnel, which is only true while the kill-switch is loaded; after
  `nft flush ruleset` with the tunnel down it logged "tunnel healthy" while its
  own probes left through the physical NIC. Every run now checks
  `nft list table inet mullvad_killswitch` first, reloads
  `/etc/nftables.d/mullvad-killswitch.nft` if it is missing (logged), and exits
  non-zero without probing if it cannot. `mullvad-killswitch.service` gains
  `After=`, `PartOf=`, `ReloadPropagatedFrom=nftables.service` and an
  `ExecReload=`, so restarting or upgrading nftables re-applies it immediately
  (not exercised on a running systemd). `bulkvpn-deploy.sh` no longer counts a
  guest as already protected when the table is not loaded. Already-protected
  guests need `FORCE_REDEPLOY=1` to receive the new script and unit.
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
  established/related rule. On a guest whose physical uplink is named like
  one of these, replies to outside-LAN inbound connections still leave it (see
  README).

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
