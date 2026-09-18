#!/usr/bin/env bash
# check.sh
# Run every gate this repo's CI enforces, locally, in one command:
#
#   bash -n                syntax of the shipped scripts
#   static analysis        shellcheck, with the same flags as ci.yml
#   workflow lint          actionlint, which also analyses the inline `run:`
#                          scripts in .github/workflows
#   bats test              unit tests
#
# Why this exists: CI on main was red for four consecutive pushes because
# running shellcheck over scripts/*.sh cannot see the shell embedded in a
# workflow, and actionlint was only ever run by CI. Local green does not imply
# CI green unless the local set matches.
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

missing=()
need() {
  command -v "$1" >/dev/null 2>&1 || missing+=("$1")
}
need shellcheck
need actionlint
need bats

if [ "${#missing[@]}" -gt 0 ]; then
  cat >&2 <<EOF
Missing tools: ${missing[*]}

  shellcheck  https://github.com/koalaman/shellcheck/releases
  actionlint  https://github.com/rhysd/actionlint/releases
  bats        https://github.com/bats-core/bats-core
EOF
  exit 2
fi

fail=0
step() {
  local name="$1"
  shift
  printf '=== %s\n' "$name"
  if "$@"; then
    printf '    ok\n'
  else
    printf '    FAILED\n' >&2
    fail=1
  fi
}

step "bash -n scripts/*.sh" bash -n scripts/*.sh
step "shellcheck" shellcheck --external-sources scripts/*.sh
step "actionlint" actionlint
step "bats test" bats test

if [ "$fail" -ne 0 ]; then
  echo
  echo "One or more gates failed. Fix them before pushing; CI runs the same set." >&2
  exit 1
fi

echo
echo "All local gates passed. Note that this does not prove CI is green: the"
echo "authoritative check is 'gh run list --workflow ci.yml' after pushing."
