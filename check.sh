#!/usr/bin/env bash
# check.sh - every automatic check for this repo, in one command. CI runs exactly
# this (.github/workflows/ci.yml), so a green ./check.sh is a green pull request.
#
#   1. bash -n      syntax of every shell file
#   2. ShellCheck   default severity, no file-wide disables
#   3. bats         unit, drift and end-to-end tests with stub pvesh/pct/qm
#   4. leak rig     network-namespace test of the real kill-switch ruleset
#
# Needs: bash, shellcheck, bats, nft, ip, unshare, python3, jq.
# Exits non-zero as soon as a step fails.
unset PYTHONPATH PYTHONHOME VIRTUAL_ENV
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\ncheck.sh: FAILED - %s\n' "$*" >&2; exit 1; }

for tool in bash shellcheck bats jq; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done

# Every shell file the repo owns.
mapfile -t SH_FILES < <(
    { printf '%s\n' bulkvpn-deploy.sh check.sh assets/mullvad-rotate.sh
      find tests -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.bats' \) | sort
    } | sort -u
)
# ShellCheck reads .bats files natively; only bash -n skips them (bats parses them itself).
LINT_FILES=("${SH_FILES[@]}")

step "bash -n (${#SH_FILES[@]} files)"
for f in "${SH_FILES[@]}"; do
    [[ "$f" == *.bats ]] && continue
    bash -n "$f" || fail "bash -n $f"
done
echo "ok"

step "ShellCheck $(shellcheck --version | sed -n 's/^version: //p') (${#LINT_FILES[@]} files)"
shellcheck "${LINT_FILES[@]}" || fail "ShellCheck"
echo "ok"

step "bats"
bats --tap tests || fail "bats"

step "leak rig"
bash tests/leak/run.sh
rc=$?
if [[ "$rc" == 77 ]]; then
    echo "leak rig SKIPPED (namespaces unavailable; with CI=true this would be a failure)"
elif [[ "$rc" != 0 ]]; then
    fail "leak rig (exit $rc)"
fi

printf '\ncheck.sh: all checks passed\n'
