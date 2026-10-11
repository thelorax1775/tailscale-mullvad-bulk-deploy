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
