# Changelog

## Unreleased

### Changed

- `--help` text now lives in a heredoc inside `usage()` instead of the script's
  comment header, so it prints without `#` prefixes and no longer depends on
  fixed line numbers.

### Fixed

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

### Added

- `MULLVAD_LAN_SCAN_EXCLUDE`: vmids to leave out of the LAN pre-scan.
- `MULLVAD_LAN_AGENT_QUERY` (default `1`): set `0` to keep the pre-scan to
  host-side config only, with no guest-agent queries even for selected VMs.
