#!/usr/bin/env bash
#
# mullvad-rotate.sh — rotate / self-heal the Tailscale + Mullvad exit node.
#
# Normal run     : picks a fresh random ONLINE node, switches, and VERIFIES
#                  that traffic actually flows through it. If verification
#                  fails it transparently re-acquires another node, looping
#                  until one works or candidates are exhausted.
# --check-only   : does nothing if the current tunnel is healthy; only
#                  re-acquires when connectivity is down. Run this on a short
#                  timer as a self-healing watchdog.
#
# Leak safety comes from the companion nftables kill-switch
# (mullvad-killswitch.nft): whenever no working exit node is set, all
# non-tunnel egress is DROPPED, so a failed/unverified node never leaks
# your real IP.
#
# Vendored from https://github.com/thelorax1775/tailscale-mullvad-killswitch
# The COUNTRY_FILTER / ALLOW_LAN / LAN_SUBNETS lines below are templated by
# bulkvpn-deploy.sh.

set -euo pipefail

### ---- Configuration -------------------------------------------------------
COUNTRY_FILTER=""              # e.g. "USA"; empty = any country
PREFERRED_NODE=""
ALLOW_LAN=true                 # keep LAN access to the web UI / SSH
LAN_SUBNETS=""                 # space-separated CIDRs to keep reachable directly
                               # (off the exit-node tunnel), e.g. other guests' LANs
LAN_BYPASS_PRIO=5200           # ip-rule priority (above Tailscale's ~5230 diverter)
LOG_FILE="/var/log/mullvad-rotate.log"
CHECK_TIMEOUT=8                # seconds per connectivity probe
TUNNEL_SETTLE=3                # seconds to wait after switching before probing
TAILSCALE="$(command -v tailscale || echo /usr/bin/tailscale)"
### --------------------------------------------------------------------------

CHECK_ONLY=false
[[ "${1:-}" == "--check-only" ]] && CHECK_ONLY=true

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

[[ -x "$TAILSCALE" ]] || die "tailscale binary not found at '$TAILSCALE'"

# ensure_lan_bypass: keep the configured LAN subnets reachable *directly* while
# an exit node is active. Tailscale policy-routes the default route into the
# tunnel (ip rule at priority ~5230), which otherwise swallows traffic to other
# LAN subnets reached via the gateway (--exit-node-allow-lan-access only exempts
# the node's own directly-connected subnet). A higher-priority rule sends these
# subnets to the main table so they egress via the local gateway instead of the
# tunnel — so containers/VMs/LXCs on the LAN can still reach each other. These
# rules are runtime-only, so re-assert them on every run (idempotent).
ensure_lan_bypass() {
    [[ -n "$LAN_SUBNETS" ]] || return 0
    command -v ip >/dev/null 2>&1 || return 0
    local net
    for net in $LAN_SUBNETS; do
        [[ "$net" == */* ]] || continue
        ip rule del to "$net" lookup main priority "$LAN_BYPASS_PRIO" 2>/dev/null || true
        if ip rule add to "$net" lookup main priority "$LAN_BYPASS_PRIO" 2>/dev/null; then
            log "LAN bypass: $net -> main table (direct, off tunnel)"
        fi
    done
}

# Keep the LAN reachable before anything else, on every run (including
# --check-only heals), so a reboot that comes up healthy still restores it.
ensure_lan_bypass

verify_connectivity() {
    # With the kill-switch active, ANY successful outbound TCP connect proves
    # traffic is egressing through the tunnel (raw eth0 egress is dropped).
    local host
    for host in 1.1.1.1 9.9.9.9; do
        if timeout "$CHECK_TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/443" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}


CURRENT=""
if command -v jq >/dev/null 2>&1; then
    CURRENT="$("$TAILSCALE" status --json 2>/dev/null \
        | jq -r '.. | objects | select(.ExitNode? == true) | .DNSName? // empty' \
        | sed 's/\.$//' | head -n1)"
fi

switch_to() {
    local target="$1"
    if [[ "$target" == "$CURRENT" ]]; then
        "$TAILSCALE" set --exit-node= || true
    fi
    "$TAILSCALE" set --exit-node="$target" --exit-node-allow-lan-access="$ALLOW_LAN" || return 1
    sleep "$TUNNEL_SETTLE"
    verify_connectivity && return 0
    sleep "$TUNNEL_SETTLE"
    verify_connectivity
}

if $CHECK_ONLY; then
    if verify_connectivity; then
        if [[ -z "$PREFERRED_NODE" || "$CURRENT" == "$PREFERRED_NODE" ]]; then
            log "check-only: tunnel healthy, no action"
            exit 0
        fi
        log "check-only: healthy on ${CURRENT:-none}, trying preferred $PREFERRED_NODE"
        if switch_to "$PREFERRED_NODE"; then
            log "OK: back on preferred $PREFERRED_NODE"
            exit 0
        fi
        log "WARN: preferred $PREFERRED_NODE not working, returning to ${CURRENT:-a fallback}"
        if [[ -n "$CURRENT" ]] && switch_to "$CURRENT"; then
            log "OK: staying on fallback $CURRENT"
            exit 0
        fi
        log "check-only: fallback lost too — acquiring a new node"
    else
        log "check-only: NO connectivity detected — acquiring a new node"
    fi
fi

# Gather online Mullvad candidates.
list_cmd=("$TAILSCALE" exit-node list)
[[ -n "$COUNTRY_FILTER" ]] && list_cmd+=(--filter="$COUNTRY_FILTER")

mapfile -t NODES < <(
    "${list_cmd[@]}" \
        | awk '/mullvad\.ts\.net/ && tolower($0) !~ /offline/ { print $2 }' \
        | sort -u
)
(( ${#NODES[@]} > 0 )) || die "no online Mullvad exit nodes found${COUNTRY_FILTER:+ for '$COUNTRY_FILTER'}"


mapfile -t ORDER < <(printf '%s\n' "${NODES[@]}" | grep -vxF -e "${CURRENT:-__none__}" -e "${PREFERRED_NODE:-__none__}" | shuf)
if [[ -n "$PREFERRED_NODE" ]] && { [[ "$CURRENT" == "$PREFERRED_NODE" ]] || printf '%s\n' "${NODES[@]}" | grep -qxF "$PREFERRED_NODE"; }; then
    ORDER=("$PREFERRED_NODE" "${ORDER[@]}")
fi
[[ -n "$CURRENT" && "$CURRENT" != "$PREFERRED_NODE" ]] && ORDER+=("$CURRENT")

LABEL=""; $CHECK_ONLY && LABEL="[heal] "
log "${LABEL}Selecting from ${#NODES[@]} candidates (current: ${CURRENT:-none})"

for TARGET in "${ORDER[@]}"; do
    log "Trying $TARGET ..."
    if switch_to "$TARGET"; then
        log "OK: traffic verified through $TARGET"
        exit 0
    fi
    log "WARN: $TARGET set but no connectivity — re-acquiring"
done

# Nothing worked. The kill-switch keeps egress blocked, so this fails CLOSED.
die "exhausted ${#NODES[@]} candidates with no working tunnel — egress remains blocked by kill-switch (no leak)"
