#!/usr/bin/env bats
# enable_tun_lxc / lxc_tun_configured edit only a CT's current settings (the
# lines before the first [snapshot] header). Sample configs live in a temp dir.

load helpers

DEV='lxc.cgroup2.devices.allow: c 10:200 rwm'
MNT='lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file'

setup() {
    stub_setup
    export PVE_LXC_CONF_DIR="$BATS_TEST_TMPDIR/lxc"
    mkdir -p "$PVE_LXC_CONF_DIR"
    CONF="$PVE_LXC_CONF_DIR/150.conf"
}

# from_header FILE: the text from the first [..] header to the end.
from_header() { awk '/^\[.+\]$/ { p = 1 } p' "$1"; }
current() { awk '/^\[.+\]$/ { exit } { print }' "$1"; }

# Every non-blank line of the current settings is "key: value"; none repeated.
assert_well_formed() {
    local bad dup
    bad="$(current "$CONF" | grep -v '^[[:space:]]*$' | grep -cvE '^[A-Za-z0-9_.-]+: .+' || true)"
    [ "$bad" -eq 0 ]
    dup="$(current "$CONF" | grep -v '^[[:space:]]*$' | sort | uniq -d)"
    [ -z "$dup" ]
}

base_current() {
    printf 'arch: amd64\ncores: 2\nhostname: web\nunprivileged: 1\n'
}

snap() {  # snap NAME [extra lines...]
    local n="$1"; shift
    printf '[%s]\narch: amd64\ncores: 1\nsnaptime: 1700000000\n' "$n"
    (( $# )) && printf '%s\n' "$@"
    return 0
}

@test "two snapshots, no tun lines: both lines go to the current settings, snapshots untouched" {
    { base_current; printf '\n'; snap before-upgrade; printf '\n'; snap second; } > "$CONF"
    before="$(from_header "$CONF")"
    run lib enable_tun_lxc 150
    [ "$status" -eq 1 ]
    [ "$(from_header "$CONF")" = "$before" ]
    current "$CONF" | grep -qxF "$DEV"
    current "$CONF" | grep -qxF "$MNT"
    # inserted before the blank line that separates the sections
    [ "$(sed -n 5,6p "$CONF" | tr '\n' '|')" = "$DEV|$MNT|" ]
    [ -z "$(sed -n 7p "$CONF")" ]
    assert_well_formed
    run lib lxc_tun_configured 150
    [ "$status" -eq 0 ]
}

@test "tun lines only inside a snapshot: not configured, both added to current, snapshot untouched" {
    { base_current; printf '\n'; snap old "$DEV" "$MNT"; } > "$CONF"
    before="$(from_header "$CONF")"
    run lib lxc_tun_configured 150
    [ "$status" -ne 0 ]
    run lib enable_tun_lxc 150
    [ "$status" -eq 1 ]
    [ "$(from_header "$CONF")" = "$before" ]
    current "$CONF" | grep -qxF "$DEV"
    current "$CONF" | grep -qxF "$MNT"
    assert_well_formed
    run lib lxc_tun_configured 150
    [ "$status" -eq 0 ]
}

@test "only one line present in the current settings: only the missing one is added" {
    { base_current; echo "$DEV"; printf '\n'; snap s1; } > "$CONF"
    before="$(from_header "$CONF")"
    run lib enable_tun_lxc 150
    [ "$status" -eq 1 ]
    [ "$(current "$CONF" | grep -cxF "$DEV")" -eq 1 ]
    [ "$(current "$CONF" | grep -cxF "$MNT")" -eq 1 ]
    [ "$(from_header "$CONF")" = "$before" ]
    assert_well_formed
}

@test "only the mount line present: only the device line is added" {
    { base_current; echo "$MNT"; } > "$CONF"
    run lib enable_tun_lxc 150
    [ "$status" -eq 1 ]
    [ "$(grep -cxF "$DEV" "$CONF")" -eq 1 ]
    [ "$(grep -cxF "$MNT" "$CONF")" -eq 1 ]
    assert_well_formed
}

@test "both lines already in current settings (with snapshots): file unchanged, return 0" {
    { base_current; echo "$DEV"; echo "$MNT"; printf '\n'; snap s1; } > "$CONF"
    cp "$CONF" "$BATS_TEST_TMPDIR/orig"
    run lib lxc_tun_configured 150
    [ "$status" -eq 0 ]
    run lib enable_tun_lxc 150
    [ "$status" -eq 0 ]
    cmp "$CONF" "$BATS_TEST_TMPDIR/orig"
    assert_well_formed
}

@test "both lines already in current settings (no snapshots): file unchanged, return 0" {
    { base_current; echo "$DEV"; echo "$MNT"; } > "$CONF"
    cp "$CONF" "$BATS_TEST_TMPDIR/orig"
    run lib lxc_tun_configured 150
    [ "$status" -eq 0 ]
    run lib enable_tun_lxc 150
    [ "$status" -eq 0 ]
    cmp "$CONF" "$BATS_TEST_TMPDIR/orig"
    assert_well_formed
}

@test "no snapshots, no tun lines: both added, second call changes nothing" {
    base_current > "$CONF"
    run lib enable_tun_lxc 150
    [ "$status" -eq 1 ]
    [ "$(grep -cxF "$DEV" "$CONF")" -eq 1 ]
    [ "$(grep -cxF "$MNT" "$CONF")" -eq 1 ]
    cp "$CONF" "$BATS_TEST_TMPDIR/after1"
    run lib enable_tun_lxc 150
    [ "$status" -eq 0 ]
    cmp "$CONF" "$BATS_TEST_TMPDIR/after1"
    assert_well_formed
}

@test "unprivileged is read from the current settings only" {
    { printf 'arch: amd64\n\n'; snap s1 'unprivileged: 1'; } > "$CONF"
    run lib lxc_is_unprivileged 150
    [ "$status" -ne 0 ]
    { base_current; printf '\n'; snap s1; } > "$CONF"
    run lib lxc_is_unprivileged 150
    [ "$status" -eq 0 ]
}

@test "PVE_LXC_CONF_DIR unset: path is /etc/pve/lxc/<vmid>.conf" {
    run bash -c 'unset PVE_LXC_CONF_DIR; BULKVPN_LIB_ONLY=1 source "$0"; lxc_conf_path 123' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "/etc/pve/lxc/123.conf" ]
}

@test "DRY_RUN=1: tun lines only in a snapshot still list the tun + reboot step" {
    fixture_lxc '[{"vmid":150,"status":"running","name":"web"}]'
    fixture_qemu '[]'
    fixture_probe ct150 'bin=0 state=0 profile=0 svc=none backend=unknown'
    { base_current; printf '\n'; snap old "$DEV" "$MNT"; } > "$CONF"
    cp "$CONF" "$BATS_TEST_TMPDIR/orig"
    TS_AUTHKEY=dry-run-placeholder DRY_RUN=1 run_main
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD enroll"*"add /dev/net/tun to the CT config and reboot the CT"* ]]
    cmp "$CONF" "$BATS_TEST_TMPDIR/orig"
}

@test "a failing rewrite leaves the CT config byte-identical and says why" {
    { base_current; printf 'rootfs: local:150/disk.raw\n\n'; snap old; } > "$CONF"
    cp "$CONF" "$BATS_TEST_TMPDIR/orig"
    real_awk="$(command -v awk)"
    # awk used for the rewrite (-v add=...) prints one line and fails, like a full /tmp
    # shellcheck disable=SC2016
    printf '#!/bin/bash\nif [ "$1" = "-v" ]; then echo "arch: amd64"; exit 2; fi\nexec %s "$@"\n' "$real_awk" > "$STUB_BIN/awk"
    chmod +x "$STUB_BIN/awk"
    run lib enable_tun_lxc 150
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"*"NOT written"* ]]
    cmp "$CONF" "$BATS_TEST_TMPDIR/orig"
}

@test "a rewrite with the wrong line count is not copied over the config" {
    { base_current; printf '\n'; snap old; } > "$CONF"
    cp "$CONF" "$BATS_TEST_TMPDIR/orig"
    real_awk="$(command -v awk)"
    # exits 0 but drops lines
    # shellcheck disable=SC2016
    printf '#!/bin/bash\nif [ "$1" = "-v" ]; then echo "arch: amd64"; exit 0; fi\nexec %s "$@"\n' "$real_awk" > "$STUB_BIN/awk"
    chmod +x "$STUB_BIN/awk"
    run lib enable_tun_lxc 150
    [ "$status" -eq 0 ]
    [[ "$output" == *"expected"* ]]
    cmp "$CONF" "$BATS_TEST_TMPDIR/orig"
}

@test "a missing config logs why no tun lines were written" {
    run lib enable_tun_lxc 999
    [ "$status" -eq 0 ]
    [[ "$output" == *"not found"*"NOT written"* ]]
}
