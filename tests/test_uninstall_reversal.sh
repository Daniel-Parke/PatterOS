#!/usr/bin/env bash
# =============================================================================
#  Test: the uninstaller must undo exactly what the installer did, and no more.
#
#  MUST BE RUN AS ROOT IN A DISPOSABLE CONTAINER. It creates a user and edits
#  group membership. Do not run it on your own machine.
#
#    docker run --rm -v "$PWD:/mnt" -w /mnt ubuntu:24.04 \
#      bash tests/test_uninstall_reversal.sh
#
#  What it covers
#  --------------
#  1. Exit codes. A successful reset used to return 1 and only a dry run
#     returned 0, because the script's last statement was a bare
#     `[[ "${DRY}" == "yes" ]] && warn ...`. Anything checking the exit code
#     was told every successful reset had failed.
#  2. Port recovery. The installer lets people choose their own ports. The
#     uninstaller used to assume 8020/7000, so it deleted firewall rules that
#     were never added and left the user's real ports open.
#  3. Group membership, both directions. It must remove groups PatterOS added,
#     and it must NOT remove a group the user already belonged to. Many
#     desktops put users in 'video' by default and removing it breaks their
#     graphics for reasons they would never connect to us.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNINSTALL="${HERE}/../scripts/uninstall_local_ai.sh"
[[ -r "${UNINSTALL}" ]] || { echo "cannot read ${UNINSTALL}"; exit 1; }
[[ "${EUID}" -eq 0 ]] || { echo "must run as root, in a disposable container"; exit 1; }

PASS=0; FAIL=0
ok(){  printf '  [pass] %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){
  if [[ "$2" == "$3" ]]; then ok "$1"
  else bad "$1"; printf '         expected: %s\n         actual:   %s\n' "$3" "$2"; fi
}

U="patteros_test_user"
groupadd -f render >/dev/null 2>&1
groupadd -f video  >/dev/null 2>&1
useradd -m "${U}" >/dev/null 2>&1 || true
run(){ SUDO_USER="${U}" bash "${UNINSTALL}" "$@" >/dev/null 2>&1; }

echo "uninstaller: reversing an install without collateral damage"

# --- 1. exit codes ----------------------------------------------------------
run -y;        check "a successful reset exits 0" "$?" "0"
run --dry-run; check "a dry run exits 0"          "$?" "0"

# --- 2. ports are read back from the installed units, not assumed -----------
mkdir -p /etc/systemd/system
cat > /etc/systemd/system/llama.service <<'EOF'
[Service]
ExecStart=/x/llama-server --host 127.0.0.1 --port 9100 --models-max 1
EOF
cat > /etc/systemd/system/odysseus.service <<'EOF'
[Service]
ExecStart=/x/python -m uvicorn app:app --host 127.0.0.1 --port 9200
EOF
out="$(SUDO_USER="${U}" bash "${UNINSTALL}" --dry-run 2>&1)"
# The plan names the ports read from the units. That is the proof they were
# recovered: CI's ubuntu container has no ufw, so the firewall step never
# prints them, and looking for the old "9100/9200" slash form failed there
# even though read_port had the right numbers.
if grep -q 'LAN ports from the installed units: 9100 and 9200' <<<"${out}"; then
  ok "recovers custom ports from the unit files"
else
  bad "recovers custom ports from the unit files"
  printf '         expected the plan to name 9100 and 9200\n'
  grep -E 'Firewall|LAN ports' <<<"${out}" | sed 's/^/         /'
fi
if grep -q 'LAN ports from the installed units: 8020 and 7000' <<<"${out}"; then
  bad "does not fall back to the default ports"
else
  ok "does not fall back to the default ports"
fi
rm -f /etc/systemd/system/llama.service /etc/systemd/system/odysseus.service

# --- 3a. groups PatterOS added are removed ---------------------------------
usermod -aG render,video "${U}"
mkdir -p /var/lib/patteros
printf '%s render\n%s video\n' "${U}" "${U}" > /var/lib/patteros/groups-added
run -y
groups_now="$(id -nG "${U}" | tr ' ' '\n' | grep -cE '^(render|video)$' || true)"
check "removes both groups when PatterOS added both" "${groups_now}" "0"

# --- 3b. THE IMPORTANT ONE: a pre-existing group must survive --------------
usermod -aG render,video "${U}"
mkdir -p /var/lib/patteros
printf '%s render\n' "${U}" > /var/lib/patteros/groups-added   # only render was ours
run -y
if id -nG "${U}" | grep -qw video;  then ok "leaves a group the user already had ('video' survives)"
else bad "leaves a group the user already had ('video' survives)"; fi
if id -nG "${U}" | grep -qw render; then bad "still removes the group PatterOS added"
else ok "still removes the group PatterOS added"; fi

# --- 4. its own state is cleaned up ----------------------------------------
mkdir -p /var/lib/patteros; touch /var/lib/patteros/llama.service.sha
run -y
if [[ -d /var/lib/patteros ]]; then bad "removes its own state directory"
else ok "removes its own state directory"; fi

userdel -r "${U}" >/dev/null 2>&1 || true

echo
printf '%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
