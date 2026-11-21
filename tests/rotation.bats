#!/usr/bin/env bats
# Tests for how the watchdog (assets/mullvad-rotate.sh) picks an exit node,
# keeps it and returns to the preferred node.
#
# The script under test is rendered exactly like the deploy renders it
# (bulkvpn-deploy.sh's rotate_templated), then run against stubbed
# tailscale/nft/timeout/sleep/ip commands. Nothing here touches a real host.

load helpers

bats_require_minimum_version 1.5.0

NODE_A="us-bos-wg-001.mullvad.ts.net"
NODE_B="us-nyc-wg-002.mullvad.ts.net"
NODE_C="us-chi-wg-003.mullvad.ts.net"

setup() {
    stub_setup

    ROTATE="$BATS_TEST_TMPDIR/rotate.sh"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"
    CALLS="$WORK/calls"
    CURRENT_FILE="$WORK/current"
    : > "$CALLS"

    # The nft stub makes ensure_killswitch() succeed (the kill-switch table
    # is always "present" in the test world).
    cat > "$STUB_BIN/nft" <<'EOF'
#!/bin/sh
exit 0
EOF
    # No-op sleep so switch_to() does not wait for the tunnel to settle.
    cat > "$STUB_BIN/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
    # No-op ip so the LAN bypass can never touch the real host.
    cat > "$STUB_BIN/ip" <<'EOF'
#!/bin/sh
exit 0
EOF
    # timeout() succeeds only when the currently set exit node is a GOOD one.
    cat > "$STUB_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
cur=$(cat "$W/current" 2>/dev/null)
for g in $GOOD; do
    [ "$g" = "$cur" ] && exit 0
done
exit 1
EOF
    # Stateful tailscale stub: logs every call, remembers the exit node that
    # is currently set and lists the online Mullvad nodes from $NODES.
    cat > "$STUB_BIN/tailscale" <<'EOF'
#!/usr/bin/env bash
echo "tailscale $*" >> "$W/calls"
cur=$(cat "$W/current" 2>/dev/null)
case "$1" in
    status)
        if [ -n "$cur" ]; then
            printf '{"Peer":{"k":{"DNSName":"%s.","ExitNode":true}}}' "$cur"
        else
            echo '{}'
        fi
        ;;
    exit-node)
        echo "IP HOSTNAME COUNTRY CITY STATUS"
        for n in $NODES; do
            echo " 100.1.1.1  $n  USA  X  -"
        done
        echo " 100.1.1.9  us-off-wg-009.mullvad.ts.net  USA  X  offline"
        ;;
    set)
        v="${2#--exit-node=}"
        printf '%s' "$v" > "$W/current"
        ;;
esac
EOF
    chmod +x "$STUB_BIN/nft" "$STUB_BIN/sleep" "$STUB_BIN/ip" "$STUB_BIN/timeout" "$STUB_BIN/tailscale"

    export W="$WORK"
    export NODES=""
    export GOOD=""
}

# render_rotate PREFERRED COUNTRY: render the watchdog through the deploy
# script's templating (so PREFERRED_NODE/COUNTRY_FILTER are baked in) and
# shorten the timeouts as setup_watchdog does.
render_rotate() {
    MULLVAD_PREFERRED_NODE="$1" MULLVAD_COUNTRY_FILTER="$2" \
        run lib rotate_templated ""
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$ROTATE"
    sed -i -e 's/^CHECK_TIMEOUT=.*/CHECK_TIMEOUT=2/' \
           -e 's/^TUNNEL_SETTLE=.*/TUNNEL_SETTLE=0/' "$ROTATE"
    chmod +x "$ROTATE"
}

# run_rotate MODE: MODE is "check" (--check-only) or "normal" (no argument).
run_rotate() {
    local -a args=()
    [ "$1" = "check" ] && args=(--check-only)
    : > "$CALLS"
    if [ -n "${CURRENT_NODE:-}" ]; then
        printf '%s' "$CURRENT_NODE" > "$CURRENT_FILE"
    else
        rm -f "$CURRENT_FILE"
    fi
    run env W="$WORK" NODES="$NODES" GOOD="$GOOD" \
        MULLVAD_NFT="$STUB_BIN/nft" MULLVAD_LOG_FILE="$WORK/rotate.log" \
        PATH="$STUB_BIN:$PATH" bash "$ROTATE" "${args[@]}"
}

# set_calls: the "tailscale set" lines of the call log.
set_calls() {
    grep '^tailscale set' "$CALLS" || true
}

# trying_lines: the target of every "Trying" line in the output.
trying_lines() {
    printf '%s\n' "$output" | grep 'Trying ' || true
}

@test "rotation: check-only on the preferred node does nothing" {
    NODES="$NODE_A $NODE_B $NODE_C"
    GOOD="$NODE_A"
    CURRENT_NODE="$NODE_A"
    render_rotate "$NODE_A" ""

    run_rotate check

    [ "$status" -eq 0 ]
    [[ "$output" == *"check-only: tunnel healthy, no action"* ]]
    [ -z "$(set_calls)" ]
}

@test "rotation: check-only returns to the preferred node" {
    NODES="$NODE_A $NODE_B $NODE_C"
    GOOD="$NODE_A $NODE_B"
    CURRENT_NODE="$NODE_B"
    render_rotate "$NODE_A" ""

    run_rotate check

    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: back on preferred us-bos-wg-001.mullvad.ts.net"* ]]
    [ "$(set_calls)" = "tailscale set --exit-node=us-bos-wg-001.mullvad.ts.net --exit-node-allow-lan-access=true" ]
}

@test "rotation: check-only falls back to the current node when the preferred one fails" {
    NODES="$NODE_A $NODE_B $NODE_C"
    GOOD="$NODE_B"
    CURRENT_NODE="$NODE_B"
    render_rotate "$NODE_A" ""

    run_rotate check

    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN: preferred us-bos-wg-001.mullvad.ts.net not working, returning to us-nyc-wg-002.mullvad.ts.net"* ]]
    [[ "$output" == *"OK: staying on fallback us-nyc-wg-002.mullvad.ts.net"* ]]
    [ "$(set_calls)" = "tailscale set --exit-node=us-bos-wg-001.mullvad.ts.net --exit-node-allow-lan-access=true
tailscale set --exit-node=
tailscale set --exit-node=us-nyc-wg-002.mullvad.ts.net --exit-node-allow-lan-access=true" ]
}

@test "rotation: check-only with no working node tries preferred, then current, and fails closed" {
    NODES="$NODE_A $NODE_B $NODE_C"
    GOOD=""
    CURRENT_NODE="$NODE_B"
    render_rotate "$NODE_A" ""

    run_rotate check

    [ "$status" -eq 1 ]
    [[ "$output" == *"NO connectivity detected"* ]]
    [[ "$output" == *"Selecting from 3 candidates"* ]]
    [[ "$output" == *"exhausted 3 candidates"* ]]
    local first last
    first="$(trying_lines | head -n1)"
    last="$(trying_lines | tail -n1)"
    [[ "$first" == *"$NODE_A"* ]]
    [[ "$last" == *"$NODE_B"* ]]
    run set_calls
    [[ "$output" != *"us-off-wg-009"* ]]
}

@test "rotation: a normal run picks the preferred node" {
    NODES="$NODE_A $NODE_B $NODE_C"
    GOOD="$NODE_A $NODE_B $NODE_C"
    CURRENT_NODE="$NODE_B"
    render_rotate "$NODE_A" ""

    run_rotate normal

    [ "$status" -eq 0 ]
    [ "$(trying_lines | wc -l)" -eq 1 ]
    [[ "$(trying_lines)" == *"$NODE_A"* ]]
    [ "$(set_calls | wc -l)" -eq 1 ]
}

@test "rotation: the country filter is passed to tailscale exit-node list" {
    NODES="$NODE_A $NODE_B $NODE_C"
    GOOD="$NODE_A $NODE_B $NODE_C"
    CURRENT_NODE="$NODE_B"
    render_rotate "$NODE_A" "USA"

    run_rotate normal

    [ "$status" -eq 0 ]
    grep -q '^tailscale exit-node list --filter=USA$' "$CALLS"
}

@test "rotation: no online node for the country filter is fatal and changes nothing" {
    NODES=""
    GOOD=""
    CURRENT_NODE="$NODE_B"
    render_rotate "$NODE_A" "USA"

    run_rotate normal

    [ "$status" -eq 1 ]
    [[ "$output" == *"no online Mullvad exit nodes found for 'USA'"* ]]
    [ -z "$(set_calls)" ]
}
