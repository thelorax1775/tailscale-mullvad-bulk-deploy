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
        exec sudo -n env "PATH=$PATH" "CI=${CI:-}" "BULKVPN_LEAK_PHYS=${BULKVPN_LEAK_PHYS:-eth0}" bash "$SELF"
    fi
    cannot_run "could not create network namespaces (need root, passwordless sudo, or unprivileged user namespaces)"
fi

### ---- everything below runs inside the private namespaces -------------------
PHYS="${BULKVPN_LEAK_PHYS:-eth0}"   # the guest's physical NIC; check.sh also runs the rig with BULKVPN_LEAK_PHYS=br-up
broken() { echo "leak rig: BROKEN - $1" >&2; exit 1; }

# A private /run: `ip netns` keeps its handles in /run/netns, and the rig uses
# /run/rig as scratch space. Both disappear with the mount namespace.
mount -t tmpfs tmpfs /run || broken "cannot mount a private /run"
mkdir -p /run/netns /run/rig

ip netns add G || broken "cannot create the guest namespace"
ip link set lo up
ip link add weth type veth peer name "$PHYS" netns G || broken "cannot create the veth pair for $PHYS"
ip link add wts type veth peer name tailscale0 netns G || broken "cannot create the veth pair for tailscale0"
ip link add inet0 type dummy || broken "cannot create the dummy internet interface"
ip addr add 192.168.50.1/24 dev weth
ip link set weth up
ip link set wts up
ip link set inet0 up
ip addr add 203.0.113.10/32 dev inet0
ip addr add 1.1.1.1/32 dev inet0     # the rotate script's connectivity probes
ip addr add 9.9.9.9/32 dev inet0
ip -6 addr add 2001:db8::10/128 dev inet0 nodad
ip -6 addr add fd50::1/64 dev weth nodad
ip route add 100.64.0.2/32 dev wts
ip addr add 100.64.0.1/32 dev wts   # the tunnel's far end, for inbound-over-tunnel cases
sysctl -qw net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.weth.rp_filter=0 \
    net.ipv4.conf.wts.rp_filter=0 2>/dev/null

g() { ip netns exec G "$@"; }
g ip link set lo up
g ip addr add 192.168.50.2/24 dev "$PHYS"
g ip link set "$PHYS" up
g ip -6 addr add fd50::2/64 dev "$PHYS" nodad
g ip route add default via 192.168.50.1
g ip -6 route add default via fd50::1
g ip addr add 100.64.0.2/32 dev tailscale0
g ip link set tailscale0 up
g ip rule add priority 5270 lookup 52
# A third namespace behind the guest: stand-in for a Docker container. The guest
# forwards its traffic and masquerades what leaves through tailscale0 (the NAT
# table is loaded only for the forwarded case, see below).
ip netns add C || broken "cannot create the container namespace"
g ip link add docker0 type veth peer name cveth netns C || broken "cannot create the container veth pair"
g ip addr add 172.17.0.1/24 dev docker0
g ip link set docker0 up
c() { ip netns exec C "$@"; }
c ip link set lo up
c ip addr add 172.17.0.2/24 dev cveth
c ip link set cveth up
c ip route add default via 172.17.0.1
g sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.docker0.rp_filter=0 net.ipv4.conf.tailscale0.rp_filter=0 net.ipv4.conf."$PHYS".rp_filter=0 2>/dev/null
# What selecting / clearing an exit node does to the guest's routing.
# Table 52 sits ahead of the main table, so (like the LAN bypass routes the
# rotate script adds) the container bridge needs a route of its own in it.
tunnel_up()   { g ip route replace default dev tailscale0 table 52; g ip route replace 172.17.0.0/24 dev docker0 table 52; }
tunnel_down() { g ip route del default dev tailscale0 table 52 2>/dev/null; true; }

# Counters in W: what arrived from G, and over which path.
nft -f - <<'EOF' || broken "cannot load the counter table"
table inet watch {
    counter phys_inet {}
    counter phys_inet6 {}
    counter phys_lan {}
    counter tun_inet {}
    counter phys_udp67 {}
    counter phys_udp67_6 {}
    counter phys_dhcp {}
    counter phys_tsrc {}
    counter tun_in_reply {}
    counter phys_probe {}
    counter tun_probe {}
    chain pre { type filter hook prerouting priority -300;
        iifname "weth" ip daddr 203.0.113.10 counter name phys_inet
        iifname "weth" ip6 daddr 2001:db8::10 counter name phys_inet6
        iifname "weth" ip daddr 192.168.50.1 tcp dport 443 counter name phys_lan
        iifname "wts" ip daddr 203.0.113.10 counter name tun_inet
        iifname "weth" udp dport 67 ip daddr 203.0.113.10 counter name phys_udp67
        iifname "weth" udp dport 67 ip6 daddr 2001:db8::10 counter name phys_udp67_6
        iifname "weth" udp sport 68 udp dport 67 ip daddr 255.255.255.255 counter name phys_dhcp
        iifname "weth" ip saddr 100.64.0.0/10 counter name phys_tsrc
        iifname "wts" ip saddr 100.64.0.2 ip daddr 100.64.0.1 counter name tun_in_reply
        iifname "weth" ip daddr { 1.1.1.1, 9.9.9.9 } counter name phys_probe
        iifname "wts" ip daddr { 1.1.1.1, 9.9.9.9 } counter name tun_probe
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
def hold(ip, port):          # accepts, then reads until the peer goes away
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((ip, port))
    s.listen(8)
    def drain(c):
        try:
            while c.recv(4096):
                pass
        except OSError:
            pass
    while True:
        c, _ = s.accept()
        threading.Thread(target=drain, args=(c,), daemon=True).start()
for ip in ("203.0.113.10", "192.168.50.1", "1.1.1.1", "9.9.9.9"):
    threading.Thread(target=serve, args=(ip,), daemon=True).start()
threading.Thread(target=hold, args=("203.0.113.10", 8443), daemon=True).start()
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

### ---- leaks that were open before: flows that outlive the tunnel route -----
# A client keeps writing to a socket that was opened through the tunnel while
# the harness removes the table-52 default route (what clearing the exit node
# does). An "established" accept ahead of the interface check lets the
# re-routed packets out of the physical NIC.
LONG_CLIENT='import socket, sys, time
s = socket.socket()
s.settimeout(3)
s.connect(("203.0.113.10", 8443))
print("connected", flush=True)
end = time.time() + float(sys.argv[1])
while time.time() < end:
    try:
        s.send(b"x" * 100)
    except OSError:
        pass
    time.sleep(0.1)'
flow_case() {   # name  "command prefix that runs the client"
    local name="$1"; shift
    tunnel_up; reset
    "$@" python3 -c "$LONG_CLIENT" 4 > /run/rig/client.out 2>&1 &
    local cp=$!
    sleep 1.2
    local before; before="$(count phys_inet)"
    tunnel_down
    sleep 0.2
    wait "$cp"
    local n tsrc tun; n="$(count phys_inet)"; tsrc="$(count phys_tsrc)"; tun="$(count tun_inet)"
    if grep -q connected /run/rig/client.out && [[ "$before" == 0 && "$n" == 0 && "$tsrc" == 0 ]]; then
        result ok "$name" "connected through the tunnel; 0 packets on the physical side after the route was removed"
    else
        result bad "$name" "LEAK or no connection: before=$before, after=$n packets (from 100.64.0.0/10: $tsrc), client said: $(tr '\n' ' ' < /run/rig/client.out)"
    fi
}
flow_case "tunnel route removed: an established TCP connection from the guest does not move to the physical NIC" g
g nft -f - <<'EOF2' || broken "cannot load the guest NAT table"
table ip nat {
    chain post { type nat hook postrouting priority 100;
        oifname "tailscale0" masquerade
    }
}
EOF2
# With `masquerade` the kernel itself drops a flow whose output interface
# changed, so this case passes even without the fix; it documents that.
flow_case "tunnel route removed: an established forwarded (masqueraded) connection from a container does not move to the physical NIC" c
# A fixed `snat to` (static NAT, or a firewall that does not use masquerade)
# has no such guard: the re-routed packets keep the Tailscale source address
# and only the kill-switch stops them.
g nft delete table ip nat || broken "cannot remove the masquerade table"
g nft -f - <<'EOF2' || broken "cannot load the guest SNAT table"
table ip nat {
    chain post { type nat hook postrouting priority 100;
        oifname "tailscale0" snat to 100.64.0.2
    }
}
EOF2
flow_case "tunnel route removed: an established forwarded (SNATed to the tailscale address) connection from a container does not move to the physical NIC" c

udp_send() {   # ns-prefix  family(4|6)  dst  sport  mark(0=none)  bind-device("" = none)  dport
    "$1" python3 -c 'import socket, sys
fam = socket.AF_INET6 if sys.argv[1] == "6" else socket.AF_INET
dst, sport, mark, dev, dport = sys.argv[2], int(sys.argv[3]), int(sys.argv[4], 0), sys.argv[5], int(sys.argv[6])
s = socket.socket(fam, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
if dev:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, dev.encode())
if mark:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, mark)
s.bind(("::" if fam == socket.AF_INET6 else "0.0.0.0", sport))
for _ in range(3):
    s.sendto(b"x", (dst, dport))' "$2" "$3" "$4" "${5:-0}" "${6:-}" "${7:-9999}" 2>/dev/null || true
}
tunnel_down; reset
udp_send g 4 203.0.113.10 40000 0 "" 67; sleep 0.3
n="$(count phys_udp67)"
if [[ "$n" == 0 ]]; then
    result ok "tunnel down: UDP from an unprivileged port to port 67 on an internet address (IPv4) is blocked" "0 packets on the physical side"
else
    result bad "tunnel down: UDP from an unprivileged port to port 67 on an internet address (IPv4) is blocked" "LEAK: $n packets on the physical side"
fi
reset
udp_send g 4 203.0.113.10 68 0 "" 67; sleep 0.3
n="$(count phys_udp67)"
if [[ "$n" == 0 ]]; then
    result ok "tunnel down: UDP from port 68 to port 67 on a unicast internet address is blocked" "0 packets on the physical side"
else
    result bad "tunnel down: UDP from port 68 to port 67 on a unicast internet address is blocked" "LEAK: $n packets on the physical side"
fi
reset
for _ in 1 2 3; do udp_send g 6 2001:db8::10 40000 0 "" 67; sleep 0.3; done
n="$(count phys_udp67_6)"
if [[ "$n" == 0 ]]; then
    result ok "tunnel down: UDP from an unprivileged port to port 67 on an internet address (IPv6) is blocked" "0 packets on the physical side"
else
    result bad "tunnel down: UDP from an unprivileged port to port 67 on an internet address (IPv6) is blocked" "LEAK: $n packets on the physical side"
fi

### ---- things that must keep working ----------------------------------------
tunnel_down; reset
udp_send g 4 255.255.255.255 68 0 "$PHYS" 67; sleep 0.3
n="$(count phys_dhcp)"
if [[ "$n" -gt 0 ]]; then
    result ok "tunnel down: DHCP-shaped datagram (68 -> 255.255.255.255:67) leaves $PHYS" "$n packets on the physical side"
else
    result bad "tunnel down: DHCP-shaped datagram (68 -> 255.255.255.255:67) leaves $PHYS" "0 packets arrived; DHCP would break"
fi

reset
udp_send g 4 203.0.113.10 40000 0x80000 "" 9999; sleep 0.3
n="$(count phys_inet)"
if [[ "$n" -gt 0 ]]; then
    result ok "tunnel down: packet with Tailscale's bypass mark 0x80000 to an internet address leaves $PHYS" "$n packets on the physical side"
else
    result bad "tunnel down: packet with Tailscale's bypass mark 0x80000 to an internet address leaves $PHYS" "0 packets arrived; tailscaled could not reach its peers"
fi
reset
udp_send g 4 203.0.113.10 40001 0 "" 9999; sleep 0.3
n="$(count phys_inet)"
if [[ "$n" == 0 ]]; then
    result ok "control: the same datagram without the mark is blocked" "0 packets on the physical side"
else
    result bad "control: the same datagram without the mark is blocked" "LEAK: $n packets on the physical side"
fi

# Inbound TCP: the peer connects, sends a line, the guest answers.
INBOUND_SERVER='import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], 7000))
s.listen(1)
s.settimeout(6)
try:
    c, _ = s.accept()
except OSError:
    sys.exit(0)
c.settimeout(3)
data = c.recv(100)
c.sendall(b"pong:" + data)
c.close()'
INBOUND_CLIENT='import socket, sys
s = socket.create_connection((sys.argv[2], 7000), timeout=3, source_address=(sys.argv[1], 0))
s.sendall(b"ping")
s.settimeout(3)
print(s.recv(100).decode())'
inbound_case() {   # name  server-ip  client-source-ip
    ip netns exec G python3 -c "$INBOUND_SERVER" "$2" &
    local sp=$!
    sleep 0.5
    local out; out="$(timeout 6 python3 -c "$INBOUND_CLIENT" "$3" "$2" 2>&1)"
    wait "$sp" 2>/dev/null
    [[ -z "$(ip netns exec G ss -Hltn 'sport = :7000')" ]] || broken "leftover test server on port 7000 in G"
    [[ "$out" == "pong:ping" ]]
}
tunnel_down; reset
if inbound_case x 192.168.50.2 192.168.50.1; then
    result ok "tunnel down: a TCP connection from the LAN to a port on the guest completes and exchanges data both ways" "ping answered with pong"
else
    result bad "tunnel down: a TCP connection from the LAN to a port on the guest completes and exchanges data both ways" "no answer from the guest"
fi
tunnel_up; reset
if inbound_case x 100.64.0.2 100.64.0.1; then
    r="$(count tun_in_reply)"; p="$(count phys_tsrc)"
    if [[ "$r" -gt 0 && "$p" == 0 ]]; then
        result ok "tunnel up: a connection arriving over tailscale0 gets its replies back over tailscale0" "$r reply packets in the tunnel, 0 on the physical side"
    else
        result bad "tunnel up: a connection arriving over tailscale0 gets its replies back over tailscale0" "tunnel replies=$r, packets from 100.64.0.0/10 on the physical side=$p"
    fi
else
    result bad "tunnel up: a connection arriving over tailscale0 gets its replies back over tailscale0" "no answer from the guest"
fi

# Container bridge: a container (C) reaches a service on the guest at 172.17.0.1
# and the guest's replies leave through docker0 (the "docker*" established
# accept in chain output). A NEW connection from the guest into the bridge is
# not allowed (the bridge subnet is not in the LAN set), so it must fail.
tunnel_down; reset
ip netns exec G python3 -c "$INBOUND_SERVER" 172.17.0.1 &
sp=$!
sleep 0.5
out="$(c timeout 6 python3 -c "$INBOUND_CLIENT" 172.17.0.2 172.17.0.1 2>&1)"
wait "$sp" 2>/dev/null
[[ -z "$(ip netns exec G ss -Hltn 'sport = :7000')" ]] || broken "leftover test server on port 7000 in G"
if [[ "$out" == "pong:ping" ]]; then
    result ok "tunnel down: a container connects to a service on the guest over the bridge and gets its replies" "ping answered with pong"
else
    result bad "tunnel down: a container connects to a service on the guest over the bridge and gets its replies" "got: ${out:-nothing}"
fi
ip netns exec C python3 -c "$INBOUND_SERVER" 172.17.0.2 &
sp=$!
sleep 0.5
out="$(g timeout 4 python3 -c "$INBOUND_CLIENT" 172.17.0.1 172.17.0.2 2>&1)"
kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
[[ -z "$(ip netns exec C ss -Hltn 'sport = :7000')" ]] || broken "leftover test server on port 7000 in C"
if [[ "$out" != "pong:ping" ]]; then
    result ok "tunnel down: a NEW connection from the guest into the container bridge is dropped (bridge subnet is not in the LAN set)" "no answer, as documented"
else
    result bad "tunnel down: a NEW connection from the guest into the container bridge is dropped (bridge subnet is not in the LAN set)" "the connection completed"
fi

# Forwarded traffic that must keep working with the tunnel down (the guest is a
# Docker host), and must not become a way out of the physical NIC.
# 1. A new connection a container opens to an internet address is dropped.
tunnel_down; reset
c timeout 3 bash -c 'exec 3<>/dev/tcp/203.0.113.10/443' 2>/dev/null; rc=$?
sleep 0.3
n="$(count phys_inet)"
if [[ "$rc" != 0 && "$n" == 0 ]]; then
    result ok "tunnel down: a NEW connection from a container to an internet address is dropped" "0 packets on the physical side"
else
    result bad "tunnel down: a NEW connection from a container to an internet address is dropped" "LEAK: $n packets on the physical side, connect rc=$rc"
fi
# 2. Published port: a LAN client reaches guest:7100, DNATed to the container.
g nft -f - <<EOF2 || broken "cannot load the DNAT table"
table ip pub {
    chain pre { type nat hook prerouting priority -100;
        iifname "$PHYS" tcp dport 7100 dnat to 172.17.0.2:7000
    }
}
EOF2
ip netns exec C python3 -c "$INBOUND_SERVER" 172.17.0.2 &
sp=$!
sleep 0.5
out="$(timeout 6 python3 -c 'import socket
s = socket.create_connection(("192.168.50.2", 7100), timeout=3, source_address=("192.168.50.1", 0))
s.sendall(b"ping"); s.settimeout(3); print(s.recv(100).decode())' 2>&1)"
kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
[[ -z "$(ip netns exec C ss -Hltn 'sport = :7000')" ]] || broken "leftover test server on port 7000 in C"
if [[ "$out" == "pong:ping" ]]; then
    result ok "tunnel down: a published port (LAN -> DNAT -> container) works and the replies come back" "ping answered with pong"
else
    result bad "tunnel down: a published port (LAN -> DNAT -> container) works and the replies come back" "got: ${out:-nothing}"
fi
# 2b. The answers to an INTERNET client of a published port go out the uplink,
# not the tunnel: with the tunnel down they must be dropped (as on eth0). On a
# br-* uplink the bridge-name accepts used to let them leave (client got a RST).
ip netns exec C python3 -c "$INBOUND_SERVER" 172.17.0.2 &
sp=$!
sleep 0.5
reset
timeout 4 python3 -c 'import socket
s = socket.create_connection(("192.168.50.2", 7100), timeout=2, source_address=("203.0.113.10", 0))' >/dev/null 2>&1
sleep 0.3
n="$(count phys_inet)"
kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
[[ -z "$(ip netns exec C ss -Hltn 'sport = :7000')" ]] || broken "leftover test server on port 7000 in C"
if [[ "$n" == 0 ]]; then
    result ok "tunnel down: replies to an internet client of a published port do not leave the uplink" "0 packets on the physical side"
else
    result bad "tunnel down: replies to an internet client of a published port do not leave the uplink" "LEAK: $n packets on the physical side"
fi
# 2c. Subnet router: a tunnel peer reaches a container IP directly (no DNAT)
# while the tunnel is up.
tunnel_up
ip route add 172.17.0.0/24 via 100.64.0.2 dev wts 2>/dev/null
ip netns exec C python3 -c "$INBOUND_SERVER" 172.17.0.2 &
sp=$!
sleep 0.5
out="$(timeout 6 python3 -c "$INBOUND_CLIENT" 100.64.0.1 172.17.0.2 2>&1)"
kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
[[ -z "$(ip netns exec C ss -Hltn 'sport = :7000')" ]] || broken "leftover test server on port 7000 in C"
if [[ "$out" == "pong:ping" ]]; then
    result ok "tunnel up: a tunnel peer reaches a container IP directly (subnet router, no DNAT)" "ping answered with pong"
else
    result bad "tunnel up: a tunnel peer reaches a container IP directly (subnet router, no DNAT)" "got: ${out:-nothing}"
fi
tunnel_down
# 3. Container to container on two bridges (docker0 and br-app), through the guest.
g ip link add br-app type veth peer name c2veth netns C2 2>/dev/null || { ip netns add C2 && g ip link add br-app type veth peer name c2veth netns C2; } || broken "cannot create the second container bridge"
g ip addr add 172.18.0.1/24 dev br-app
g ip link set br-app up
g sysctl -qw net.ipv4.conf.br-app.rp_filter=0 2>/dev/null
c2() { ip netns exec C2 "$@"; }
c2 ip link set lo up
c2 ip addr add 172.18.0.2/24 dev c2veth
c2 ip link set c2veth up
c2 ip route add default via 172.18.0.1
ip netns exec C2 python3 -c "$INBOUND_SERVER" 172.18.0.2 &
sp=$!
sleep 0.5
out="$(c timeout 6 python3 -c "$INBOUND_CLIENT" 172.17.0.2 172.18.0.2 2>&1)"
kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
[[ -z "$(ip netns exec C2 ss -Hltn 'sport = :7000')" ]] || broken "leftover test server on port 7000 in C2"
if [[ "$out" == "pong:ping" ]]; then
    result ok "tunnel down: container to container across two bridges works" "ping answered with pong"
else
    result bad "tunnel down: container to container across two bridges works" "got: ${out:-nothing}"
fi

### ---- the watchdog restores a kill-switch table that something removed -------
# Runs the REAL assets/mullvad-rotate.sh (only the log path, the ruleset path and
# the two sleep/timeout settings are changed) with a stub `tailscale`. The stub
# records every call; `set --exit-node=X` brings the fake tunnel up, like a
# successful exit-node switch does.
mkdir -p /run/rig/bin /run/rig/etc
cat > /run/rig/bin/tailscale <<'STUB'
#!/usr/bin/env bash
echo "tailscale $*" >> /run/rig/tailscale.calls
case "${1:-}" in
    status) echo '{}' ;;
    exit-node) echo "100.64.9.9  us-bos-wg-001.mullvad.ts.net  USA  Boston  -" ;;
    set) case "${2:-}" in --exit-node=?*) ip route replace default dev tailscale0 table 52 ;; esac ;;
esac
exit 0
STUB
chmod +x /run/rig/bin/tailscale
sed -e 's/^CHECK_TIMEOUT=[0-9]*/CHECK_TIMEOUT=2/' -e 's/^TUNNEL_SETTLE=[0-9]*/TUNNEL_SETTLE=0/' \
    "$REPO/assets/mullvad-rotate.sh" > /run/rig/rotate.sh
cp /run/rig/killswitch.nft /run/rig/etc/mullvad-killswitch.nft
run_rotate() {   # args for mullvad-rotate.sh; output in /run/rig/rotate.out, status in $ROTATE_RC
    : > /run/rig/rotate.log; : > /run/rig/tailscale.calls
    g env PATH="/run/rig/bin:$PATH" MULLVAD_LOG_FILE=/run/rig/rotate.log \
        MULLVAD_KILLSWITCH_RULES=/run/rig/etc/mullvad-killswitch.nft \
        bash /run/rig/rotate.sh "$@" > /run/rig/rotate.out 2>&1
    ROTATE_RC=$?
}
table_ok() { g nft list table inet mullvad_killswitch >/dev/null 2>&1; }
reload_table() { g nft flush ruleset; g nft -f /run/rig/killswitch.nft; }

# 1. table flushed away, tunnel down, ruleset file fine: reload it, heal, never say healthy.
reload_table; tunnel_down; g nft flush ruleset; reset
run_rotate --check-only
p="$(count phys_probe)"; sets="$(grep -c '^tailscale set --exit-node=us-' /run/rig/tailscale.calls)"
if table_ok && [[ "$p" == 0 && "$sets" -ge 1 ]] && grep -qi 'kill-switch table.*missing.*reload' /run/rig/rotate.log \
   && ! grep -q 'tunnel healthy' /run/rig/rotate.out; then
    result ok "kill-switch flushed, tunnel down: the watchdog reloads the table, heals, and does not report healthy" "table loaded again, $p probe packets on the physical side, $sets exit-node set call(s)"
else
    result bad "kill-switch flushed, tunnel down: the watchdog reloads the table, heals, and does not report healthy" "table loaded=$(table_ok && echo yes || echo NO), $p probe packets on the physical side, $sets exit-node set call(s), rc=$ROTATE_RC, output: $(tr '\n' '|' < /run/rig/rotate.out)"
fi

# 2. same, but the installed ruleset file is missing / invalid: fail closed, no probe.
for variant in missing invalid; do
    reload_table; tunnel_down; g nft flush ruleset; reset
    if [[ "$variant" == missing ]]; then rm -f /run/rig/etc/mullvad-killswitch.nft
    else echo 'this is not a ruleset {' > /run/rig/etc/mullvad-killswitch.nft; fi
    run_rotate --check-only
    p="$(count phys_probe)"; calls="$(wc -l < /run/rig/tailscale.calls)"
    if [[ "$ROTATE_RC" != 0 && "$p" == 0 && "$calls" == 0 ]] && grep -qi 'ERROR.*kill-switch' /run/rig/rotate.log \
       && ! grep -q 'tunnel healthy' /run/rig/rotate.out; then
        result ok "kill-switch flushed, ruleset file $variant: exit non-zero, error names the kill-switch, no probe" "rc=$ROTATE_RC, $p probe packets on the physical side, $calls tailscale calls"
    else
        result bad "kill-switch flushed, ruleset file $variant: exit non-zero, error names the kill-switch, no probe" "rc=$ROTATE_RC, $p probe packets on the physical side, $calls tailscale calls, output: $(tr '\n' '|' < /run/rig/rotate.out)"
    fi
done
cp /run/rig/killswitch.nft /run/rig/etc/mullvad-killswitch.nft

# 3. table present and tunnel up: behaves as before, table untouched.
reload_table; tunnel_up; reset
before="$(g nft -a list table inet mullvad_killswitch)"
run_rotate --check-only
after="$(g nft -a list table inet mullvad_killswitch)"
if [[ "$ROTATE_RC" == 0 && "$before" == "$after" && "$(grep -c 'tunnel healthy, no action' /run/rig/rotate.log)" == 1 ]] \
   && ! grep -qi 'reload' /run/rig/rotate.log && ! grep -q '^tailscale set' /run/rig/tailscale.calls; then
    result ok "kill-switch loaded, tunnel up: --check-only logs one 'tunnel healthy' line, no reload, table handles unchanged" "rc=0"
else
    result bad "kill-switch loaded, tunnel up: --check-only logs one 'tunnel healthy' line, no reload, table handles unchanged" "rc=$ROTATE_RC, table changed=$([[ "$before" == "$after" ]] && echo no || echo YES), log: $(tr '\n' '|' < /run/rig/rotate.log)"
fi

echo "leak rig: $pass passed, $fail failed"
[[ "$fail" == 0 ]]
