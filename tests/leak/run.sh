#!/usr/bin/env bash
# Leak test rig for the kill-switch.
#
# Loads the REAL ruleset (assets, templated by the real nft_templated() and
# lan_nft_set() from bulkvpn-deploy.sh) inside throwaway namespaces and counts
# which packets reach the "physical" side. Nothing outside the namespaces is
# touched: no interface, route, firewall rule or file on the machine changes.
#
# Usage:  tests/leak/run.sh            (normally through ./check.sh)
# Needs:  nft, ip, unshare, python3, timeout, and either root (directly or
#         through passwordless sudo) or unprivileged user namespaces.
# Exit:   0 all cases passed, 1 a case failed or the rig broke,
#         77 the namespaces could not be created (outside CI only; with
#         CI=true that is exit 1, so CI never skips the rig).
#
# Topology (all fake):
#   G = the protected guest.  eth0 192.168.50.2/24, gateway .1  ("physical" NIC)
#                             tailscale0 100.64.0.2             (fake tunnel)
#       Policy routing like Tailscale: rule 5270 -> table 52, whose default
#       route points into tailscale0 while an exit node is selected.
#   W = "the world": LAN router 192.168.50.1 on weth, tunnel far end on wts,
#       internet hosts 203.0.113.10 and 2001:db8::10 on a dummy interface.
#       Counters in W record what arrives over weth (= left G through eth0)
#       and over wts (= left G through the tunnel).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"

cannot_run() {   # reason
    if [[ "${CI:-}" == "true" ]]; then
        echo "leak rig: FAILED - $1 (CI=true, so this is an error, not a skip)" >&2
        exit 1
    fi
    echo "leak rig: cannot run - $1" >&2
    exit 77
}

if [[ "${BULKVPN_LEAK_IN_NS:-}" != "1" ]]; then
    for tool in nft ip unshare python3 timeout; do
        command -v "$tool" >/dev/null 2>&1 || cannot_run "required tool not found: $tool"
    done
    # A PID namespace with --kill-child means every process the rig starts dies
    # with it, and the network namespaces and veth pairs vanish with them.
    ns_flags=(--net --mount --pid --fork --kill-child --mount-proc)
    if [[ "$(id -u)" == "0" ]] && unshare "${ns_flags[@]}" true 2>/dev/null; then
        exec env BULKVPN_LEAK_IN_NS=1 unshare "${ns_flags[@]}" bash "$SELF"
    elif unshare --user --map-root-user "${ns_flags[@]}" true 2>/dev/null; then
        exec env BULKVPN_LEAK_IN_NS=1 unshare --user --map-root-user "${ns_flags[@]}" bash "$SELF"
    elif [[ "$(id -u)" != "0" ]] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        exec sudo -n env "PATH=$PATH" "CI=${CI:-}" bash "$SELF"
    fi
    cannot_run "could not create network namespaces (need root, passwordless sudo, or unprivileged user namespaces)"
fi

### ---- everything below runs inside the private namespaces -------------------
broken() { echo "leak rig: BROKEN - $1" >&2; exit 1; }

# A private /run: `ip netns` keeps its handles in /run/netns, and the rig uses
# /run/rig as scratch space. Both disappear with the mount namespace.
mount -t tmpfs tmpfs /run || broken "cannot mount a private /run"
mkdir -p /run/netns /run/rig

ip netns add G || broken "cannot create the guest namespace"
ip link set lo up
ip link add weth type veth peer name eth0 netns G || broken "cannot create the veth pair for eth0"
ip link add wts type veth peer name tailscale0 netns G || broken "cannot create the veth pair for tailscale0"
ip link add inet0 type dummy || broken "cannot create the dummy internet interface"
ip addr add 192.168.50.1/24 dev weth
ip link set weth up
ip link set wts up
ip link set inet0 up
ip addr add 203.0.113.10/32 dev inet0
ip -6 addr add 2001:db8::10/128 dev inet0 nodad
ip -6 addr add fd50::1/64 dev weth nodad
ip route add 100.64.0.2/32 dev wts
sysctl -qw net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.weth.rp_filter=0 \
    net.ipv4.conf.wts.rp_filter=0 2>/dev/null

g() { ip netns exec G "$@"; }
g ip link set lo up
g ip addr add 192.168.50.2/24 dev eth0
g ip link set eth0 up
g ip -6 addr add fd50::2/64 dev eth0 nodad
g ip route add default via 192.168.50.1
g ip -6 route add default via fd50::1
g ip addr add 100.64.0.2/32 dev tailscale0
g ip link set tailscale0 up
g ip rule add priority 5270 lookup 52
# What selecting / clearing an exit node does to the guest's routing.
tunnel_up()   { g ip route replace default dev tailscale0 table 52; }
tunnel_down() { g ip route del default dev tailscale0 table 52 2>/dev/null; true; }

# Counters in W: what arrived from G, and over which path.
nft -f - <<'EOF' || broken "cannot load the counter table"
table inet watch {
    counter phys_inet {}
    counter phys_inet6 {}
    counter phys_lan {}
    counter tun_inet {}
    chain pre { type filter hook prerouting priority -300;
        iifname "weth" ip daddr 203.0.113.10 counter name phys_inet
        iifname "weth" ip6 daddr 2001:db8::10 counter name phys_inet6
        iifname "weth" ip daddr 192.168.50.1 tcp dport 443 counter name phys_lan
        iifname "wts" ip daddr 203.0.113.10 counter name tun_inet
    }
}
EOF
count() { nft list counter inet watch "$1" | sed -n 's/.*packets \([0-9]*\).*/\1/p'; }
reset() { nft reset counters table inet watch >/dev/null; }

# TCP servers in W: an internet host and the LAN router.
python3 - <<'EOF' &
import socket, threading, time
def serve(ip):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((ip, 443))
    s.listen(8)
    while True:
        c, _ = s.accept()
        c.close()
for ip in ("203.0.113.10", "192.168.50.1"):
    threading.Thread(target=serve, args=(ip,), daemon=True).start()
time.sleep(300)
EOF
SRV=$!
trap 'kill "$SRV" 2>/dev/null' EXIT
tcp_w() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/443" 2>/dev/null; }          # from W itself
tcp_g() { g timeout 3 bash -c "exec 3<>/dev/tcp/$1/443" 2>/dev/null; }        # from the guest
udp6_g() { g timeout 3 python3 -c 'import socket,sys
s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.sendto(b"x", (sys.argv[1], 9999))' "$1" 2>/dev/null; }
for _ in $(seq 50); do
    tcp_w 203.0.113.10 && tcp_w 192.168.50.1 && break
    sleep 0.1
done
if ! { tcp_w 203.0.113.10 && tcp_w 192.168.50.1; }; then broken "the test servers did not start"; fi

pass=0; fail=0
result() {   # ok|bad  name  detail
    if [[ "$1" == "ok" ]]; then
        echo "PASS  $2 ($3)"; pass=$((pass + 1))
    else
        echo "FAIL  $2 ($3)"; fail=$((fail + 1))
    fi
}

### ---- self-check: without the kill-switch the rig must SEE a leak ----------
# If these fail, a "0 packets" result below would prove nothing.
tunnel_down; reset
tcp_g 203.0.113.10; rc=$?
n="$(count phys_inet)"
if [[ "$rc" == 0 && "$n" -gt 0 ]]; then
    result ok "self-check: no kill-switch, tunnel down, TCP to the internet is seen on the physical side" "$n packets counted"
else
    result bad "self-check: no kill-switch, tunnel down, TCP to the internet is seen on the physical side" "connect rc=$rc, $n packets counted - the rig cannot detect a leak"
fi
reset
n=0
for _ in 1 2 3 4 5; do      # the first packet may wait for neighbour discovery
    udp6_g 2001:db8::10
    sleep 0.3
    n="$(count phys_inet6)"
    [[ "$n" -gt 0 ]] && break
done
if [[ "$n" -gt 0 ]]; then
    result ok "self-check: no kill-switch, IPv6 to a global address is seen on the physical side" "$n packets counted"
else
    result bad "self-check: no kill-switch, IPv6 to a global address is seen on the physical side" "0 packets counted - the rig cannot detect an IPv6 leak"
fi

### ---- load the real ruleset through the real templating functions ----------
BULKVPN_LIB_ONLY=1 bash -c 'source "$0" && nft_templated "$(lan_nft_set "192.168.50.0/24")"' \
    "$REPO/bulkvpn-deploy.sh" > /run/rig/killswitch.nft \
    || broken "could not template the ruleset from bulkvpn-deploy.sh"
g nft -f /run/rig/killswitch.nft || broken "the templated ruleset failed to load"
g nft list table inet mullvad_killswitch >/dev/null 2>&1 || broken "the kill-switch table is missing after loading"
echo "ruleset loaded from bulkvpn-deploy.sh: $(g nft list table inet mullvad_killswitch | grep -c 'policy drop') chains with policy drop, LAN = { 192.168.50.0/24 }"

### ---- control cases ---------------------------------------------------------
tunnel_down; reset
tcp_g 203.0.113.10; rc=$?
sleep 0.3
n="$(count phys_inet)"
if [[ "$n" == 0 && "$rc" != 0 ]]; then
    result ok "tunnel down: new TCP connection to the internet is blocked" "0 packets on the physical side"
else
    result bad "tunnel down: new TCP connection to the internet is blocked" "LEAK: $n packets on the physical side, connect rc=$rc"
fi

reset
udp6_g 2001:db8::10
sleep 0.3
n="$(count phys_inet6)"
if [[ "$n" == 0 ]]; then
    result ok "tunnel down: new IPv6 packet to a global address is blocked" "0 packets on the physical side"
else
    result bad "tunnel down: new IPv6 packet to a global address is blocked" "LEAK: $n packets on the physical side"
fi

reset
tcp_g 192.168.50.1; rc=$?
n="$(count phys_lan)"
if [[ "$rc" == 0 && "$n" -gt 0 ]]; then
    result ok "tunnel down: TCP connection to a LAN address succeeds" "$n packets on the physical side, as intended"
else
    result bad "tunnel down: TCP connection to a LAN address succeeds" "connect rc=$rc, $n packets counted"
fi

tunnel_up; reset
tcp_g 203.0.113.10; rc=$?
tun="$(count tun_inet)"; phys="$(count phys_inet)"
if [[ "$rc" == 0 && "$tun" -gt 0 && "$phys" == 0 ]]; then
    result ok "tunnel up: TCP connection to the internet succeeds through tailscale0" "$tun packets through the tunnel, 0 on the physical side"
else
    result bad "tunnel up: TCP connection to the internet succeeds through tailscale0" "connect rc=$rc, $tun packets through the tunnel, $phys on the physical side"
fi

echo "leak rig: $pass passed, $fail failed"
[[ "$fail" == 0 ]]
