#!/usr/bin/env bash
# Stand-in for the Proxmox tools pvesh, pct and qm. tests/helpers.bash copies it
# to a temp directory under each of those three names and puts that directory on
# PATH, so the deploy script never reaches a real Proxmox node.
#
# STUB_DIR holds the fixtures, STUB_LOG receives one line per call:
#   lxc.json / qemu.json     what `pvesh get /nodes/N/lxc|qemu` returns
#   ct<ID>.* / vm<ID>.*      per-guest behaviour (guest = ct101, vm301, ...):
#     .protected   the kill-switch is already installed
#     .nosystemd   the guest is not systemd-based
#     .probe       output of the Tailscale probe command
#     .mullvad     a Mullvad exit node is visible on the tailnet
#     .agent       (VMs) the guest agent answers ping
#     .config      output of `pct|qm config`
# Anything else run in a guest succeeds silently. Data piped to
# `qm guest exec --pass-stdin` is saved as stdin-<guest> and never logged.
set -u
name="$(basename "$0")"
S="${STUB_DIR:?STUB_DIR is not set}"
printf '%s %s\n' "$name" "$*" >> "${STUB_LOG:?STUB_LOG is not set}"

# guest_cmd PREFIX ID COMMAND: what the command would do inside that guest.
guest_cmd() {
    local g="$1$2" cmd="$3"
    case "$cmd" in
        "test -x /usr/local/bin/mullvad-rotate.sh && systemctl is-enabled"*) [[ -e "$S/$g.protected" ]]; return ;;
        "test -d /run/systemd/system") [[ ! -e "$S/$g.nosystemd" ]]; return ;;
        "b=0; command -v tailscale"*) cat "$S/$g.probe" 2>/dev/null; return 0 ;;
        "tailscale exit-node list"*) [[ -e "$S/$g.mullvad" ]]; return ;;
        *) return 0 ;;
    esac
}

case "$name" in
    pvesh)
        case "$*" in
            *"/lxc"*)  cat "$S/lxc.json" 2>/dev/null || echo '[]' ;;
            *"/qemu"*) cat "$S/qemu.json" 2>/dev/null || echo '[]' ;;
            *) echo '[]' ;;
        esac
        ;;
    pct)
        case "${1:-}" in
            exec)   guest_cmd ct "$2" "${*: -1}" ;;   # pct exec ID -- bash -c CMD
            config) cat "$S/ct$2.config" 2>/dev/null; true ;;
            *)      true ;;                            # push, reboot, ...
        esac
        ;;
    qm)
        case "${1:-} ${2:-}" in
            "guest cmd")
                case "${4:-}" in
                    ping) [[ -e "$S/vm$3.agent" ]] ;;
                    *)    echo '[]' ;;
                esac
                ;;
            "guest exec")
                id="$3"; shift 3; stdin_file=""
                while [[ $# -gt 0 && "$1" != "--" ]]; do
                    [[ "$1" == "--pass-stdin" ]] && stdin_file="$S/stdin-vm$id"
                    shift
                done
                [[ -z "$stdin_file" ]] || cat > "$stdin_file"
                out="$(guest_cmd vm "$id" "${*: -1}")"; rc=$?   # qm guest exec ID -- bash -c CMD
                jq -cn --argjson rc "$rc" --arg out "$out" '{exitcode: $rc, "out-data": $out}'
                ;;
            config*) cat "$S/vm${2:-}.config" 2>/dev/null; true ;;
            *) case "${1:-}" in config) cat "$S/vm$2.config" 2>/dev/null; true ;; *) true ;; esac ;;
        esac
        ;;
esac
