#!/usr/bin/env bats
# Watchdog log resilience tests: mullvad-rotate.sh keeps healing when its log file
# cannot be written (missing directory, full disk, read-only fs, etc.).

bats_require_minimum_version 1.5.0

load helpers

# Stub tailscale that:
# - logs every call to a file
# - prints one candidate for exit-node list
# - returns {} for status --json
# - set --exit-node=X brings up the fake tunnel (for verify_connectivity)
setup_tailscale_stub() {
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    cat > "$STUB_BIN/tailscale" <<'STUB'
#!/usr/bin/env bash
echo "tailscale $*" >> "$STUB_LOG.tailscale"
case "${1:-}" in
    status) echo '{}' ;;
    exit-node) echo " 100.1.1.1  us-nyc-wg-001.mullvad.ts.net  USA  NYC  -" ;;
    set) case "${2:-}" in --exit-node=?*) exit 0 ;; esac ;;
esac
exit 0
STUB
    chmod +x "$STUB_BIN/tailscale"
    export PATH="$STUB_BIN:$PATH"
}

# Stub timeout that exits with given code (0 = connectivity works, 1 = no connectivity)
# Does NOT run the actual command - just exits with the configured code.
setup_timeout_stub() {
    local exit_code="$1"
    cat > "$STUB_BIN/timeout" <<EOF
#!/usr/bin/env bash
# timeout stub: exits with $exit_code without running the command
shift  # skip timeout value
exit $exit_code
EOF
    chmod +x "$STUB_BIN/timeout"
}

# Stub sleep that does nothing (TUNNEL_SETTLE is 3s normally)
setup_sleep_stub() {
    cat > "$STUB_BIN/sleep" <<'STUB'
#!/usr/bin/env bash
# no-op sleep
exit 0
STUB
    chmod +x "$STUB_BIN/sleep"
}

# Stub nft that says table exists
setup_nft_stub() {
    cat > "$STUB_BIN/nft" <<'NFT'
#!/usr/bin/env bash
case "${1:-}" in
    list) exit 0 ;;  # table exists
    -f) exit 0 ;;
    *) exit 0 ;;
esac
NFT
    chmod +x "$STUB_BIN/nft"
}

setup_watchdog() {
    # Common setup for watchdog tests
    stub_setup
    
    # Use the real asset script with modified paths
    sed -e 's/^CHECK_TIMEOUT=[0-9]*/CHECK_TIMEOUT=2/' \
        -e 's/^TUNNEL_SETTLE=[0-9]*/TUNNEL_SETTLE=0/' \
        "$REPO/assets/mullvad-rotate.sh" > "$BATS_TEST_TMPDIR/rotate.sh"
    chmod +x "$BATS_TEST_TMPDIR/rotate.sh"
    
    setup_nft_stub
    export MULLVAD_NFT="$STUB_BIN/nft"
    export MULLVAD_KILLSWITCH_RULES="/etc/nftables.d/mullvad-killswitch.nft"
    
    # Reset tailscale call log
    : > "$STUB_LOG.tailscale"
}

@test "watchdog: missing log directory does not stop healing (normal run)" {
    setup_watchdog
    setup_tailscale_stub
    setup_timeout_stub 0  # connectivity works
    setup_sleep_stub
    
    # Log file in a directory that doesn't exist
    MULLVAD_LOG_FILE="$BATS_TEST_TMPDIR/missing-dir/x.log"
    export MULLVAD_LOG_FILE
    
    run --separate-stderr bash "$BATS_TEST_TMPDIR/rotate.sh"
    echo "status=$status"
    echo "output=$output"
    echo "stderr=[$stderr]"
    echo "stderr_len=${#stderr}"
    echo "stderr_raw=$(printf '%q' "$stderr")"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: traffic verified through us-nyc-wg-001.mullvad.ts.net"* ]]
    
    # Save stderr before next run command overwrites it
    local captured_stderr="$stderr"
    
    # Check stub call log has exactly one set --exit-node=us-nyc-wg-001.mullvad.ts.net
    run cat "$STUB_LOG.tailscale"
    local sets
    sets=$(grep -c 'set --exit-node=us-nyc-wg-001.mullvad.ts.net' "$STUB_LOG.tailscale" || true)
    echo "sets=$sets"
    echo "stub_log=$(cat "$STUB_LOG.tailscale")"
    [ "$sets" -eq 1 ]
    
    # Stderr should have exactly one line: the WARN about log file
    [ "${#captured_stderr}" -gt 0 ] || { echo "FAIL: stderr is empty but should have WARN line"; return 1; }
    local stderr_lines
    stderr_lines=$(printf '%s\n' "$captured_stderr" | grep -c '^' || true)
    [ "$stderr_lines" -eq 1 ]
    [[ "$captured_stderr" == *"WARN: cannot write to log file"* ]]
}

@test "watchdog: missing log directory does not stop healing (--check-only, no connectivity)" {
    setup_watchdog
    setup_tailscale_stub
    setup_timeout_stub 1  # connectivity FAILS
    setup_sleep_stub
    
    # Log file in a directory that doesn't exist
    MULLVAD_LOG_FILE="$BATS_TEST_TMPDIR/missing-dir/x.log"
    export MULLVAD_LOG_FILE
    
    # Also need a preferred node for --check-only to try switching
    export MULLVAD_PREFERRED_NODE="us-nyc-wg-001.mullvad.ts.net"
    
    run --separate-stderr bash "$BATS_TEST_TMPDIR/rotate.sh" --check-only
    echo "status=$status"
    echo "output=$output"
    echo "stderr=[$stderr]"
    echo "stderr_len=${#stderr}"
    echo "stderr_raw=$(printf '%q' "$stderr")"
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"NO connectivity detected"* ]]
    [[ "$output" == *"exhausted"* ]]
    
    # Save stderr before next run command overwrites it
    local captured_stderr="$stderr"
    
    # Check stub call log has at least one set --exit-node=
    run cat "$STUB_LOG.tailscale"
    local sets
    sets=$(grep -c 'set --exit-node=' "$STUB_LOG.tailscale" || true)
    echo "sets=$sets"
    echo "stub_log=$(cat "$STUB_LOG.tailscale")"
    [ "$sets" -ge 1 ]
    
    # Stderr should have exactly one line: the WARN about log file
    [ "${#captured_stderr}" -gt 0 ] || { echo "FAIL: stderr is empty but should have WARN line"; return 1; }
    local stderr_lines
    stderr_lines=$(printf '%s\n' "$captured_stderr" | grep -c '^' || true)
    [ "$stderr_lines" -eq 1 ]
    [[ "$captured_stderr" == *"WARN: cannot write to log file"* ]]
}

@test "watchdog: writable log file receives same lines as stdout (behaviour unchanged)" {
    setup_watchdog
    setup_tailscale_stub
    setup_timeout_stub 0  # connectivity works
    setup_sleep_stub
    
    # Log file in a writable location
    MULLVAD_LOG_FILE="$BATS_TEST_TMPDIR/writable.log"
    export MULLVAD_LOG_FILE
    
    run --separate-stderr bash "$BATS_TEST_TMPDIR/rotate.sh"
    echo "status=$status"
    echo "output=$output"
    echo "stderr=[$stderr]"
    echo "stderr_len=${#stderr}"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: traffic verified through us-nyc-wg-001.mullvad.ts.net"* ]]
    
    # Log file should exist
    [ -f "$MULLVAD_LOG_FILE" ]
    
    # Log file should equal stdout exactly (diff with stderr kept separate)
    # Normalize line endings and compare
    diff <(printf '%s\n' "$output") "$MULLVAD_LOG_FILE"
    
    # No WARN about log file in stderr
    [ -z "$stderr" ]
}

# a1b5f9f regression results (one-time verification, reported in PR):
# - Test 1 (missing log dir, normal run): FAILS on a1b5f9f with "tee: ... No such file or directory", exit 1, zero tailscale set calls
# - Test 2 (missing log dir, --check-only): FAILS on a1b5f9f with "tee: ... No such file or directory", exit 1, zero tailscale set calls
# - Test 3 (writable log): PASSES on a1b5f9f (behaviour unchanged)
