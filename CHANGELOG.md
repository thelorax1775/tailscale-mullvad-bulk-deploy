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
