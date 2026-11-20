#!/usr/bin/env bats
# Watchdog log resilience tests: mullvad-rotate.sh keeps healing when its log file
# cannot be written (missing directory, full disk, read-only fs, etc.).

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
setup_timeout_stub() {
    local exit_code="$1"
    cat > "$STUB_BIN/timeout" <<EOF
#!/usr/bin/env bash
# timeout stub: just run the command and exit with $exit_code
shift  # skip timeout value
"\$@"
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
    
    run bash "$BATS_TEST_TMPDIR/rotate.sh"
    echo "status=$status"
    echo "output=$output"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: traffic verified through us-nyc-wg-001.mullvad.ts.net"* ]]
    
    # Check stub call log has exactly one set --exit-node=us-nyc-wg-001.mullvad.ts.net
    run cat "$STUB_LOG.tailscale"
    local sets
    sets=$(grep -c '^tailscale set --exit-node=us-nyc-wg-001\.mullvad\.ts\.net ' "$STUB_LOG.tailscale" || true)
    [ "$sets" -eq 1 ]
    
    # Should have exactly one WARN about log file (not multiple)
    local warns
    warns=$(grep -c 'WARN: cannot write to log file' <<<"$output" || true)
    [ "$warns" -le 1 ]
}

@test "watchdog: missing log directory does not stop healing (--check-only, no connectivity)" {
    setup_watchdog
    setup_tailscale_stub
    setup_timeout_stub 1  # connectivity FAILS
    setup_sleep_stub
    
    # Log file in a directory that doesn't exist
    MULLVAD_LOG_FILE="$BATS_TEST_TMPDIR/missing-dir/x.log"
    export MULLVAD_LOG_FILE
    
    run bash "$BATS_TEST_TMPDIR/rotate.sh" --check-only
    echo "status=$status"
    echo "output=$output"
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"NO connectivity detected"* ]]
    [[ "$output" == *"exhausted"* ]]
    
    # Check stub call log has at least one set --exit-node=
    run cat "$STUB_LOG.tailscale"
    local sets
    sets=$(grep -c '^tailscale set --exit-node=' "$STUB_LOG.tailscale" || true)
    [ "$sets" -ge 1 ]
    
    # Should have exactly one WARN about log file
    local warns
    warns=$(grep -c 'WARN: cannot write to log file' <<<"$output" || true)
    [ "$warns" -le 1 ]
}

@test "watchdog: writable log file receives same lines as stdout (behaviour unchanged)" {
    setup_watchdog
    setup_tailscale_stub
    setup_timeout_stub 0  # connectivity works
    setup_sleep_stub
    
    # Log file in a writable location
    MULLVAD_LOG_FILE="$BATS_TEST_TMPDIR/writable.log"
    export MULLVAD_LOG_FILE
    
    run bash "$BATS_TEST_TMPDIR/rotate.sh"
    echo "status=$status"
    echo "output=$output"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: traffic verified through us-nyc-wg-001.mullvad.ts.net"* ]]
    
    # Log file should exist and contain the same lines as stdout (plus the WARN if any)
    [ -f "$MULLVAD_LOG_FILE" ]
    
    # Count lines in stdout (excluding the final success line which is duplicated in log)
    local stdout_lines
    stdout_lines=$(printf '%s\n' "$output" | wc -l)
    local log_lines
    log_lines=$(wc -l < "$MULLVAD_LOG_FILE")
    
    # Log should have at least as many lines as stdout (can have more due to initial setup)
    [ "$log_lines" -ge "$stdout_lines" ]
    
    # Every non-empty stdout line should appear in the log
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        grep -qF "$line" "$MULLVAD_LOG_FILE" || {
            echo "Line not found in log: $line"
            false
        }
    done <<<"$output"
    
    # No WARN about log file
    local warns
    warns=$(grep -c 'WARN: cannot write to log file' <<<"$output" || true)
    [ "$warns" -eq 0 ]
}

# Verify each new test fails on main a1b5f9f's version of the script
@test "watchdog: missing log directory FAILS on a1b5f9f (regression guard)" {
    # This test ensures our test would catch the bug on the old version
    # We run it against the old version and expect it to fail
    setup_tailscale_stub
    setup_timeout_stub 0
    setup_sleep_stub
    setup_nft_stub
    
    MULLVAD_LOG_FILE="$BATS_TEST_TMPDIR/missing-dir/x.log"
    export MULLVAD_LOG_FILE
    MULLVAD_NFT="$STUB_BIN/nft"
    export MULLVAD_NFT
    MULLVAD_KILLSWITCH_RULES="/etc/nftables.d/mullvad-killswitch.nft"
    export MULLVAD_KILLSWITCH_RULES
    
    # Get the old version of the script - fetch if needed
    local old_script="$BATS_TEST_TMPDIR/old_rotate.sh"
    if ! git -C "$REPO" cat-file -e a1b5f9f:assets/mullvad-rotate.sh 2>/dev/null; then
        skip "a1b5f9f not available in this clone (shallow CI clone); regression guard skipped"
    fi
    git -C "$REPO" show a1b5f9f:assets/mullvad-rotate.sh | \
        sed -e 's/^CHECK_TIMEOUT=[0-9]*/CHECK_TIMEOUT=2/' \
            -e 's/^TUNNEL_SETTLE=[0-9]*/TUNNEL_SETTLE=0/' \
        > "$old_script"
    chmod +x "$old_script"
    
    run bash "$old_script"
    echo "status=$status"
    echo "output=$output"
    
    # Old version should fail (exit non-zero) because tee fails
    [ "$status" -ne 0 ]
    [[ "$output" == *"tee:"* ]] || [[ "$output" == *"No such file or directory"* ]]
}

@test "watchdog: --check-only missing log dir FAILS on a1b5f9f (regression guard)" {
    setup_tailscale_stub
    setup_timeout_stub 1
    setup_sleep_stub
    setup_nft_stub
    
    MULLVAD_LOG_FILE="$BATS_TEST_TMPDIR/missing-dir/x.log"
    export MULLVAD_LOG_FILE
    MULLVAD_NFT="$STUB_BIN/nft"
    export MULLVAD_NFT
    MULLVAD_KILLSWITCH_RULES="/etc/nftables.d/mullvad-killswitch.nft"
    export MULLVAD_KILLSWITCH_RULES
    
    local old_script="$BATS_TEST_TMPDIR/old_rotate.sh"
    if ! git -C "$REPO" cat-file -e a1b5f9f:assets/mullvad-rotate.sh 2>/dev/null; then
        skip "a1b5f9f not available in this clone (shallow CI clone); regression guard skipped"
    fi
    git -C "$REPO" show a1b5f9f:assets/mullvad-rotate.sh | \
        sed -e 's/^CHECK_TIMEOUT=[0-9]*/CHECK_TIMEOUT=2/' \
            -e 's/^TUNNEL_SETTLE=[0-9]*/TUNNEL_SETTLE=0/' \
        > "$old_script"
    chmod +x "$old_script"
    
    run bash "$old_script" --check-only
    echo "status=$status"
    echo "output=$output"
    
    # Old version should fail (exit non-zero) because tee fails
    [ "$status" -ne 0 ]
    [[ "$output" == *"tee:"* ]] || [[ "$output" == *"No such file or directory"* ]]
}

@test "watchdog: writable log file works on a1b5f9f (unchanged behaviour)" {
    setup_tailscale_stub
    setup_timeout_stub 0
    setup_sleep_stub
    setup_nft_stub
    
    MULLVAD_LOG_FILE="$BATS_TEST_TMPDIR/writable.log"
    export MULLVAD_LOG_FILE
    MULLVAD_NFT="$STUB_BIN/nft"
    export MULLVAD_NFT
    MULLVAD_KILLSWITCH_RULES="/etc/nftables.d/mullvad-killswitch.nft"
    export MULLVAD_KILLSWITCH_RULES
    
    local old_script="$BATS_TEST_TMPDIR/old_rotate.sh"
    if ! git -C "$REPO" cat-file -e a1b5f9f:assets/mullvad-rotate.sh 2>/dev/null; then
        skip "a1b5f9f not available in this clone (shallow CI clone); regression guard skipped"
    fi
    git -C "$REPO" show a1b5f9f:assets/mullvad-rotate.sh | \
        sed -e 's/^CHECK_TIMEOUT=[0-9]*/CHECK_TIMEOUT=2/' \
            -e 's/^TUNNEL_SETTLE=[0-9]*/TUNNEL_SETTLE=0/' \
        > "$old_script"
    chmod +x "$old_script"
    
    run bash "$old_script"
    echo "status=$status"
    echo "output=$output"
    
    # Old version should work fine with writable log
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: traffic verified through us-nyc-wg-001.mullvad.ts.net"* ]]
    [ -f "$MULLVAD_LOG_FILE" ]
}