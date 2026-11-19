# Shared helpers for the bats tests. Nothing here touches a real Proxmox node:
# pvesh, pct and qm are stubs, and every file lives under BATS_TEST_TMPDIR.

SCRIPT="$BATS_TEST_DIRNAME/../bulkvpn-deploy.sh"
# shellcheck disable=SC2034  # used by the .bats files that load this helper
REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# lib NAME ARGS...: run one function of the deploy script in a fresh bash, with
# the script's own `set -Eeuo pipefail`, without running main.
lib() {
    BULKVPN_LIB_ONLY=1 bash -c 'source "$0" && "$@"' "$SCRIPT" "$@"
}

# libsh 'SNIPPET': run a shell snippet after the script has been sourced.
libsh() {
    BULKVPN_LIB_ONLY=1 bash -c 'source "$0" && eval "$1"' "$SCRIPT" "$1"
}

# stub_setup: create the stub tools and the fixture directory. Afterwards PATH
# starts with the stubs, and the script's log, TMPDIR and HOME are inside the
# test's temp directory.
stub_setup() {
    STUB_DIR="$BATS_TEST_TMPDIR/fixtures"
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
    mkdir -p "$STUB_DIR" "$STUB_BIN" "$BATS_TEST_TMPDIR/logs" "$BATS_TEST_TMPDIR/tmp" "$BATS_TEST_TMPDIR/home"
    local t
    for t in pvesh pct qm; do
        cp "$BATS_TEST_DIRNAME/stubs/pve-stub.sh" "$STUB_BIN/$t"
    done
    : > "$STUB_LOG"
    export STUB_DIR STUB_LOG
    export PATH="$STUB_BIN:$PATH"
    export BULKVPN_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    export TMPDIR="$BATS_TEST_TMPDIR/tmp" HOME="$BATS_TEST_TMPDIR/home"
    export PVE_NODE=testnode
    unset TS_AUTHKEY TS_AUTHKEY_FILE SELECT_GUESTS FORCE_REDEPLOY BULKVPN_LIB_ONLY
}

# Fixture builders. Guest names are ct<ID> / vm<ID>.
fixture_lxc()  { printf '%s' "$1" > "$STUB_DIR/lxc.json"; }
fixture_qemu() { printf '%s' "$1" > "$STUB_DIR/qemu.json"; }
fixture_flag() { : > "$STUB_DIR/$1"; }          # fixture_flag ct101.protected
fixture_probe() { printf '%s' "$2" > "$STUB_DIR/$1.probe"; }   # fixture_probe ct101 'bin=1 ...'

# run_main: run the whole script (main) with the stubs, in a fresh bash. The
# host-touching ensure_host_tun is replaced so a real run cannot modprobe or
# write /etc/modules-load.d.
run_main() {
    run bash -c 'BULKVPN_LIB_ONLY=1 source "$0"; ensure_host_tun() { log "Host: tun check skipped (test)"; }; main' "$SCRIPT" < /dev/null
}

# calls_log: the stub call log (one line per call).
calls_log() { cat "$STUB_LOG"; }
