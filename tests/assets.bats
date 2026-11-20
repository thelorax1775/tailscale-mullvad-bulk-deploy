#!/usr/bin/env bats
# Drift check: the copies of the five assets embedded in bulkvpn-deploy.sh must
# be byte-identical to the files in assets/ (the source of truth).

load helpers

check_asset() {   # FUNCTION FILE
    lib "$1" > "$BATS_TEST_TMPDIR/embedded"
    run diff -u "$REPO/$2" "$BATS_TEST_TMPDIR/embedded"
    if [ "$status" -ne 0 ]; then
        echo "$1 drifted from $2 ('-' = assets/ file, '+' = text embedded in bulkvpn-deploy.sh):"
        echo "$output"
    fi
    [ "$status" -eq 0 ]
    cmp "$REPO/$2" "$BATS_TEST_TMPDIR/embedded"
}

@test "asset_rotate is byte-identical to assets/mullvad-rotate.sh" {
    check_asset asset_rotate assets/mullvad-rotate.sh
}

@test "asset_nft is byte-identical to assets/nftables/mullvad-killswitch.nft" {
    check_asset asset_nft assets/nftables/mullvad-killswitch.nft
}

@test "asset_killswitch_service is byte-identical to assets/systemd/mullvad-killswitch.service" {
    check_asset asset_killswitch_service assets/systemd/mullvad-killswitch.service
}

@test "asset_healthcheck_service is byte-identical to assets/systemd/mullvad-healthcheck.service" {
    check_asset asset_healthcheck_service assets/systemd/mullvad-healthcheck.service
}

@test "asset_healthcheck_timer is byte-identical to assets/systemd/mullvad-healthcheck.timer" {
    check_asset asset_healthcheck_timer assets/systemd/mullvad-healthcheck.timer
}

# ---- the kill-switch ruleset must parse for any LAN set ----------------------
# `nft -c` only checks; it needs a network namespace to run unprivileged.
nft_check_lan() {   # SPACE-SEPARATED SUBNETS
    command -v nft >/dev/null 2>&1 || skip "nft not installed"
    local f="$BATS_TEST_TMPDIR/ks.nft"
    BULKVPN_LIB_ONLY=1 bash -c 'source "$0" && nft_templated "$(lan_nft_set "$1")"' "$SCRIPT" "$1" > "$f"
    local ns=(unshare --net) out rc
    [ "$(id -u)" = 0 ] || ns=(unshare --user --map-root-user --net)
    "${ns[@]}" true 2>/dev/null || skip "cannot create a network namespace here"
    out="$("${ns[@]}" nft -c -f "$f" 2>&1)"; rc=$?
    echo "$out"
    [ "$rc" -eq 0 ]
}

@test "nft -c accepts the templated kill-switch for a one-subnet LAN set" {
    nft_check_lan '192.168.1.0/24'
}

@test "nft -c accepts the templated kill-switch for a five-subnet LAN set" {
    nft_check_lan '192.168.1.0/24 192.168.2.0/24 10.0.0.0/8 172.16.0.0/12 100.100.0.0/16'
}

@test "the kill-switch has no blanket established/related accept and no bare port-67 accept" {
    run grep -nE '^[[:space:]]*(ct state established|udp dport 67 accept)' "$REPO/assets/nftables/mullvad-killswitch.nft"
    [ "$status" -eq 1 ]
}

# ---- the kill-switch unit follows nftables.service ---------------------------
# Text only: the unit has NOT been exercised on a running systemd by these tests.
@test "mullvad-killswitch.service is reapplied when nftables.service restarts or reloads" {
    f="$REPO/assets/systemd/mullvad-killswitch.service"
    grep -qx 'After=nftables.service' "$f"
    grep -qx 'PartOf=nftables.service' "$f"
    grep -qx 'ReloadPropagatedFrom=nftables.service' "$f"
    grep -qx 'ExecReload=/usr/sbin/nft -f /etc/nftables.d/mullvad-killswitch.nft' "$f"
    grep -qx 'Before=network-pre.target tailscaled.service' "$f"
    grep -qx 'RemainAfterExit=yes' "$f"
    grep -qx 'ExecStart=/usr/sbin/nft -f /etc/nftables.d/mullvad-killswitch.nft' "$f"
}

@test "CMD_PROTECTED checks the kill-switch table as well as script, service and timer" {
    # shellcheck disable=SC2016  # expanded by the inner shell
    run libsh 'printf %s "$CMD_PROTECTED"'
    [[ "$output" == *"nft list table inet mullvad_killswitch"* ]]
    [[ "$output" == *"mullvad-healthcheck.timer"* ]]
}

@test "CMD_VERIFY still checks the kill-switch table" {
    # shellcheck disable=SC2016  # expanded by the inner shell
    run libsh 'printf %s "$CMD_VERIFY"'
    [[ "$output" == *"nft list table inet mullvad_killswitch"* ]]
}
