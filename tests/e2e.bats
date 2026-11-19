#!/usr/bin/env bats
# End-to-end runs of main() against stub pvesh/pct/qm (tests/stubs/pve-stub.sh).
# The stub call log shows exactly what the script asked Proxmox to do.

load helpers

setup() {
    stub_setup
    export VM_AGENT_TIMEOUT=1 LXC_READY_TIMEOUT=1
    MARK="$BATS_TEST_TMPDIR/marker"
    : > "$MARK"
    sleep 0.05
}

# Files created or changed outside the test's temp directory while the script
# ran. Only the places this script could write to are watched (the repo, the
# log default /root, and the host paths ensure_host_tun and enable_tun_lxc use);
# a whole-filesystem scan would trip over unrelated activity on a busy runner.
stray_files() {
    local d
    for d in "$REPO" /root /usr/local /etc/modules-load.d /etc/nftables.d /etc/systemd /etc/pve; do
        [ -d "$d" ] || continue
        find "$d" -xdev -type f -newer "$MARK" -not -path "$BATS_TEST_TMPDIR/*" 2>/dev/null
    done
}

@test "DRY_RUN=1: tally is right and nothing is pushed, rebooted or written" {
    fixture_lxc '[{"vmid":101,"status":"running","name":"web"},{"vmid":102,"status":"stopped","name":"old"}]'
    fixture_qemu '[{"vmid":301,"status":"running","name":"nas"}]'
    fixture_probe ct101 'bin=1 state=1 profile=1 svc=active backend=Running'
    fixture_flag ct101.mullvad
    # vm301 has no .agent fixture: the guest agent does not answer.
    DRY_RUN=1 run_main
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Done (dry run, nothing changed).  WOULD_DEPLOY=1  WOULD_ENROLL=0  WOULD_FAIL=0  SKIPPED=2  FAILED=0"* ]]
    [[ "$output" == *"[ct/101 (web)] WOULD deploy"* ]]
    [[ "$output" == *"ct/102 (old) SKIP — not running"* ]]
    [[ "$output" == *"WOULD skip — qemu-guest-agent not responding"* ]]

    run calls_log
    echo "$output"
    [[ "$output" == *"pct exec 101"* ]]          # the read-only probes did run
    [[ "$output" != *"pct push"* ]]
    [[ "$output" != *"pct reboot"* ]]
    [[ "$output" != *"qm reboot"* ]]
    [[ "$output" != *"--pass-stdin"* ]]
    [[ "$output" != *"qm guest exec"* ]]          # the unreachable VM was never entered

    # The only file written is the log, and it is inside the temp directory.
    ls "$BULKVPN_LOG_DIR"/bulkvpn-*.log
    strays="$(stray_files)"
    [ -z "$strays" ] || { echo "files written outside the temp dir: $strays"; false; }
}

@test "DRY_RUN=1: a VM that needs enrollment never gets the key even with TS_AUTHKEY set" {
    fixture_lxc '[]'
    fixture_qemu '[{"vmid":301,"status":"running","name":"nas"}]'
    fixture_flag vm301.agent
    fixture_probe vm301 'bin=1 state=0 profile=0 svc=active backend=NeedsLogin'
    TS_AUTHKEY="DRYRUN-MARKER-abc123" DRY_RUN=1 run_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD_ENROLL=1"* ]]
    run calls_log
    [[ "$output" != *"--pass-stdin"* ]]
    [[ "$output" != *"DRYRUN-MARKER-abc123"* ]]
    [ ! -e "$STUB_DIR/stdin-vm301" ]
}

@test "real run: protected guest skipped, enrollment without TS_AUTHKEY FAILED, non-Running profile left alone" {
    fixture_lxc '[{"vmid":101,"status":"running","name":"done"},{"vmid":102,"status":"running","name":"fresh"},{"vmid":103,"status":"running","name":"loggedout"}]'
    fixture_qemu '[]'
    fixture_flag ct101.protected
    fixture_probe ct102 'bin=1 state=0 profile=0 svc=active backend=NeedsLogin'
    fixture_flag ct102.mullvad
    fixture_probe ct103 'bin=1 state=1 profile=1 svc=active backend=Stopped'
    fixture_flag ct103.mullvad
    DRY_RUN=0 run_main
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Done.  SUCCESS=0  SKIPPED=2  FAILED=1"* ]]
    [[ "$output" == *"ct/101 (done)] SKIP — kill-switch already installed"* ]]
    [[ "$output" == *"ct/102 (fresh)] FAILED — guest needs Tailscale enrollment but TS_AUTHKEY is not set"* ]]
    [[ "$output" == *"ct/103 (loggedout)] SKIP — WARN: Tailscale has a login profile but its backend is Stopped"* ]]

    run calls_log
    echo "$output"
    [[ "$output" != *"pct reboot"* ]]
    [[ "$output" != *"qm reboot"* ]]
    [[ "$output" != *"pct push"* ]]               # nothing enrolled, nothing deployed
    [[ "$output" != *"tailscale up"* ]]
    [[ "$output" != *"mullvad-rotate.sh"*"base64 -d"* ]]
}

@test "real run: TS_AUTHKEY is delivered on stdin or by file and never in any stub argument" {
    local key="SECRET-MARKER-9f8e7d6c"
    fixture_lxc '[{"vmid":102,"status":"running","name":"fresh"}]'
    fixture_qemu '[{"vmid":301,"status":"running","name":"nas"}]'
    fixture_flag ct102.mullvad
    fixture_probe ct102 'bin=1 state=0 profile=0 svc=active backend=NeedsLogin'
    fixture_flag vm301.agent
    fixture_flag vm301.mullvad
    fixture_probe vm301 'bin=1 state=0 profile=0 svc=active backend=NeedsLogin'
    TS_AUTHKEY="$key" DRY_RUN=0 run_main
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Done.  SUCCESS=2  SKIPPED=0  FAILED=0"* ]]
    [[ "$output" != *"$key"* ]]                   # not in the script's own output either

    run calls_log
    echo "$output"
    [[ "$output" != *"$key"* ]]                   # in no argument of any stub call
    [[ "$output" == *"pct push 102"* ]]           # the CT got it as a file
    [[ "$output" == *"--pass-stdin 1"* ]]         # the VM got it on stdin
    [ "$(cat "$STUB_DIR/stdin-vm301")" = "$key" ] # and stdin really carried it
    [[ "$output" == *"--auth-key='file:/run/bulkvpn-ts-authkey'"* ]]
    [[ "$output" != *"pct reboot"* ]]
}
