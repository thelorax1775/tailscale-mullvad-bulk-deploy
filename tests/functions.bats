#!/usr/bin/env bats
# Unit tests for the pure helper functions of bulkvpn-deploy.sh.

load helpers

bats_require_minimum_version 1.5.0

# ---- ts_classify -------------------------------------------------------------

@test "ts_classify: backend Running is ready" {
    run lib ts_classify 'bin=1 state=1 profile=1 svc=active backend=Running'
    [ "$status" -eq 0 ]
    [ "$output" = "ready|" ]
}

@test "ts_classify: no binary and no state is install" {
    run lib ts_classify 'bin=0 state=0 profile=0 svc=none backend=unknown'
    [ "$status" -eq 0 ]
    [ "$output" = "install|" ]
}

@test "ts_classify: binary present and NeedsLogin is enroll" {
    run lib ts_classify 'bin=1 state=0 profile=0 svc=active backend=NeedsLogin'
    [ "$status" -eq 0 ]
    [ "$output" = "enroll|" ]
}

@test "ts_classify: keep, login profile but status unreadable" {
    run lib ts_classify 'bin=1 state=1 profile=1 svc=active backend=unknown'
    [ "$output" = "keep|Tailscale has a login profile but its status could not be read after retries (tailscaled: active)" ]
}

@test "ts_classify: keep, login profile but backend not Running" {
    run lib ts_classify 'bin=1 state=1 profile=1 svc=inactive backend=Stopped'
    [ "$output" = "keep|Tailscale has a login profile but its backend is Stopped (tailscaled: inactive)" ]
}

@test "ts_classify: keep, state directory without the binary" {
    run lib ts_classify 'bin=0 state=1 profile=0 svc=none backend=unknown'
    [ "$output" = "keep|/var/lib/tailscale holds state but the tailscale binary is missing" ]
}

@test "ts_classify: keep, installed but status unreadable" {
    run lib ts_classify 'bin=1 state=0 profile=0 svc=failed backend=unknown'
    [ "$output" = "keep|tailscale is installed but its status could not be read after retries (tailscaled: failed)" ]
}

@test "ts_classify: keep, installed but backend not Running" {
    run lib ts_classify 'bin=1 state=0 profile=0 svc=active backend=Stopped'
    [ "$output" = "keep|tailscale is installed but its backend is Stopped (tailscaled: active)" ]
}

@test "ts_classify: an unparseable probe is keep" {
    run lib ts_classify 'bash: tailscale: command not found'
    [ "$status" -eq 0 ]
    [ "$output" = "keep|could not read Tailscale state from the guest" ]
}

@test "ts_classify: an empty probe is keep" {
    run lib ts_classify ''
    [ "$output" = "keep|could not read Tailscale state from the guest" ]
}

# ---- cidr_network ------------------------------------------------------------

@test "cidr_network: host bits are cleared" {
    run lib cidr_network 192.168.1.77/24
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.0/24" ]
    run lib cidr_network 10.20.30.40/12
    [ "$output" = "10.16.0.0/12" ]
}

@test "cidr_network: /0 becomes 0.0.0.0/0" {
    run lib cidr_network 10.1.2.3/0
    [ "$status" -eq 0 ]
    [ "$output" = "0.0.0.0/0" ]
}

@test "cidr_network: /32 is kept as is" {
    run lib cidr_network 1.2.3.4/32
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3.4/32" ]
}

@test "cidr_network: an octet of 256 is rejected" {
    run lib cidr_network 10.0.0.256/24
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "cidr_network: prefix 33 is rejected" {
    run lib cidr_network 10.0.0.1/33
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "cidr_network: text that is not a CIDR is rejected" {
    run lib cidr_network dhcp
    [ "$status" -eq 1 ]
}

# ---- private_cidr_filter -----------------------------------------------------

@test "private_cidr_filter keeps RFC1918 and drops everything else" {
    run lib private_cidr_filter <<'IN'
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
100.64.0.0/10
8.8.8.0/24
172.32.0.0/16
IN
    [ "$status" -eq 0 ]
    [ "$output" = $'10.0.0.0/8\n172.16.0.0/12\n192.168.0.0/16' ]
}

@test "private_cidr_filter drops a private range with a prefix shorter than its block" {
    run lib private_cidr_filter <<'IN'
10.0.0.0/7
172.16.0.0/11
192.168.0.0/15
IN
    [ -z "$output" ]
}

# ---- resolve_lan_list --------------------------------------------------------

@test "resolve_lan_list: guest auto-detected non-private subnets are ignored and logged" {
    MULLVAD_LAN_AUTODETECT=1 MULLVAD_LAN_INCLUDE_GUESTS=0 MULLVAD_LAN_SUBNET="" run --separate-stderr libsh '
        run_guest() { echo "0.0.0.0/1 128.0.0.0/1 192.168.10.0/24"; }
        resolve_lan_list lxc 101
    '
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.10.0/24" ]
    # shellcheck disable=SC2154
    [[ "$stderr" == *"ignoring non-private subnet(s): 0.0.0.0/1 128.0.0.0/1"* ]]
}

@test "resolve_lan_list: only non-private auto-detected subnets falls back to RFC1918" {
    MULLVAD_LAN_AUTODETECT=1 MULLVAD_LAN_INCLUDE_GUESTS=0 MULLVAD_LAN_SUBNET="" run --separate-stderr libsh '
        run_guest() { echo "0.0.0.0/1 128.0.0.0/1"; }
        resolve_lan_list lxc 101
    '
    [ "$status" -eq 0 ]
    [ "$output" = "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16" ]
    # shellcheck disable=SC2154
    [[ "$stderr" == *"ignoring non-private subnet(s): 0.0.0.0/1 128.0.0.0/1"* ]]
}

@test "resolve_lan_list: MULLVAD_LAN_SUBNET invalid CIDR /0 exits non-zero" {
    stub_setup
    MULLVAD_LAN_AUTODETECT=0 MULLVAD_LAN_INCLUDE_GUESTS=0 MULLVAD_LAN_SUBNET="0.0.0.0/0" run libsh '
        resolve_lan_list lxc 101
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *"MULLVAD_LAN_SUBNET"* ]]
    [[ "$output" == *"0.0.0.0/0"* ]]
}

@test "resolve_lan_list: MULLVAD_LAN_SUBNET invalid prefix /33 exits non-zero" {
    stub_setup
    MULLVAD_LAN_AUTODETECT=0 MULLVAD_LAN_INCLUDE_GUESTS=0 MULLVAD_LAN_SUBNET="10.0.0.0/33" run libsh '
        resolve_lan_list lxc 101
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *"MULLVAD_LAN_SUBNET"* ]]
    [[ "$output" == *"10.0.0.0/33"* ]]
}

@test "resolve_lan_list: MULLVAD_LAN_SUBNET invalid format exits non-zero" {
    stub_setup
    MULLVAD_LAN_AUTODETECT=0 MULLVAD_LAN_INCLUDE_GUESTS=0 MULLVAD_LAN_SUBNET="foo/24" run libsh '
        resolve_lan_list lxc 101
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *"MULLVAD_LAN_SUBNET"* ]]
    [[ "$output" == *"foo/24"* ]]
}

@test "resolve_lan_list: valid MULLVAD_LAN_SUBNET entries work (incl. non-private)" {
    stub_setup
    MULLVAD_LAN_AUTODETECT=0 MULLVAD_LAN_INCLUDE_GUESTS=0 MULLVAD_LAN_SUBNET="10.0.10.0/24, 203.0.113.0/24" run libsh '
        resolve_lan_list lxc 101
    '
    [ "$status" -eq 0 ]
    # sort -u order: 10.0.10.0/24 comes before 203.0.113.0/24
    [ "$output" = "10.0.10.0/24 203.0.113.0/24" ]
}

@test "validate_lan_extras: glob metacharacters are not expanded and are rejected with literal value" {
    stub_setup
    # Create a file that would match if glob expansion happened
    touch "$BATS_TEST_TMPDIR/192.168.1.0_24"
    MULLVAD_LAN_AUTODETECT=0 MULLVAD_LAN_INCLUDE_GUESTS=0 MULLVAD_LAN_SUBNET="1*2.168.1.0/24" run libsh '
        validate_lan_extras
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *"MULLVAD_LAN_SUBNET"* ]]
    [[ "$output" == *"1*2.168.1.0/24"* ]]
}

# ---- lan_nft_set -------------------------------------------------------------

@test "lan_nft_set: several subnets become an nft set literal" {
    run lib lan_nft_set '192.168.1.0/24 192.168.2.0/24 10.0.0.0/8'
    [ "$status" -eq 0 ]
    [ "$output" = "{ 192.168.1.0/24, 192.168.2.0/24, 10.0.0.0/8 }" ]
}

@test "lan_nft_set: one subnet" {
    run lib lan_nft_set '192.168.1.0/24'
    [ "$output" = "{ 192.168.1.0/24 }" ]
}

@test "lan_nft_set: words that are not subnets are dropped" {
    run lib lan_nft_set '192.168.1.0/24 junk 10.0.0.0/8'
    [ "$output" = "{ 192.168.1.0/24, 10.0.0.0/8 }" ]
}

# ---- sanitize_hostname -------------------------------------------------------

@test "sanitize_hostname: unusual characters become single dashes" {
    run lib sanitize_hostname 'ct-My Web_Server!'
    [ "$output" = "ct-My-Web-Server" ]
}

@test "sanitize_hostname: leading and trailing dashes are removed, runs collapse" {
    run lib sanitize_hostname '..a///b..'
    [ "$output" = "a-b" ]
}

@test "sanitize_hostname: a clean name is unchanged" {
    run lib sanitize_hostname 'vm-plex-01'
    [ "$output" = "vm-plex-01" ]
}

# ---- is_selected -------------------------------------------------------------

@test "is_selected: an id in the set matches" {
    run libsh 'SELECTED_IDS="10 100 200"; is_selected 100'
    [ "$status" -eq 0 ]
}

@test "is_selected: id 10 does not match 100" {
    run libsh 'SELECTED_IDS="100 200"; is_selected 10'
    [ "$status" -eq 1 ]
}

@test "is_selected: id 100 does not match 10 or 1000" {
    run libsh 'SELECTED_IDS="10 1000"; is_selected 100'
    [ "$status" -eq 1 ]
}

@test "is_selected: an empty set matches nothing" {
    run libsh 'SELECTED_IDS=""; is_selected 1'
    [ "$status" -eq 1 ]
}

# ---- select_guests -----------------------------------------------------------

@test "select_guests: SELECT_GUESTS with a running, a stopped and an unknown id" {
    stub_setup
    fixture_lxc '[{"vmid":100,"status":"running","name":"web"},{"vmid":101,"status":"stopped","name":"old"}]'
    fixture_qemu '[{"vmid":200,"status":"running","name":"vm"}]'
    # shellcheck disable=SC2016  # single quotes intentional: snippet is expanded by the inner bash
    SELECT_GUESTS="100,101 999" run libsh 'select_guests; echo "SELECTED=[$SELECTED_IDS]"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"SELECTED=[100]"* ]]
    [[ "$output" == *"WARN: SELECT_GUESTS id '101' is not a running guest"* ]]
    [[ "$output" == *"WARN: SELECT_GUESTS id '999' is not a running guest"* ]]
}

@test "select_guests: several running ids come back sorted and de-duplicated" {
    stub_setup
    fixture_lxc '[{"vmid":100,"status":"running","name":"web"}]'
    fixture_qemu '[{"vmid":200,"status":"running","name":"vm"}]'
    # shellcheck disable=SC2016  # single quotes intentional: snippet is expanded by the inner bash
    SELECT_GUESTS="200 100 200" run libsh 'select_guests; echo "SELECTED=[$SELECTED_IDS]"'
    [[ "$output" == *"SELECTED=[100 200]"* ]]
}

@test "select_guests: only stopped and unknown ids is fatal" {
    stub_setup
    fixture_lxc '[{"vmid":100,"status":"running","name":"web"},{"vmid":101,"status":"stopped","name":"old"}]'
    SELECT_GUESTS="101 999" run libsh 'select_guests'
    [ "$status" -eq 1 ]
    [[ "$output" == *"SELECT_GUESTS matched no running guests"* ]]
}

@test "select_guests: with no terminal and no SELECT_GUESTS every running guest is chosen" {
    stub_setup
    fixture_lxc '[{"vmid":100,"status":"running","name":"web"},{"vmid":101,"status":"stopped","name":"old"}]'
    fixture_qemu '[{"vmid":200,"status":"running","name":"vm"}]'
    run bash -c 'BULKVPN_LIB_ONLY=1 source "$0" && select_guests && echo "SELECTED=[$SELECTED_IDS]"' "$SCRIPT" < /dev/null
    [[ "$output" == *"SELECTED=[100 200 ]"* ]]
}
