#!/usr/bin/env bash
# =============================================================================
#  Every command-line flag and environment override of install_local_ai.sh.
#
#  MUST BE RUN AS ROOT. Safe on a normal machine, for the same reason as the
#  other suites: harness/stubs.sh replaces every command that would change
#  anything, and the service directory and PatterOS state directory are
#  redirected into a temporary sandbox.
#
#  WHY THIS EXISTS
#  ---------------
#  The hardware matrix in test_install_paths.sh varies the MACHINE. This varies
#  what the USER ASKED FOR. Those are different failure modes: a flag that is
#  parsed and then quietly ignored looks like a successful install and leaves
#  someone with a service that does the opposite of what they typed. --cpu in
#  particular is the escape hatch we tell people to reach for when a GPU build
#  misbehaves, so it silently failing would strand exactly the users who are
#  already having a bad time.
#
#  It also pins the branches the matrix never reaches: a driver in the 'broken'
#  state, LACT already being installed, and sshd on a non-standard port.
#
#  Run:  sudo bash tests/test_install_flags.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
INSTALL="${ROOT}/scripts/install_local_ai.sh"
[[ -r "${INSTALL}" ]] || { echo "cannot read ${INSTALL}"; exit 1; }
[[ "${EUID}" -eq 0 ]] || { echo "must run as root"; exit 1; }

PASS=0; FAIL=0
ok(){  printf '    [pass] %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '    [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && printf '           %s\n' "$2"; }
has(){      if grep -q  -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "expected: $2"; fi; }
hasnt(){    if grep -q  -- "$2" "$1" 2>/dev/null; then bad "$3" "did not expect: $2"; else ok "$3"; fi; }
has_re(){   if grep -qE -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "expected match: $2"; fi; }
hasnt_re(){ if grep -qE -- "$2" "$1" 2>/dev/null; then bad "$3" "did not expect match: $2"; else ok "$3"; fi; }
exits(){    if [[ "${RC}" -eq "$1" ]]; then ok "exits $1"; else bad "exits $1" "got ${RC}"; fi; }

U="patteros_probe"
id -u "${U}" >/dev/null 2>&1 || useradd -m "${U}" >/dev/null 2>&1
PROBE_HOME="$(getent passwd "${U}" | cut -d: -f6)"
if [[ -n "${PROBE_HOME}" && "${PROBE_HOME}" == /home/* && -d "${PROBE_HOME}" ]]; then
  rm -rf -- "${PROBE_HOME}/llama.cpp" "${PROBE_HOME}/odysseus" "${PROBE_HOME}/models" "${PROBE_HOME}/Downloads"
else
  echo "refusing to reset an unexpected home for ${U}: '${PROBE_HOME}'"; exit 1
fi

PRESEED_UNIT=""

# run_case <name> [installer args...]   (scenario and env overrides via env)
run_case(){
  local name="$1"; shift
  SANDBOX="$(mktemp -d)"
  export STUB_DIR="${SANDBOX}/bin" STUB_LOG="${SANDBOX}/calls.log"
  bash "${HERE}/harness/stubs.sh" >/dev/null
  mkdir -p "${SANDBOX}/etc" "${SANDBOX}/var"
  sed -e "s#/etc/systemd/system#${SANDBOX}/etc#g" \
      -e "s#^STAMP_DIR=\"/var/lib/patteros\"#STAMP_DIR=\"${SANDBOX}/var\"#" \
      "${INSTALL}" > "${SANDBOX}/install.sh"
  if [[ -n "${PRESEED_UNIT}" ]]; then
    printf '%s' "${PRESEED_UNIT}" > "${SANDBOX}/etc/llama.service"
    # PRESEED_STAMP=1 also records the checksum PatterOS would have stored, which
    # is how the installer tells "a file we wrote" from "a file someone edited".
    if [[ "${PRESEED_STAMP:-0}" == "1" ]]; then
      printf '%s' "${PRESEED_UNIT}" | sha256sum | awk '{print $1}' > "${SANDBOX}/var/llama.service.sha"
    fi
  fi

  OUT="${SANDBOX}/stdout.txt"
  ( PATH="$(cat "${STUB_DIR}-path")"; export PATH
    export SUDO_USER="${U}"
    cd "${SANDBOX}" && bash "${SANDBOX}/install.sh" -y "$@"
  ) >"${OUT}" 2>&1
  RC=$?
  UNIT="${SANDBOX}/etc/llama.service"
  CALLS="${SANDBOX}/calls.log"
  printf '\n  %s (exit %d)\n' "${name}" "${RC}"
}

cleanup(){ rm -rf "${SANDBOX:-}" 2>/dev/null || true; }
trap cleanup EXIT

# Default scenario for the flag cases: a healthy 3090 Ti class rig, so any
# CPU-only or driver-free outcome below is caused by the flag, not the hardware.
export STUB_GPU=nvidia STUB_NVIDIA=ok STUB_VRAM_MB=24576 STUB_DISK_GB=500

echo "installer: flags and environment overrides"

# ---------------------------------------------------------------------------
# --cpu: the documented escape hatch. On a working NVIDIA rig it must produce a
# CPU engine and must not go anywhere near the driver.
# ---------------------------------------------------------------------------
run_case "--cpu on a healthy NVIDIA rig" --cpu --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "Engine built (cpu)" "builds the CPU engine"
has "${UNIT}" "-ngl 0" "asks for zero GPU layers"
hasnt_re "${CALLS}" '^ubuntu-drivers'                "does not touch the driver"
hasnt_re "${CALLS}" '^apt-get install.*cuda-toolkit' "does not install the CUDA toolkit"
hasnt_re "${CALLS}" '^apt-get install.*lact'         "does not install LACT with no GPU in use"

# ---------------------------------------------------------------------------
# --skip-upgrade. The distinction that matters: refreshing package LISTS is
# still fine, upgrading installed packages is what the user opted out of.
# ---------------------------------------------------------------------------
run_case "--skip-upgrade" --skip-upgrade --no-models --no-odysseus --skip-firewall
exits 0
hasnt_re "${CALLS}" '^apt-get upgrade' "no packages were upgraded"
has_re   "${CALLS}" '^apt-get update'  "package lists were still refreshed"
has "${OUT}" "Lists were still refreshed" "says so, rather than implying nothing happened"

# ---------------------------------------------------------------------------
# --skip-drivers on a rig with NO working driver: the user has taken the wheel,
# so we must not install anything, but we must still build something usable.
# ---------------------------------------------------------------------------
STUB_NVIDIA=missing run_case "--skip-drivers with no driver present" --skip-drivers --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "Skipping the driver phase entirely" "says the phase was skipped"
hasnt_re "${CALLS}" '^ubuntu-drivers' "installs no driver"
has "${OUT}" "Engine built" "still produces an engine"

# ---------------------------------------------------------------------------
# --skip-build. Nothing must be compiled.
# ---------------------------------------------------------------------------
run_case "--skip-build" --skip-build --no-models --no-odysseus --skip-firewall
exits 0
hasnt_re "${CALLS}" '^cmake ' "nothing was compiled"

# ---------------------------------------------------------------------------
# Reuse vs rebuild. The probe user's home is shared across the cases in this
# file, so by now ~/llama.cpp is already built: exactly the state of a user
# re-running the installer.
# ---------------------------------------------------------------------------
run_case "second run reuses the existing engine" --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "already built" "reuses the engine instead of recompiling"

run_case "--rebuild forces a recompile" --rebuild --no-models --no-odysseus --skip-firewall
exits 0
has_re "${CALLS}" '^cmake ' "compiles again when asked"

# ---------------------------------------------------------------------------
# --replace-units. With -y there is no prompt, so this flag is the ONLY way a
# hand-edited unit gets overwritten. It must still leave a backup.
# ---------------------------------------------------------------------------
PRESEED_UNIT=$'[Service]\nExecStart=/x/llama-server --api-key hunter2\n'
run_case "hand-edited unit, -y WITHOUT --replace-units" --no-models --no-odysseus --skip-firewall
has "${UNIT}" "hunter2" "keeps the user's file by default"
has "${OUT}" "Keeping your llama.service unchanged" "says it kept the user's file"
has "${OUT}" "Use --replace-units to overwrite" "tells the user how to override that"

PRESEED_UNIT=$'[Service]\nExecStart=/x/llama-server --api-key hunter2\n'
run_case "hand-edited unit, --replace-units" --replace-units --no-models --no-odysseus --skip-firewall
PRESEED_UNIT=""
hasnt "${UNIT}" "hunter2" "overwrites when explicitly asked"
hasnt "${OUT}" "your version is kept" "does not say it kept the file while replacing it"
has "${OUT}" "Replaced llama.service" "says it replaced the file"
if [[ -f "${UNIT}.patteros-backup" ]]; then ok "still leaves a backup"; else bad "still leaves a backup"; fi

# ---------------------------------------------------------------------------
# LACT.
# ---------------------------------------------------------------------------
run_case "--lact on a GPU rig" --lact --no-models --no-odysseus --skip-firewall
has_re "${CALLS}" '^(wget|apt-get install).*lact' "fetches and installs LACT"

run_case "--no-lact" --no-lact --no-models --no-odysseus --skip-firewall
has "${OUT}" "Skipping LACT" "skips LACT when told to"
hasnt_re "${CALLS}" '^wget.*lact' "downloads nothing"

STUB_INSTALLED="lact" run_case "LACT already installed" --lact --no-models --no-odysseus --skip-firewall
has "${OUT}" "LACT is already installed" "recognises an existing install"
hasnt_re "${CALLS}" '^wget.*lact' "does not download it again"

# ---------------------------------------------------------------------------
# --no-models must actually download nothing.
#
# Every other case in this file passes --no-models to keep itself quick, and not
# one of them ever checked that it worked. It did not: the flag set a variable
# that the tier calculation then overwrote, so anyone who asked for no models
# got the express set anyway, about 7 GB they had explicitly declined. This
# suite exists to catch a flag that parses and is then ignored, and it had that
# exact bug sitting inside almost every case in it.
# ---------------------------------------------------------------------------
run_case "--no-models downloads nothing" --no-models --no-odysseus --skip-firewall
exits 0
has     "${OUT}"   "Skipping downloads" "says it is skipping the download"
hasnt_re "${CALLS}" '^(hf|huggingface-cli) download' "runs no download command"
hasnt   "${OUT}"   "model(s) downloaded" "does not report models it never fetched"

# ---------------------------------------------------------------------------
# --full asks for all six models AND every one of them verifies.
#
# Asking is not the same as arriving. The four `has` lines below match the
# "Fetching ..." line, which is printed before the download is attempted, so on
# their own they would pass against a tier where nothing landed at all. That is
# not hypothetical: for one release the harness could not produce either Qwen
# file and every run here reported two of six as failed, in silence, because
# nothing looked at the count. The last three assertions are the ones that
# would have caught it.
# ---------------------------------------------------------------------------
run_case "--full model tier" --full --no-odysseus --skip-firewall
exits 0
has "${OUT}" "12B" "includes the 12B model"
has "${OUT}" "31B" "includes the 31B model"
has "${OUT}" "unsloth/Qwen3.8-27B-GGUF" "includes Unsloth Qwen3.8 UD"
has "${OUT}" "AtomicChat/Qwen3.8-27B-GGUF" "includes AtomicChat Qwen3.8 AD"
hasnt "${OUT}" "IQ3_XXS" "does not auto-download the 16 GB IQ3"
# `has`, not `has_re`: the helper greps a basic regex, where the brackets in
# "model(s)" are literal. Under -E they would be a group and this would silently
# stop matching the very string it exists to check.
has   "${OUT}" "All 6 model(s) downloaded" "all six verify after downloading"
hasnt "${OUT}" "may be incomplete"  "no model is reported as the wrong size"
hasnt "${OUT}" "no file matching"   "every requested file is found afterwards"

# ---------------------------------------------------------------------------
# Environment overrides.
# ---------------------------------------------------------------------------
CTX=32768 run_case "CTX=32768" --no-models --no-odysseus --skip-firewall
has "${UNIT}" "-c 32768" "context override reaches the unit"

NGL=7 run_case "NGL=7" --no-models --no-odysseus --skip-firewall
has "${UNIT}" "-ngl 7" "GPU-layer override reaches the unit"
has "${OUT}" "Using GPU layers from the environment" "tells the user the override was taken"

NGL=banana run_case "NGL=banana" --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "Ignoring NGL" "rejects a non-numeric override instead of writing nonsense"
has_re "${UNIT}" '\-ngl [0-9]+' "falls back to a sane numeric value"

LLAMA_VERSION=master run_case "LLAMA_VERSION=master" --no-models --no-odysseus --skip-firewall
has "${OUT}" "master" "mentions that master is untested"

LLAMA_VERSION=b9999 run_case "LLAMA_VERSION=b9999" --no-models --no-odysseus --skip-firewall
has "${CALLS}" "b9999" "checks out the requested tag"

# ---------------------------------------------------------------------------
# An llama.cpp checkout that is already on disk at the WRONG version.
#
# This is not a corner case. It is the state of anyone who re-runs the
# installer after the pin moves, and of anyone who followed the manual guide
# and cloned llama.cpp themselves, which leaves them on master. The version
# matters for a specific reason: before tag b9702 the router accepted -ngl and
# -c and then silently discarded them, so the service starts, looks healthy,
# and runs entirely on the CPU. Building the wrong source while the header
# claims the pinned tag would hide exactly that.
# ---------------------------------------------------------------------------
STUB_GIT_AT=b10313 LLAMA_VERSION=b9999 run_case "existing checkout at the wrong version" --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "It is at b10313, so switching it to b9999" "notices and reports the mismatch"
has_re "${CALLS}" '^git .*fetch .*b9999'    "fetches the requested tag"
has_re "${CALLS}" '^git .*checkout .*b9999' "checks it out"
has "${OUT}" "Source is now at b9999" "confirms the switch"
has_re "${CALLS}" '^cmake ' "rebuilds, because the source moved and the old build is stale"

STUB_GIT_AT=b9999 LLAMA_VERSION=b9999 run_case "existing checkout already at the right version" --no-models --no-odysseus --skip-firewall
exits 0
hasnt_re "${CALLS}" '^git .*fetch' "does no needless network work"
hasnt "${OUT}" "switching it to" "stays quiet when there is nothing to do"

STUB_GIT_AT=b10313 STUB_GIT_DIRTY=1 LLAMA_VERSION=b9999 run_case "wrong version, but the user has local edits" --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "uncommitted" "notices the local changes"
hasnt_re "${CALLS}" '^git .*checkout .*b9999' "does NOT throw the user's work away"
has "${OUT}" "move ${PROBE_HOME}/llama.cpp aside" "tells the user how to get the pinned version"

STUB_GIT_AT=b10313 STUB_GIT_FETCH_FAIL=1 LLAMA_VERSION=bNOPE run_case "requested tag does not exist" --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "Could not switch to bNOPE" "says the switch failed instead of pretending it worked"
has "${OUT}" "Engine built" "still finishes with a working engine"

# ---------------------------------------------------------------------------
# The 'broken' driver state: nvidia-smi is present but fails for a reason that
# is neither a mismatch nor an unloaded module.
# ---------------------------------------------------------------------------
STUB_NVIDIA=broken run_case "driver state: broken" --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "state: broken" "names the state it detected"
has_re "${CALLS}" '^ubuntu-drivers' "installs a driver, since none is working"
has "${OUT}" "Engine built" "still completes the build"

# ---------------------------------------------------------------------------
# Post-upgrade watchdog. A healthy driver can become a mismatch solely because
# apt upgrade replaced files on disk. Reinstalling on top of that is the
# failure this check exists to prevent.
# ---------------------------------------------------------------------------
STUB_GPU=nvidia STUB_NVIDIA=ok STUB_NVIDIA_AFTER_UPGRADE=mismatch STUB_VRAM_MB=24576 \
  run_case "apt upgrade replaced NVIDIA driver files" --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "replaced NVIDIA driver files" "detects the post-upgrade mismatch"
has "${OUT}" "Phase 2 will leave the driver alone" "promises not to reinstall"
hasnt_re "${CALLS}" '^ubuntu-drivers' "does NOT reinstall on top of a post-upgrade mismatch"
has "${OUT}" "Reboot" "asks for the one reboot that actually fixes it"

# ---------------------------------------------------------------------------
# The firewall. This phase can lock a user out of their own machine, so the SSH
# rule has to come first, and it has to follow the port sshd actually uses.
# ---------------------------------------------------------------------------
STUB_SSH_PORT=2222 run_case "firewall with sshd on a non-standard port" --no-models --no-odysseus
exits 0
has "${CALLS}" "ufw allow 2222/tcp" "allows the real SSH port"
if [[ "$(grep -n 'ufw allow 2222/tcp' "${CALLS}" | head -1 | cut -d: -f1)" -lt \
      "$(grep -n 'ufw --force enable' "${CALLS}" | head -1 | cut -d: -f1)" ]]; then
  ok "allows SSH BEFORE enabling the firewall"
else
  bad "allows SSH BEFORE enabling the firewall" "order would lock out a remote user"
fi

# ---------------------------------------------------------------------------
# One broken third-party apt repository must not end the install.
#
# This is not hypothetical: the machine these tests were written on has exactly
# this problem (an editor's repo with an unverifiable key), and it stopped the
# real installer dead at step 1 with nothing but a line number. Expired or
# missing keys on third-party repos are among the most common states a real
# Linux desktop is in, so this has to degrade gracefully.
# ---------------------------------------------------------------------------
STUB_APT_UPDATE_FAIL=1 run_case "a broken third-party apt repository" --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "Refreshing the package lists reported a problem" "reports the problem"
has "${OUT}" "not signed" "shows apt's own message, so the repo can be identified"
has "${OUT}" "not something PatterOS changed" "makes clear this is pre-existing"
has "${OUT}" "signing key has expired" "names the usual cause"
has "${OUT}" "does not stop the install" "reassures the user"
has "${OUT}" "Engine built" "and genuinely carries on to a working engine"
has "${OUT}" "Local AI is set up." "reaching the closing summary"

# ---------------------------------------------------------------------------
# A port that something else already owns.
#
# This is the failure mode that used to be reported as a driver problem: the
# service cannot bind, and the readiness check then talked to whatever DOES own
# the port and announced a healthy server. Both halves are checked here.
# ---------------------------------------------------------------------------
STUB_BUSY_PORTS="8020:some-other-app" STUB_SVC_DEAD="llama.service" \
  run_case "port 8020 already taken by another program" --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "ALREADY IN USE by" "flags the clash in the plan, before anything changes"
has "${OUT}" "some-other-app" "names the program holding the port"
has "${OUT}" "choose a different port" "says how to resolve it while it is still free to do so"
has "${OUT}" "llama.service is not running" "admits the service did not start"
has "${OUT}" "could not bind to it" "gives the real reason"
hasnt "${OUT}" "Server is answering" "does NOT report a healthy server that is not ours"
hasnt "${OUT}" "NVIDIA usually needs the reboot" "does not blame the driver for a port clash"

STUB_BUSY_PORTS="8020:llama-server" \
  run_case "re-run with PatterOS's own service on the port" --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "in use by PatterOS's own llama.service" "recognises its own service"
hasnt "${OUT}" "ALREADY IN USE" "does not alarm the user about itself"

# ---------------------------------------------------------------------------
# A rewritten unit has to be APPLIED, not just written. systemd's `start` is a
# no-op on a running service, so without a restart the old process keeps serving
# with the old port and context window while everything here reports success.
# ---------------------------------------------------------------------------
run_case "first install starts the service" --no-models --no-odysseus --skip-firewall
exits 0
has_re "${CALLS}" '^systemctl restart llama.service' "starts the newly written service"
SAVED_UNIT="$(cat "${UNIT}")"

PRESEED_UNIT="${SAVED_UNIT}"; PRESEED_STAMP=1
run_case "re-run with an identical unit" --no-models --no-odysseus --skip-firewall
has "${OUT}" "already exactly as we want it" "notices there is nothing to change"
hasnt_re "${CALLS}" '^systemctl restart llama.service' "does not disturb a healthy server for no reason"

PRESEED_UNIT="${SAVED_UNIT}"; PRESEED_STAMP=1
CTX=32768 run_case "re-run that CHANGES the context window" --no-models --no-odysseus --skip-firewall
PRESEED_UNIT=""; PRESEED_STAMP=0
has "${OUT}" "Updated llama.service" "rewrites its own unit"
has "${UNIT}" "-c 32768" "the new context window is in the unit"
has_re "${CALLS}" '^systemctl restart llama.service' "RESTARTS, so the new setting actually takes effect"

# ---------------------------------------------------------------------------
# The pinned Odysseus commit ships a NameError: two helpers are annotated with
# dict[str, Any] while Any is never imported, so the module cannot be imported
# and the workspace crash-loops on every machine. Upstream fixed it on dev and
# never merged it to main, so the installer carries the one-line fix.
# ---------------------------------------------------------------------------
seed_odysseus(){ # $1 = the typing import line to plant
  mkdir -p "${PROBE_HOME}/odysseus/src" "${PROBE_HOME}/odysseus/.git"
  { printf '%s\n' "$1"
    printf 'def _resolved_tool_event_name(event: dict[str, Any]) -> str:\n    return ""\n'
  } > "${PROBE_HOME}/odysseus/src/agent_loop.py"
  chown -R "${U}:${U}" "${PROBE_HOME}/odysseus"
}
ODY_AL="${PROBE_HOME}/odysseus/src/agent_loop.py"

seed_odysseus 'from typing import AsyncGenerator, List, Dict, Optional, Set'
run_case "the pinned Odysseus commit is missing its Any import" --no-models --skip-firewall
exits 0
has "${ODY_AL}" "from typing import Any, AsyncGenerator" "adds the missing import"
has "${OUT}" "Applied one upstream Odysseus fix" "tells the user it carried a fix, rather than doing it silently"

# Once upstream merges the fix, this must become a no-op rather than mangling a
# file that is already correct.
seed_odysseus 'from typing import Any, AsyncGenerator, List, Dict, Optional, Set'
run_case "Odysseus already has the fix upstream" --no-models --skip-firewall
exits 0
has "${ODY_AL}" "from typing import Any, AsyncGenerator" "leaves the correct import alone"
hasnt "${ODY_AL}" "from typing import Any, Any," "does not apply the fix twice"
hasnt "${OUT}" "Applied one upstream Odysseus fix" "stays quiet when there is nothing to fix"
rm -rf "${PROBE_HOME}/odysseus"

# ---------------------------------------------------------------------------
# A service that starts and then dies must never be reported as working.
#
# These units are Type=simple, so systemd calls them active the instant the
# process is forked. `is-active` a moment after `restart` therefore returns
# success for a service whose Python is about to fail on an import error, which
# is exactly how a real install came to print "Odysseus installed" and a
# clickable URL for a workspace stuck in a permanent restart loop. The rising
# restart counter is the only reliable signal, so that is what is checked.
# ---------------------------------------------------------------------------
STUB_SVC_LOOPING="odysseus.service" STUB_CURL_FAIL="7000" \
  run_case "the workspace starts, dies, and keeps restarting" --no-models --skip-firewall
exits 0
has "${OUT}" "starts and then immediately exits" "says plainly that the workspace is broken"
has "${OUT}" "not in your machine" "makes clear the user's hardware is not at fault"
has "${OUT}" "last few lines of its log" "shows the error instead of setting homework"
has "${OUT}" "disable --now odysseus.service" "offers a way to stop the retry loop"
has "${OUT}" "Workspace:     NOT RUNNING" "the closing summary agrees with reality"
hasnt "${OUT}" "log in as 'admin'" "does NOT print a login URL for something that is down"
has "${OUT}" "model server above is fine" "reassures that the rest of the install is usable"
rm -f "${STUB_DIR}/.restarts-odysseus.service"

STUB_SVC_DEAD="llama.service" STUB_CURL_FAIL="8020" \
  run_case "the model server never comes up" --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "llama.service is not running" "admits the service is down"
has "${OUT}" "Model server:  NOT RUNNING" "the closing summary does not advertise a dead server"
hasnt "${OUT}" "Server is answering" "does not claim it is answering"

# Nothing may be trusted just because the port replies: a foreign program on the
# port answers too, and calling that a healthy PatterOS service is worse than
# saying nothing at all.
STUB_SVC_DEAD="llama.service" \
  run_case "another program answers on our port while our service is down" \
  --no-models --no-odysseus --skip-firewall
exits 0
hasnt "${OUT}" "Server is answering" "an answer on the port is not accepted as proof"
has "${OUT}" "llama.service is not running" "reports the truth about our own unit"

# ---------------------------------------------------------------------------
# A rebuilt engine has to reach the running service.
#
# On Linux a process keeps its executable alive by inode, so deleting
# ~/llama.cpp/build under a running llama-server does not stop it: it carries on
# from a file that no longer exists. With the unit unchanged, nothing restarted
# it, so --rebuild produced a new binary that the machine went on ignoring until
# its next reboot, while the summary named the engine it had just built.
# ---------------------------------------------------------------------------
run_case "an engine to rebuild exists" --no-models --no-odysseus --skip-firewall
SAVED_UNIT="$(cat "${UNIT}")"

PRESEED_UNIT="${SAVED_UNIT}"; PRESEED_STAMP=1
run_case "--rebuild while the service is running and the unit is unchanged" --rebuild --no-models --no-odysseus --skip-firewall
PRESEED_UNIT=""; PRESEED_STAMP=0
exits 0
has "${OUT}" "already exactly as we want it" "the unit itself did not change"
has_re "${CALLS}" '^systemctl stop llama.service' "stops the service before deleting the build directory"
has "${OUT}" "Stopping llama.service while the engine rebuilds" "says why it is going down"
has_re "${CALLS}" '^systemctl restart llama.service' "restarts it afterwards, unit change or not"
has "${OUT}" "so it runs the engine just built" "explains that the restart is what adopts the new engine"

# ---------------------------------------------------------------------------
# Build parallelism. llama.cpp's CUDA translation units are large, and -j nproc
# on a machine with more cores than spare gigabytes is how a build takes the
# desktop down with it. The cap has to be visible and overridable.
# ---------------------------------------------------------------------------
JOBS=2 run_case "JOBS=2" --rebuild --no-models --no-odysseus --skip-firewall
exits 0
has_re "${CALLS}" '^cmake --build .* -j2$' "compiles with exactly the requested number of jobs"
has "${OUT}" "from JOBS in the environment" "says where the number came from"

JOBS=banana run_case "JOBS=banana" --rebuild --no-models --no-odysseus --skip-firewall
exits 0
has "${OUT}" "Ignoring JOBS" "rejects a non-numeric override"
has_re "${CALLS}" '^cmake --build .* -j[1-9][0-9]*$' "still passes a sane job count"

run_case "no JOBS override" --rebuild --no-models --no-odysseus --skip-firewall
exits 0
jobs_used="$(grep -oE '^cmake --build .* -j[0-9]+' "${CALLS}" | grep -oE '[0-9]+$' | head -1)"
if [[ -n "${jobs_used}" ]] && (( jobs_used >= 1 && jobs_used <= $(nproc) )); then
  ok "picks a job count between 1 and the core count (${jobs_used} of $(nproc))"
else
  bad "picks a job count between 1 and the core count" "got '${jobs_used}', cores $(nproc)"
fi

# ---------------------------------------------------------------------------
# What gets recorded as "installed by PatterOS".
#
# The uninstaller's --packages and --drivers used to work from a fixed list and
# a wildcard, which is not a reversal of an install: --packages included
# mesa-vulkan-drivers, the graphics driver on AMD and Intel, and --drivers swept
# up every nvidia-* and cuda-* package on the machine. Both now read this record,
# so what goes into it is the thing worth testing.
# ---------------------------------------------------------------------------
run_case "records the packages it installed" --no-models --no-odysseus --skip-firewall
exits 0
ADDED="${SANDBOX}/var/packages-added"
if [[ -f "${ADDED}" ]]; then ok "writes a record of what it installed"
else bad "writes a record of what it installed" "no ${ADDED}"; fi
has "${ADDED}" "cmake" "records a package it installed"
has "${ADDED}" "mesa-vulkan-drivers" "records the Vulkan driver it installed on a bare machine"

STUB_INSTALLED="tmux mesa-vulkan-drivers" \
  run_case "does not claim packages the user already had" --no-models --no-odysseus --skip-firewall
exits 0
ADDED="${SANDBOX}/var/packages-added"
hasnt "${ADDED}" "tmux" "a package that was already installed is not recorded as ours"
hasnt "${ADDED}" "mesa-vulkan-drivers" "nor is the pre-existing graphics driver"

STUB_NVIDIA=missing STUB_DRIVER_ADDS="nvidia-driver-595 libnvidia-compute-595" \
  run_case "records the driver packages ubuntu-drivers added" --no-models --no-odysseus --skip-firewall
exits 0
ADDED="${SANDBOX}/var/packages-added"
has "${ADDED}" "nvidia-driver-595" "records the driver it installed"
has "${ADDED}" "libnvidia-compute-595" "records its libraries too"

STUB_NVIDIA=missing STUB_INSTALLED="nvidia-driver-535 libnvidia-compute-535" \
  STUB_DRIVER_ADDS="nvidia-driver-595" \
  run_case "leaves an older driver series out of the record" --no-models --no-odysseus --skip-firewall
exits 0
ADDED="${SANDBOX}/var/packages-added"
has "${ADDED}" "nvidia-driver-595" "records what it installed"
hasnt "${ADDED}" "nvidia-driver-535" "does not claim a driver series that was already here"
hasnt "${ADDED}" "libnvidia-compute-535" "nor its libraries"

# ---------------------------------------------------------------------------
# The firewall and a unit that listens on the network.
#
# install_unit keeps a hand-edited service file on purpose, and Steps 10 and 11
# of the guide tell people to bind 0.0.0.0 for other devices. The firewall step
# then printed "listen on this computer only, private by default", which was
# false, and enabled a firewall that blocked the port they had opened, without
# mentioning it.
# ---------------------------------------------------------------------------
run_case "firewall with the units we wrote" --no-models --no-odysseus
exits 0
has "${OUT}" "listen on this computer only" "says private, and is telling the truth"

PRESEED_UNIT=$'[Service]\nExecStart=/x/llama-server --host 0.0.0.0 --port 8020\n'
run_case "firewall with a unit the user pointed at the network" --no-models --no-odysseus
PRESEED_UNIT=""
exits 0
hasnt "${OUT}" "listen on this computer only" "does not claim privacy it cannot see"
has "${OUT}" "listen on your whole network" "points out what the unit actually does"
has "${OUT}" "port 8020 is now blocked" "warns that the firewall has just closed it"
has "${OUT}" "sudo ufw allow 8020/tcp" "gives the exact command to open it"
has "${OUT}" "That was your edit, so it is left alone" "makes clear it changed nothing behind their back"
has "${OUT}" "network you trust" "and does not open a port on the user's behalf"

# ---------------------------------------------------------------------------
# Odysseus's first-run password.
#
# upstream's create_default_admin() returns at "auth.json already exists" before
# it reads ODYSSEUS_ADMIN_PASSWORD, so on a re-run the password we generate is
# applied to nothing. Writing it to the first-login file anyway replaced a
# working credential with one that cannot log in, which is worst for the exact
# person most likely to re-run the installer: someone who has lost their
# password and is looking for it.
# ---------------------------------------------------------------------------
seed_ody_auth(){ # $1 = yes|no, does data/auth.json already exist
  mkdir -p "${PROBE_HOME}/odysseus/data" "${PROBE_HOME}/odysseus/src" "${PROBE_HOME}/odysseus/.git"
  if [[ "$1" == "yes" ]]; then printf '{"users":{"admin":{}}}\n' > "${PROBE_HOME}/odysseus/data/auth.json"
  else rm -f "${PROBE_HOME}/odysseus/data/auth.json"; fi
  chown -R "${U}:${U}" "${PROBE_HOME}/odysseus"
}

seed_ody_auth no
run_case "first Odysseus install creates the admin account" --no-models --skip-firewall
exits 0
has "${OUT}" "First-run login for Odysseus has been saved" "records the password it set"
if [[ -f "${SANDBOX}/var/odysseus-first-login.txt" ]]; then ok "writes the first-login file"
else bad "writes the first-login file" "no odysseus-first-login.txt"; fi

seed_ody_auth yes
run_case "re-run when Odysseus already has an admin account" --no-models --skip-firewall
exits 0
hasnt "${OUT}" "First-run login for Odysseus has been saved" "does not claim to have set a password"
has "${OUT}" "your existing login still applies" "says the old credential is the live one"
has "${OUT}" "delete ${PROBE_HOME}/odysseus/data/auth.json" "explains how to start a fresh account"
if [[ -f "${SANDBOX}/var/odysseus-first-login.txt" ]]; then
  bad "does not write a password that was never applied" "wrote odysseus-first-login.txt anyway"
else
  ok "does not write a password that was never applied"
fi
rm -rf "${PROBE_HOME}/odysseus"

# ---------------------------------------------------------------------------
# --help must document every flag the parser accepts. Drift here is how people
# end up unable to find the escape hatch they need.
# ---------------------------------------------------------------------------
printf '\n  --help documents every flag\n'
HELP="$(bash "${INSTALL}" --help 2>&1)"; RC=$?
exits 0
PARSED="$(sed -n '/^while \[\[ \$# -gt 0/,/^esac; shift; done/p' "${INSTALL}" \
          | grep -oE '^\s+(--[a-z-]+)' | tr -d ' ' | sort -u)"
missing=""
for f in ${PARSED}; do grep -q -- "${f}" <<<"${HELP}" || missing="${missing} ${f}"; done
if [[ -z "${missing}" ]]; then ok "every parsed flag appears in --help"
else bad "every parsed flag appears in --help" "undocumented:${missing}"; fi
has_re <(printf '%s' "${HELP}") 'CTX' "documents the CTX override"
has_re <(printf '%s' "${HELP}") 'NGL' "documents the NGL override"
has_re <(printf '%s' "${HELP}") 'JOBS' "documents the JOBS override"

echo
printf '%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
