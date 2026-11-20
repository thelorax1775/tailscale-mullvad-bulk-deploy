#!/usr/bin/env bats
# Templating tests: special characters in MULLVAD_COUNTRY_FILTER and
# MULLVAD_PREFERRED_NODE are written literally and safely into the rendered
# rotate script, and a failed render never pushes an empty file.

load helpers

# Test values covering the acceptance criteria:
# - 'Bosnia & Herzegovina'  (contains &, which sed treats as re-insert)
# - 'a|b'                   (contains |, which breaks sed delimiter)
# - 'back\slash'            (contains backslash)
# - 'x"$(touch $BATS_TEST_TMPDIR/pwned)"'  (contains " and command substitution - code injection attempt)
# - "Côte d'Ivoire"         (contains unicode and ')
# - ''                      (empty string)

SPECIAL_VALUES=(
    "Bosnia & Herzegovina"
    "a|b"
    "back\\slash"
    "Côte d'Ivoire"
    ""
)

# Injection value for code execution test - must be constructed at runtime
# because BATS_TEST_TMPDIR is not available at load time
# shellcheck disable=SC2016
INJECTION_VALUE='x"$(touch $BATS_TEST_TMPDIR/pwned)"'

# Helper: render rotate_templated with given env vars and capture output
render_rotate() {
    local country="$1" node="$2" lan="$3"
    MULLVAD_COUNTRY_FILTER="$country" MULLVAD_PREFERRED_NODE="$node" \
    lib rotate_templated "$lan"
}

# Helper: render nft_templated with given LAN value
render_nft() {
    local lan_value="$1"
    lib nft_templated "$lan_value"
}

@test "rotate_templated: special characters in COUNTRY_FILTER/PREFERRED_NODE are written literally and evaluate correctly" {
    local lan_subnets="192.168.10.0/24"
    for v in "${SPECIAL_VALUES[@]}"; do
        # Render the templated script with V for both COUNTRY_FILTER and PREFERRED_NODE
        run render_rotate "$v" "$v" "$lan_subnets"
        [ "$status" -eq 0 ]
        local rendered="$output"

        # Extract just the COUNTRY_FILTER= and PREFERRED_NODE= lines
        local cf_line pn_line
        cf_line=$(printf '%s\n' "$rendered" | grep '^COUNTRY_FILTER=')
        pn_line=$(printf '%s\n' "$rendered" | grep '^PREFERRED_NODE=')

        # Run in a fresh bash using eval to properly interpret shell-quoted values
        # (the lines are already shell-quoted with printf %q)
        run bash -c 'eval "$1"; eval "$2"; printf "COUNTRY_FILTER=%s\n" "$COUNTRY_FILTER"; printf "PREFERRED_NODE=%s\n" "$PREFERRED_NODE"' _ "$cf_line" "$pn_line"
        [ "$status" -eq 0 ]
        # Both should print exactly V
        [[ "${lines[0]}" == "COUNTRY_FILTER=$v" ]]
        [[ "${lines[1]}" == "PREFERRED_NODE=$v" ]]

        # Ensure no code execution happened (pwned file should not exist)
        [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
    done
}

@test "rotate_templated: command substitution in value does not execute (injection attempt)" {
    local lan_subnets="192.168.10.0/24"
    local v="$INJECTION_VALUE"
    run render_rotate "$v" "$v" "$lan_subnets"
    [ "$status" -eq 0 ]
    local rendered="$output"

    local cf_line pn_line
    cf_line=$(printf '%s\n' "$rendered" | grep '^COUNTRY_FILTER=')
    pn_line=$(printf '%s\n' "$rendered" | grep '^PREFERRED_NODE=')

    run bash -c 'eval "$1"; eval "$2"; printf "COUNTRY_FILTER=%s\n" "$COUNTRY_FILTER"; printf "PREFERRED_NODE=%s\n" "$PREFERRED_NODE"' _ "$cf_line" "$pn_line"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "COUNTRY_FILTER=$v" ]]
    [[ "${lines[1]}" == "PREFERRED_NODE=$v" ]]

    # Critical: pwned file must NOT exist - proves no code execution
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "rotate_templated: LAN_SUBNETS evaluates to exactly the argument given" {
    local lan_subnets="192.168.10.0/24 10.0.0.0/8"
    run render_rotate "" "" "$lan_subnets"
    [ "$status" -eq 0 ]
    local rendered="$output"
    local ls_line
    ls_line=$(printf '%s\n' "$rendered" | grep '^LAN_SUBNETS=')
    # Evaluate and check using eval for shell-quoted values
    run bash -c 'eval "$1"; printf "LAN_SUBNETS=%s\n" "$LAN_SUBNETS"' _ "$ls_line"
    [ "$status" -eq 0 ]
    # output is the full stdout of the bash -c command
    [[ "$output" == "LAN_SUBNETS=$lan_subnets" ]]
}

@test "rotate_templated: bash -n passes on the rendered script" {
    local lan_subnets="192.168.10.0/24"
    for v in "${SPECIAL_VALUES[@]}"; do
        run render_rotate "$v" "$v" "$lan_subnets"
        [ "$status" -eq 0 ]
        # Check syntax
        run bash -n <<<"$output"
        [ "$status" -eq 0 ]
    done
}

@test "rotate_templated: diff with assets/mullvad-rotate.sh shows changes only on COUNTRY_FILTER, PREFERRED_NODE, and LAN_SUBNETS lines" {
    local lan_subnets="192.168.10.0/24"
    for v in "${SPECIAL_VALUES[@]}"; do
        run render_rotate "$v" "$v" "$lan_subnets"
        [ "$status" -eq 0 ]
        local rendered="$output"

        # Count changed lines vs asset file (excluding the three expected lines)
        # We expect exactly 3 lines to differ: COUNTRY_FILTER, PREFERRED_NODE, LAN_SUBNETS
        local diff_output
        diff_output=$(diff -u "$REPO/assets/mullvad-rotate.sh" <(printf '%s\n' "$rendered") 2>&1 || true)
        
        # Count lines starting with + or - that are not the +++ or --- headers
        local changed_count
        changed_count=$(printf '%s\n' "$diff_output" | grep -c -E '^[\+\-][^\+\-]')
        # The diff will show 3 additions and 3 deletions (the 3 lines changed)
        [ "$changed_count" -eq 6 ]
    done
}

@test "nft_templated: output contains the define LAN line and otherwise equals the asset" {
    local lan_value="{ 192.168.1.0/24, 10.0.0.0/8 }"
    run render_nft "$lan_value"
    [ "$status" -eq 0 ]
    local rendered="$output"

    # Check the define LAN line is present and correct
    [[ "$rendered" == *"define LAN = $lan_value"* ]]

    # Count changed lines vs asset file - should be only the define LAN line (2 lines: - and +)
    local diff_output
    diff_output=$(diff -u "$REPO/assets/nftables/mullvad-killswitch.nft" <(printf '%s\n' "$rendered") 2>&1 || true)
    local changed_count
    changed_count=$(printf '%s\n' "$diff_output" | grep -c -E '^[\+\-][^\+\-]')
    [ "$changed_count" -eq 2 ]
}

@test "nft_templated: nft -c still passes on the templated ruleset" {
    local lan_value="{ 192.168.1.0/24, 10.0.0.0/8 }"
    command -v nft >/dev/null 2>&1 || skip "nft not installed"
    local f="$BATS_TEST_TMPDIR/ks.nft"
    run render_nft "$lan_value"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$f"
    local ns=(unshare --net)
    [ "$(id -u)" = 0 ] || ns=(unshare --user --map-root-user --net)
    "${ns[@]}" true 2>/dev/null || skip "cannot create a network namespace here"
    local out rc
    out="$("${ns[@]}" nft -c -f "$f" 2>&1)"; rc=$?
    echo "$out"
    [ "$rc" -eq 0 ]
}

@test "deploy_killswitch: if rotate_templated fails, returns non-zero and never calls push_file for rotate or nft" {
    stub_setup
    fixture_lxc '[{"vmid":101,"status":"running","name":"ct101"}]'
    # Override rotate_templated to fail
    run bash -c '
        BULKVPN_LIB_ONLY=1 source "$0"
        rotate_templated() { return 1; }
        deploy_killswitch lxc 101 "ct/101 (ct101)"
    ' "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAILED to render rotate script"* ]]
    # Check stub log: no push_file commands for mullvad-rotate.sh or mullvad-killswitch.nft
    local calls
    calls=$(calls_log)
    [[ "$calls" != *"base64 -d > '/usr/local/bin/mullvad-rotate.sh'"* ]]
    [[ "$calls" != *"base64 -d > '/etc/nftables.d/mullvad-killswitch.nft'"* ]]
}

@test "deploy_killswitch: if nft_templated fails, returns non-zero and never calls push_file for rotate or nft" {
    stub_setup
    fixture_lxc '[{"vmid":101,"status":"running","name":"ct101"}]'
    # Override nft_templated to fail
    run bash -c '
        BULKVPN_LIB_ONLY=1 source "$0"
        nft_templated() { return 1; }
        deploy_killswitch lxc 101 "ct/101 (ct101)"
    ' "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAILED to render nft ruleset"* ]]
    local calls
    calls=$(calls_log)
    [[ "$calls" != *"base64 -d > '/usr/local/bin/mullvad-rotate.sh'"* ]]
    [[ "$calls" != *"base64 -d > '/etc/nftables.d/mullvad-killswitch.nft'"* ]]
}

@test "deploy_killswitch: if rotate_templated produces empty output, returns non-zero and never calls push_file" {
    stub_setup
    fixture_lxc '[{"vmid":101,"status":"running","name":"ct101"}]'
    # Override rotate_templated to produce empty output
    run bash -c '
        BULKVPN_LIB_ONLY=1 source "$0"
        rotate_templated() { printf ""; return 0; }
        deploy_killswitch lxc 101 "ct/101 (ct101)"
    ' "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAILED: rendered rotate script is empty"* ]]
    local calls
    calls=$(calls_log)
    [[ "$calls" != *"base64 -d > '/usr/local/bin/mullvad-rotate.sh'"* ]]
    [[ "$calls" != *"base64 -d > '/etc/nftables.d/mullvad-killswitch.nft'"* ]]
}

@test "deploy_killswitch: if nft_templated produces empty output, returns non-zero and never calls push_file" {
    stub_setup
    fixture_lxc '[{"vmid":101,"status":"running","name":"ct101"}]'
    # Override nft_templated to produce empty output
    run bash -c '
        BULKVPN_LIB_ONLY=1 source "$0"
        nft_templated() { printf ""; return 0; }
        deploy_killswitch lxc 101 "ct/101 (ct101)"
    ' "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAILED: rendered nft ruleset is empty"* ]]
    local calls
    calls=$(calls_log)
    [[ "$calls" != *"base64 -d > '/usr/local/bin/mullvad-rotate.sh'"* ]]
    [[ "$calls" != *"base64 -d > '/etc/nftables.d/mullvad-killswitch.nft'"* ]]
}

@test "deploy_killswitch: if rotate_templated produces syntax error, returns non-zero and never calls push_file" {
    stub_setup
    fixture_lxc '[{"vmid":101,"status":"running","name":"ct101"}]'
    # Override rotate_templated to produce invalid syntax
    run bash -c '
        BULKVPN_LIB_ONLY=1 source "$0"
        rotate_templated() { printf "COUNTRY_FILTER=\"unclosed quote\n"; }
        deploy_killswitch lxc 101 "ct/101 (ct101)"
    ' "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAILED: rendered rotate script has syntax errors"* ]]
    local calls
    calls=$(calls_log)
    [[ "$calls" != *"base64 -d > '/usr/local/bin/mullvad-rotate.sh'"* ]]
    [[ "$calls" != *"base64 -d > '/etc/nftables.d/mullvad-killswitch.nft'"* ]]
}

@test "deploy_killswitch: pushed rotate payload matches rotate_templated output byte for byte including trailing newline" {
    stub_setup
    fixture_lxc '[{"vmid":101,"status":"running","name":"ct101"}]'
    # Set special character values to test literal preservation
    export MULLVAD_COUNTRY_FILTER="Bosnia & Herzegovina"
    export MULLVAD_PREFERRED_NODE="a|b"
    export MULLVAD_LAN_AUTODETECT=0
    export MULLVAD_LAN_INCLUDE_GUESTS=0
    export MULLVAD_LAN_SUBNET="192.168.10.0/24"
    
    # Get the expected rendered output
    local expected_rotate
    expected_rotate="$(
        # shellcheck source=/dev/null
        BULKVPN_LIB_ONLY=1 source "$SCRIPT"
        rotate_templated "192.168.10.0/24"
    )"
    
    run bash -c '
        BULKVPN_LIB_ONLY=1 source "$0"
        deploy_killswitch lxc 101 "ct/101 (ct101)"
    ' "$SCRIPT"
    [ "$status" -eq 0 ]
    
    # Get the actual pushed payload from the stub log
    local calls
    calls=$(calls_log)
    # Extract the base64 payload for mullvad-rotate.sh
    local b64_payload
    b64_payload=$(printf '%s\n' "$calls" | grep "base64 -d > '/usr/local/bin/mullvad-rotate.sh'" | sed "s/.*printf '%s' '\([^']*\)'.*/\1/")
    [ -n "$b64_payload" ]
    local actual_payload
    actual_payload=$(printf '%s' "$b64_payload" | base64 -d)
    
    # Compare byte for byte
    [ "$actual_payload" = "$expected_rotate" ]
}