#!/usr/bin/env bash
# =============================================================================
#  Drive install_local_ai.sh through the prompts a real user actually sees.
#
#  MUST BE RUN AS ROOT. Safe on a normal machine: every command that would
#  change anything is stubbed (see harness/stubs.sh), the service files are
#  redirected into a temporary directory, and PatterOS's own state directory is
#  redirected with it. Nothing outside the sandbox and the throwaway probe
#  user's home is touched.
#
#  WHY THIS EXISTS
#  ---------------
#  Every other suite runs the installer with -y, which skips every prompt. That
#  left the entire interactive surface untested: two confirmation gates, the
#  plan menu, the whole Customise dialogue, the skip-phases dialogue, the
#  "replace your edited service file?" question and the offer to reboot. That is
#  most of what a first-time user touches, and it is the part where a wrong
#  answer should mean "nothing happened" rather than "half a machine".
#
#  The two gates carry a promise in their own text: "nothing has been changed".
#  A test is the only thing that keeps that promise honest, so the declining
#  cases below assert not just the exit code and the message, but that no
#  package, compiler, clone or service call was ever made.
#
#  The installer deliberately reads from /dev/tty rather than stdin, so it
#  cannot be driven by a pipe. `script` gives it a pseudo-terminal whose input
#  we supply, which is why answers are fed that way below.
#
#  Run:  sudo bash tests/test_install_interactive.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
INSTALL="${ROOT}/scripts/install_local_ai.sh"
[[ -r "${INSTALL}" ]] || { echo "cannot read ${INSTALL}"; exit 1; }
[[ "${EUID}" -eq 0 ]] || { echo "must run as root"; exit 1; }
command -v script >/dev/null 2>&1 || { echo "'script' (bsdutils) is required to drive the prompts"; exit 1; }

PASS=0; FAIL=0
ok(){  printf '    [pass] %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '    [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && printf '           %s\n' "$2"; }
has(){   if grep -q -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "expected to find: $2"; fi; }
hasnt(){ if grep -q -- "$2" "$1" 2>/dev/null; then bad "$3" "did not expect: $2"; else ok "$3"; fi; }
# Regex variants, for asserting on the stub log. Every stub logs one line of
# "<command> <args>", so anchoring with ^ distinguishes a command that was RUN
# from a word that merely appears in another command's arguments. Without this,
# "was anything compiled?" matched the word cmake inside
# "apt-get install ... cmake git ...", and reported a build that never happened.
has_re(){   if grep -qE -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "expected to match: $2"; fi; }
hasnt_re(){ if grep -qE -- "$2" "$1" 2>/dev/null; then bad "$3" "did not expect a match for: $2"; else ok "$3"; fi; }
exits(){ if [[ "${RC}" -eq "$1" ]]; then ok "exits $1"; else bad "exits $1" "got ${RC}"; fi; }
exits_nonzero(){ if [[ "${RC}" -ne 0 ]]; then ok "refuses (non-zero exit)"; else bad "refuses (non-zero exit)" "got 0"; fi; }

U="patteros_probe"
id -u "${U}" >/dev/null 2>&1 || useradd -m "${U}" >/dev/null 2>&1
PROBE_HOME="$(getent passwd "${U}" | cut -d: -f6)"
if [[ -n "${PROBE_HOME}" && "${PROBE_HOME}" == /home/* && -d "${PROBE_HOME}" ]]; then
  rm -rf -- "${PROBE_HOME}/llama.cpp" "${PROBE_HOME}/odysseus" "${PROBE_HOME}/models" "${PROBE_HOME}/Downloads"
else
  echo "refusing to reset an unexpected home for ${U}: '${PROBE_HOME}'"; exit 1
fi

# Set PRESEED_UNIT to some content to put a llama.service on disk that PatterOS
# did not write, which is what a user who followed the manual guide's Step 10
# has. Cleared after every case so it cannot leak into the next one.
PRESEED_UNIT=""

# run_tty <name> <answers> [installer args...]
# Answers are one prompt per line, with \n escapes, fed through a pty.
run_tty(){
  local name="$1" answers="$2"; shift 2
  local args="$*"
  SANDBOX="$(mktemp -d)"
  export STUB_DIR="${SANDBOX}/bin" STUB_LOG="${SANDBOX}/calls.log"
  bash "${HERE}/harness/stubs.sh" >/dev/null

  mkdir -p "${SANDBOX}/etc" "${SANDBOX}/var"
  sed -e "s#/etc/systemd/system#${SANDBOX}/etc#g" \
      -e "s#^STAMP_DIR=\"/var/lib/patteros\"#STAMP_DIR=\"${SANDBOX}/var\"#" \
      "${INSTALL}" > "${SANDBOX}/install.sh"

  [[ -n "${PRESEED_UNIT}" ]] && printf '%s' "${PRESEED_UNIT}" > "${SANDBOX}/etc/llama.service"

  OUT="${SANDBOX}/stdout.txt"
  local p; p="$(cat "${STUB_DIR}-path")"
  printf '%b' "${answers}" \
    | script -qec "cd '${SANDBOX}' && PATH='${p}' SUDO_USER='${U}' bash '${SANDBOX}/install.sh' ${args}" /dev/null \
      > "${OUT}" 2>&1
  RC=$?
  # A pty echoes carriage returns; strip them so assertions match plain text.
  tr -d '\r' < "${OUT}" > "${OUT}.clean" && mv "${OUT}.clean" "${OUT}"
  UNIT="${SANDBOX}/etc/llama.service"
  CALLS="${SANDBOX}/calls.log"
  printf '\n  %s (exit %d)\n' "${name}" "${RC}"
}

# The whole point of the declining cases: prove the promise in the prompt text.
changed_nothing(){
  hasnt_re "${CALLS}" '^apt-get upgrade'    "no system upgrade was run"
  hasnt_re "${CALLS}" '^apt-get install'    "no packages were installed"
  hasnt_re "${CALLS}" '^cmake '             "nothing was compiled"
  hasnt_re "${CALLS}" '^systemctl enable'   "no service was enabled"
  hasnt_re "${CALLS}" '^ufw --force enable' "the firewall was not touched"
  hasnt_re "${CALLS}" '^(hf|huggingface-cli) download' "nothing was downloaded"
  if [[ ! -f "${UNIT}" ]]; then ok "no service file was written"; else bad "no service file was written"; fi
}

cleanup(){ rm -rf "${SANDBOX:-}" 2>/dev/null || true; }
trap cleanup EXIT

NV="STUB_GPU=nvidia STUB_NVIDIA=ok STUB_VRAM_MB=24576 STUB_DISK_GB=500"
export STUB_GPU=nvidia STUB_NVIDIA=ok STUB_VRAM_MB=24576 STUB_DISK_GB=500
: "${NV}"   # documents the scenario the cases below share

echo "installer: the prompts a real user sees"

# ---------------------------------------------------------------------------
# 1. Declining the very first gate must be a complete no-op.
# ---------------------------------------------------------------------------
run_tty "gate 1 declined ('n' at 'ready to go?')" 'n\n' --skip-firewall
exits 0
has "${OUT}" "have a read and come back" "answers kindly rather than scolding"
changed_nothing

# ---------------------------------------------------------------------------
# 2. Declining the hardware confirmation must also change nothing, and must
#    point the user somewhere useful if the detection was wrong.
# ---------------------------------------------------------------------------
run_tty "hardware gate declined ('n' at 'is this your computer?')" 'y\nn\n' --skip-firewall
exits 0
has "${OUT}" "Stopping here, and nothing has been changed" "says plainly that nothing changed"
has "${OUT}" "github.com/Daniel-Parke/PatterOS/issues" "tells the user where to report wrong detection"
changed_nothing

# ---------------------------------------------------------------------------
# 3. Quitting at the plan menu.
# ---------------------------------------------------------------------------
run_tty "plan menu quit ('q')" 'y\ny\nq\n' --skip-firewall
exits_nonzero
has "${OUT}" "Cancelled. Nothing changed." "confirms the cancellation"
changed_nothing

# ---------------------------------------------------------------------------
# 4. Accepting the plan with a bare Enter runs the defaults.
# ---------------------------------------------------------------------------
run_tty "plan accepted (bare Enter)" 'y\ny\n\n' --no-models --no-odysseus --skip-firewall
exits 0
has "${UNIT}" "--port 8020" "uses the default model server port"
has "${UNIT}" "-c 16384"    "uses the default context window"
has "${OUT}"  "Engine built" "proceeds to build the engine"

# ---------------------------------------------------------------------------
# 5. Customise: ports and context must actually reach the service file.
#    Order of prompts: llama port, odysseus port, context, tier, odysseus y/n,
#    LACT y/n (GPU rigs only), firewall y/n. Then back to the menu.
# ---------------------------------------------------------------------------
run_tty "customise ports and context" 'y\ny\nc\n9100\n9200\n8192\nnone\nn\nn\nn\n\n'
exits 0
has "${UNIT}" "--port 9100" "custom model server port reaches the unit"
has "${UNIT}" "-c 8192"     "custom context window reaches the unit"
has "${OUT}"  "9200"        "custom Odysseus port appears in the plan"
hasnt_re "${CALLS}" '^ufw --force enable' "declining the firewall really skips it"

# ---------------------------------------------------------------------------
# 6. A port below 1024 is rejected, and the old value is kept.
# ---------------------------------------------------------------------------
run_tty "customise, invalid port" 'y\ny\nc\n99\n\n\n none\nn\nn\nn\n\n' --no-odysseus --skip-firewall
has "${OUT}" "Invalid port; keeping 8020" "rejects a privileged port and keeps the default"
has "${UNIT}" "--port 8020" "the unit still has the safe default"

# ---------------------------------------------------------------------------
# 7. Giving Odysseus the same port as the engine must be refused.
# ---------------------------------------------------------------------------
run_tty "customise, Odysseus port collides" 'y\ny\nc\n8020\n8020\n\nnone\nn\nn\nn\n\n' --no-odysseus --skip-firewall
has "${OUT}" "Same as the model server" "spots the port collision"

# ---------------------------------------------------------------------------
# 8. A context window below the 2048 floor is rejected.
# ---------------------------------------------------------------------------
run_tty "customise, context too small" 'y\ny\nc\n\n\n1000\nnone\nn\nn\nn\n\n' --no-odysseus --skip-firewall
has "${OUT}" "Invalid context; keeping 16384" "rejects a context below the floor"
has "${UNIT}" "-c 16384" "the unit keeps the safe default"

# ---------------------------------------------------------------------------
# 9. Choosing the 'none' tier downloads nothing.
# ---------------------------------------------------------------------------
run_tty "customise, tier none" 'y\ny\nc\n\n\n\nnone\nn\nn\nn\n\n' --skip-firewall
has "${OUT}" "Skipping downloads" "skips downloads entirely"
hasnt_re "${CALLS}" '^(hf|huggingface-cli) download' "no download command was ever run"

# ---------------------------------------------------------------------------
# 10. Skip-phases dialogue: 1 = system upgrade, 3 = engine build.
# ---------------------------------------------------------------------------
run_tty "skip phases '1 3'" 'y\ny\ns\n1 3\n\n' --no-models --no-odysseus --skip-firewall
has "${OUT}" "Skipping 'apt upgrade'" "honours skipping the system upgrade"
hasnt_re "${CALLS}" '^apt-get upgrade' "apt upgrade really was not called"
has "${OUT}" "Lists were still refreshed" "is honest that apt update still ran"

# ---------------------------------------------------------------------------
# 11. An unknown phase number must be reported, not silently swallowed.
# ---------------------------------------------------------------------------
run_tty "skip phases, unknown token" 'y\ny\ns\n99 banana\n\n' --no-models --no-odysseus --skip-firewall
has "${OUT}" "Ignoring unknown phase" "warns about an unrecognised phase"

# ---------------------------------------------------------------------------
# 12. An unrecognised menu key must re-prompt rather than proceed blindly.
# ---------------------------------------------------------------------------
run_tty "plan menu, unrecognised key" 'y\ny\nz\n\n' --no-models --no-odysseus --skip-firewall
has "${OUT}" "Unrecognised choice" "tells the user the key meant nothing"
exits 0

# ---------------------------------------------------------------------------
# 13. THE IMPORTANT ONE. A service file PatterOS did not write (the state of
#     anyone who followed Step 10 and added an API key) must be kept when the
#     user declines the replacement, and must be backed up either way.
# ---------------------------------------------------------------------------
PRESEED_UNIT=$'[Service]\nExecStart=/x/llama-server --api-key hunter2 --host 0.0.0.0\n'
run_tty "hand-edited unit, replacement declined" 'y\ny\n\nn\n' --no-models --no-odysseus --skip-firewall
PRESEED_UNIT=""
has "${OUT}"  "has been edited since PatterOS wrote it" "notices the file is not ours"
has "${UNIT}" "hunter2" "KEEPS the user's API key"
if [[ -f "${UNIT}.patteros-backup" ]]; then ok "backs the user's version up"; else bad "backs the user's version up"; fi

# ---------------------------------------------------------------------------
# 14. The same situation, but the user asks for the standard version.
# ---------------------------------------------------------------------------
PRESEED_UNIT=$'[Service]\nExecStart=/x/llama-server --api-key hunter2 --host 0.0.0.0\n'
run_tty "hand-edited unit, replacement accepted" 'y\ny\n\ny\n' --no-models --no-odysseus --skip-firewall
PRESEED_UNIT=""
hasnt "${UNIT}" "hunter2" "replaces the unit when asked"
has "${UNIT}" "--models-max 1" "the standard unit is written"
if [[ -f "${UNIT}.patteros-backup" ]]; then ok "the old version is still recoverable"; else bad "the old version is still recoverable"; fi

# ---------------------------------------------------------------------------
# 15. A typo in a flag must stop immediately, before anything is touched.
# ---------------------------------------------------------------------------
run_tty "unknown flag" '' --definitely-not-a-flag
exits_nonzero
has "${OUT}" "Unknown option" "names the offending option"
changed_nothing

# ---------------------------------------------------------------------------
# 16. Accepting the offer to reboot must stop the run there. Continuing past it
#     would compile against a driver that is about to change underneath.
# ---------------------------------------------------------------------------
STUB_NVIDIA=notloaded run_tty "driver not loaded, reboot accepted" 'y\ny\n\ny\n' --no-models --no-odysseus --skip-firewall
exits 0
has_re "${CALLS}" '^systemctl reboot' "actually reboots when asked"
hasnt_re "${CALLS}" '^cmake ' "does NOT carry on building after choosing to reboot"

# ---------------------------------------------------------------------------
# 17. Declining the reboot must carry on and still produce a working engine.
# ---------------------------------------------------------------------------
STUB_NVIDIA=notloaded run_tty "driver not loaded, reboot declined" 'y\ny\n\nn\n' --no-models --no-odysseus --skip-firewall
exits 0
hasnt_re "${CALLS}" '^systemctl reboot' "does not reboot when declined"
has "${OUT}" "Engine built" "carries on and builds anyway"
has "${OUT}" "Reboot once so the NVIDIA driver loads" "still reminds the user at the end"

echo
printf '%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
