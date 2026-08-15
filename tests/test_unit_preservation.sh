#!/usr/bin/env bash
# =============================================================================
#  Test: install_unit() must never destroy a hand-edited systemd unit.
#
#  Why this test exists
#  --------------------
#  The manual guide tells people to edit the service files by hand (Step 10
#  adds --api-key and changes the listen address; Step 11 does the same for
#  Odysseus). The installer's own banner promises that re-running is safe.
#  Before this test, re-running silently overwrote those edits, which meant
#  the two published documents contradicted each other and a user could lose
#  their API key by following both.
#
#  The function under test is extracted from the real installer rather than
#  copied, so this tests the code that actually ships.
#
#  Run:  bash tests/test_unit_preservation.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../scripts/install_local_ai.sh"
[[ -r "${SCRIPT}" ]] || { echo "cannot read ${SCRIPT}"; exit 1; }

PASS=0; FAIL=0
ok(){   printf '  [pass] %s\n' "$1"; PASS=$((PASS+1)); }
bad(){  printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){
  if [[ "$2" == "$3" ]]; then ok "$1"
  else bad "$1"; printf '         expected: %s\n         actual:   %s\n' "$3" "$2"; fi
}
exists(){ if [[ -f "$1" ]]; then ok "$2"; else bad "$2"; fi; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT

# --- build a harness containing the real function ---------------------------
# The single quotes below are deliberate: these lines are written verbatim into
# the harness script and must NOT expand here.
# shellcheck disable=SC2016
{
  echo 'set -uo pipefail'
  echo 'info(){ echo "    $*"; }'
  echo 'warn(){ echo "[!] $*" >&2; }'
  echo 'good(){ echo "[OK] $*"; }'
  echo 'die(){ echo "[FAIL] $*" >&2; exit 1; }'
  echo "STAMP_DIR='${SANDBOX}/var'"
  echo 'YES="yes"'                       # non-interactive, so it never prompts
  echo 'REPLACE_UNITS="${REPLACE_UNITS:-no}"'
  # Redirect the hard-coded /etc/systemd/system path into the sandbox.
  sed -n '/^install_unit(){/,/^}/p' "${SCRIPT}" \
    | sed "s#/etc/systemd/system/#${SANDBOX}/etc/#"
  echo 'install_unit "$1" "$2"'
} > "${SANDBOX}/harness.sh"

if ! grep -q 'install_unit()' "${SANDBOX}/harness.sh"; then
  echo "could not extract install_unit() from the installer"; exit 1
fi

mkdir -p "${SANDBOX}/etc" "${SANDBOX}/var"
UNIT="${SANDBOX}/etc/llama.service"
run_unit(){ bash "${SANDBOX}/harness.sh" llama.service "$1" >/dev/null 2>&1; }

echo "install_unit(): protecting hand-edited service files"

# 1. Fresh machine: the unit does not exist, so write it.
run_unit "VERSION=A"
check "writes the unit when none exists" "$(cat "${UNIT}" 2>/dev/null)" "VERSION=A"
exists "${SANDBOX}/var/llama.service.sha" "records a checksum"

# 2. Re-run with identical content: nothing changes.
run_unit "VERSION=A"
check "leaves an identical unit alone" "$(cat "${UNIT}")" "VERSION=A"

# 3. Script updated, user has NOT touched the file: we own it, so update it.
run_unit "VERSION=B"
check "updates a unit we wrote ourselves" "$(cat "${UNIT}")" "VERSION=B"

# 4. THE IMPORTANT ONE. User follows the guide and adds an API key.
#    A later run must NOT throw that away.
printf 'VERSION=B\nExecStart=llama-server --api-key hunter2 --host 0.0.0.0\n' > "${UNIT}"
run_unit "VERSION=C"
if grep -q 'hunter2' "${UNIT}"; then ok "keeps a hand-edited unit (the API key survives)"
else bad "keeps a hand-edited unit (the API key survives)"; fi
exists "${UNIT}.patteros-backup" "backs the user's version up"

# 5. Explicit override: --replace-units means the user asked for it.
REPLACE_UNITS=yes bash "${SANDBOX}/harness.sh" llama.service "VERSION=D" >/dev/null 2>&1
check "--replace-units overwrites on request" "$(cat "${UNIT}")" "VERSION=D"

# 6. After an explicit replace we own it again, so a later update is silent.
run_unit "VERSION=E"
check "regains ownership after an explicit replace" "$(cat "${UNIT}")" "VERSION=E"

echo
printf '%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
