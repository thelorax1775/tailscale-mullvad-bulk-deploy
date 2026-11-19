#!/usr/bin/env bats
# The script still behaves as before when it is run normally (no test seams).

load helpers

setup() {
    stub_setup
    # A PATH with no pvesh/pct/qm so the script stops at its host-tool check.
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    NOTOOLS_PATH="$BATS_TEST_TMPDIR/empty:/usr/bin:/bin"
}

@test "--help prints the usage and exits 0" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"bulk-deploy the Tailscale + Mullvad fail-closed"* ]]
    [[ "$output" == *"Configuration (environment variables):"* ]]
}

@test "-h prints the usage and exits 0" {
    run "$SCRIPT" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "bash bulkvpn-deploy.sh still reaches main" {
    run env -u BULKVPN_LIB_ONLY PATH="$NOTOOLS_PATH" "$BASH" "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: required host tool not found: pvesh"* ]]
}

@test "bash -s < bulkvpn-deploy.sh still reaches main" {
    run env -u BULKVPN_LIB_ONLY PATH="$NOTOOLS_PATH" "$BASH" -s < "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: required host tool not found: pvesh"* ]]
}

@test "BULKVPN_LIB_ONLY=1 defines the functions and does not run main" {
    run env BULKVPN_LIB_ONLY=1 PATH="$NOTOOLS_PATH" "$BASH" -c 'source "$0"; declare -F main process_guest ts_classify' "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"FATAL"* ]]
    [[ "$output" == *"process_guest"* ]]
}

@test "BULKVPN_LOG_DIR decides where the log goes" {
    run env BULKVPN_LIB_ONLY=1 "$BASH" -c 'source "$0"; echo "$LOG_FILE"' "$SCRIPT"
    [[ "$output" == "$BATS_TEST_TMPDIR/logs/bulkvpn-"*.log ]]
}

@test "without BULKVPN_LOG_DIR the log still goes to /root" {
    run env -u BULKVPN_LOG_DIR BULKVPN_LIB_ONLY=1 "$BASH" -c 'source "$0"; echo "$LOG_FILE"' "$SCRIPT"
    [[ "$output" == /root/bulkvpn-*.log ]]
}
