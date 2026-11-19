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
