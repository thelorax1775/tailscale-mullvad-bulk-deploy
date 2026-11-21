#!/usr/bin/env bats
# Tests for the pre-scan which collects every running guest's LAN subnet from Proxmox config.

load helpers

bats_require_minimum_version 1.5.0

# ---- collect_guest_lans ------------------------------------------------------

@test "collect_guest_lans: full fixture with exclude, dhcp, stopped, public, private, qemu" {
    stub_setup

    # ip stub for host_bridge_subnets
    cat > "$STUB_BIN/ip" <<'IP_EOF'
#!/usr/bin/env bash
case "$*" in
    *"dev vmbr0 "*)
        echo "192.168.10.0/24 proto kernel scope link src 192.168.10.99"
        ;;
    *"dev vmbr0.20 "*)
        echo "10.20.0.0/24 proto kernel scope link src 10.20.0.1"
        ;;
esac
IP_EOF
    chmod +x "$STUB_BIN/ip"

    # LXC fixtures
    cat > "$STUB_DIR/ct101.config" <<'EOF'
net0: name=eth0,bridge=vmbr0,gw=192.168.10.1,ip=192.168.10.57/24,type=veth
EOF

    cat > "$STUB_DIR/ct102.config" <<'EOF'
net0: name=eth0,bridge=vmbr0,ip=dhcp,tag=20,type=veth
EOF

    cat > "$STUB_DIR/ct103.config" <<'EOF'
net0: name=eth0,bridge=vmbr0,ip=172.16.5.9/12
EOF

    cat > "$STUB_DIR/ct104.config" <<'EOF'
net0: name=eth0,bridge=vmbr0,ip=203.0.113.7/24
EOF

    cat > "$STUB_DIR/ct105.config" <<'EOF'
net0: name=eth0,bridge=vmbr0,ip=10.99.0.1/16
EOF

    # QEMU fixture
    cat > "$STUB_DIR/vm301.config" <<'EOF'
net0: virtio=BC:24:11:00:00:02,bridge=vmbr0
ipconfig0: ip=10.5.3.7/16,gw=10.5.0.1
EOF

    # pvesh lists
    fixture_lxc '[{"vmid":101,"status":"running","name":"web"},{"vmid":102,"status":"running","name":"dhcp"},{"vmid":103,"status":"stopped","name":"off"},{"vmid":104,"status":"running","name":"pub"},{"vmid":105,"status":"running","name":"skip"}]'
    fixture_qemu '[{"vmid":301,"status":"running","name":"vm"}]'

    # shellcheck disable=SC2016  # single quotes intentional: snippet is expanded by the inner bash
    MULLVAD_LAN_INCLUDE_GUESTS=1 MULLVAD_LAN_AGENT_QUERY=0 MULLVAD_LAN_SCAN_EXCLUDE="105" run --separate-stderr bash -c '
        BULKVPN_LIB_ONLY=1 source "$0"
        collect_guest_lans
        echo "SET=[$GUEST_LAN_SET]"
    ' "$SCRIPT"

    [ "$status" -eq 0 ]

    # Expected log lines
    [[ "$output" == *"Pre-scan: ct/101 (web) -> 192.168.10.0/24"* ]]
    [[ "$output" == *"Pre-scan: ct/102 (dhcp) -> 10.20.0.0/24"* ]]
    [[ "$output" == *"Pre-scan: ct/104 (pub) ignoring non-private subnet(s): 203.0.113.0/24"* ]]
    [[ "$output" == *"Pre-scan: ct/105 (skip) excluded by MULLVAD_LAN_SCAN_EXCLUDE"* ]]
    [[ "$output" == *"Pre-scan: vm/301 (vm) -> 10.5.0.0/16"* ]]
    [[ "$output" == *"SET=[10.20.0.0/24 10.5.0.0/16 192.168.10.0/24 ]"* ]]

    # Must not contain
    [[ "$output" != *"ct/103"* ]]
    [[ "$output" != *"203.0.113"* ]] || [[ "$output" == *"SET=[10.20.0.0/24 10.5.0.0/16 192.168.10.0/24 ]"* ]] # 203.0.113 must not be in SET
    [[ "$output" != *"10.99"* ]]

    # Stub call log verification
    run cat "$STUB_LOG"
    [[ "$output" == *"pct config 101"* ]]
    [[ "$output" == *"pct config 102"* ]]
    [[ "$output" == *"pct config 104"* ]]
    [[ "$output" == *"qm config 301"* ]]
    [[ "$output" != *"pct config 103"* ]]
    [[ "$output" != *"pct config 105"* ]]
    [[ "$output" != *"pct exec"* ]]
    [[ "$output" != *"qm guest exec"* ]]
}

# ---- pve_net_subnets ---------------------------------------------------------

@test "pve_net_subnets: ip6-only config falls back to bridge route" {
    stub_setup

    # ip stub for host_bridge_subnets
    cat > "$STUB_BIN/ip" <<'IP_EOF'
#!/usr/bin/env bash
case "$*" in
    *"dev vmbr0 "*)
        echo "192.168.10.0/24 proto kernel scope link src 192.168.10.99"
        ;;
esac
IP_EOF
    chmod +x "$STUB_BIN/ip"

    run lib pve_net_subnets 'net0: name=eth0,bridge=vmbr0,ip6=fd00::5/64,type=veth'
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.10.0/24" ]
}

# ---- vm_agent_subnets --------------------------------------------------------

@test "vm_agent_subnets: filters lo, tailscale, docker and keeps eth0 and ens19" {
    stub_setup

    # shellcheck disable=SC2016  # single quotes intentional: snippet is expanded by the inner bash
    run libsh '
        qm() {
            if [[ "$1" == "guest" && "$2" == "cmd" && "$3" == "301" && "$4" == "network-get-interfaces" ]]; then
                echo '"'"'[{"name":"lo","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"127.0.0.1","prefix":8}]},{"name":"eth0","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"192.168.10.50","prefix":24},{"ip-address-type":"ipv6","ip-address":"fe80::1","prefix":64}]},{"name":"docker0","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"172.17.0.1","prefix":16}]},{"name":"tailscale0","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"100.64.1.2","prefix":32}]},{"name":"ens19","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"10.1.2.3","prefix":8}]}]'"'"'
            fi
        }
        vm_agent_subnets 301
    '

    [ "$status" -eq 0 ]
    [ "$output" = $'192.168.10.0/24\n10.0.0.0/8' ]
}

# ---- collect_guest_lans with agent query -------------------------------------

@test "collect_guest_lans: MULLVAD_LAN_AGENT_QUERY=1 falls back to config when agent fails" {
    stub_setup

    # ip stub for host_bridge_subnets (fallback)
    cat > "$STUB_BIN/ip" <<'IP_EOF'
#!/usr/bin/env bash
case "$*" in
    *"dev vmbr0 "*)
        echo "192.168.10.0/24 proto kernel scope link src 192.168.10.99"
        ;;
esac
IP_EOF
    chmod +x "$STUB_BIN/ip"

    # QEMU fixture
    cat > "$STUB_DIR/vm301.config" <<'EOF'
net0: virtio=BC:24:11:00:00:02,bridge=vmbr0
ipconfig0: ip=10.5.3.7/16,gw=10.5.0.1
EOF

    # pvesh lists - only the one VM
    fixture_lxc '[]'
    fixture_qemu '[{"vmid":301,"status":"running","name":"vm"}]'

    # Need to define is_selected to return true for 301
    # shellcheck disable=SC2016  # single quotes intentional: snippet is expanded by the inner bash
    MULLVAD_LAN_INCLUDE_GUESTS=1 MULLVAD_LAN_AGENT_QUERY=1 SELECT_GUESTS=301 run --separate-stderr bash -c '
        BULKVPN_LIB_ONLY=1 source "$0"
        # Override qm so guest cmd ping succeeds but network-get-interfaces fails
        qm() {
            case "$*" in
                "guest cmd 301 ping") return 0 ;;
                "guest cmd 301 network-get-interfaces") echo "agent error" >&2; return 255 ;;
                "config 301") cat "$STUB_DIR/vm301.config" ;;
                *) true ;;
            esac
        }
        collect_guest_lans
        echo "SET=[$GUEST_LAN_SET]"
    ' "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Pre-scan: vm/301 (vm) -> 10.5.0.0/16"* ]]
    [[ "$output" == *"SET=[10.5.0.0/16 ]"* ]]
}