#!/usr/bin/env bash
# =============================================================================
#  uninstall_local_ai.sh, across every combination of flags.
#
#  MUST BE RUN AS ROOT. Safe on a normal machine, and being safe matters more
#  here than anywhere else in this suite, because this script's job is deletion.
#  Three things keep it contained:
#    - harness/stubs.sh replaces apt-get, ufw, systemctl, dpkg and gpasswd, so
#      nothing is really purged, disabled or removed from a group,
#    - /etc/systemd/system and /var/lib/patteros are rewritten into a temporary
#      sandbox, so the real service files are never in scope,
#    - everything it is allowed to delete lives under a throwaway probe user's
#      home, which this file creates and refills before every case.
#
#  The repository also ships tests/test_uninstall_reversal.sh, which runs the
#  real uninstaller with NO stubs. That one genuinely removes llama.service and
#  odysseus.service and deletes ~/llama.cpp, so it belongs in a disposable
#  container and must never be pointed at a machine anyone uses. This file
#  covers the same ground, plus the flags that suite never reaches, safely.
#
#  WHY THE FLAG COVERAGE MATTERS
#  -----------------------------
#  Every flag here is destructive and most are irreversible without a download
#  or a reinstall. The two properties worth proving are that each flag removes
#  what it promises, and that it removes NOTHING ELSE: --packages must not take
#  git or python3 with it, --models must not fire unless asked, and no path may
#  ever delete outside the user's home.
#
#  Run:  sudo bash tests/test_uninstall_paths.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
UNINSTALL="${ROOT}/scripts/uninstall_local_ai.sh"
[[ -r "${UNINSTALL}" ]] || { echo "cannot read ${UNINSTALL}"; exit 1; }
[[ "${EUID}" -eq 0 ]] || { echo "must run as root"; exit 1; }

PASS=0; FAIL=0
ok(){  printf '    [pass] %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '    [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && printf '           %s\n' "$2"; }
has(){      if grep -q  -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "expected: $2"; fi; }
hasnt(){    if grep -q  -- "$2" "$1" 2>/dev/null; then bad "$3" "did not expect: $2"; else ok "$3"; fi; }
has_re(){   if grep -qE -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "expected match: $2"; fi; }
hasnt_re(){ if grep -qE -- "$2" "$1" 2>/dev/null; then bad "$3" "did not expect match: $2"; else ok "$3"; fi; }
exits(){    if [[ "${RC}" -eq "$1" ]]; then ok "exits $1"; else bad "exits $1" "got ${RC}"; fi; }
gone(){     if [[ ! -e "$1" ]]; then ok "$2"; else bad "$2" "still exists: $1"; fi; }
kept(){     if [[   -e "$1" ]]; then ok "$2"; else bad "$2" "was removed: $1"; fi; }

U="patteros_probe"
id -u "${U}" >/dev/null 2>&1 || useradd -m "${U}" >/dev/null 2>&1
PROBE_HOME="$(getent passwd "${U}" | cut -d: -f6)"
[[ -n "${PROBE_HOME}" && "${PROBE_HOME}" == /home/* && -d "${PROBE_HOME}" ]] \
  || { echo "refusing to use an unexpected home for ${U}: '${PROBE_HOME}'"; exit 1; }

# Put the probe user's home into the state a finished install leaves behind, and
# build matching service files and checksum records in the sandbox.
# SEED_MODE=none instead leaves nothing installed at all, which is the state of a
# rig where setup failed halfway, or that has already been reset.
seed_installed(){
  rm -rf -- "${PROBE_HOME}/llama.cpp" "${PROBE_HOME}/odysseus" "${PROBE_HOME}/models" "${PROBE_HOME}/Downloads"
  if [[ "${SEED_MODE:-installed}" == "none" ]]; then
    mkdir -p "${SANDBOX}/etc"
    return 0
  fi
  mkdir -p "${PROBE_HOME}/llama.cpp/build/bin" "${PROBE_HOME}/odysseus/venv" \
           "${PROBE_HOME}/models" "${PROBE_HOME}/Downloads" "${PROBE_HOME}/.cache/huggingface"
  # A finished install always has this: Odysseus keeps every note, upload,
  # setting and chat transcript in one directory inside its own clone.
  if [[ "${SEED_ODY_DATA:-yes}" == "yes" ]]; then
    mkdir -p "${PROBE_HOME}/odysseus/data/personal_docs"
    printf 'my notes\n' > "${PROBE_HOME}/odysseus/data/personal_docs/notes.md"
    printf '{}\n' > "${PROBE_HOME}/odysseus/data/sessions.json"
  fi
  rm -rf -- "${PROBE_HOME}"/odysseus-data-backup-*
  : > "${PROBE_HOME}/llama.cpp/build/bin/llama-server"
  : > "${PROBE_HOME}/models/gemma-4-E2B-it-UD-Q4_K_XL.gguf"
  : > "${PROBE_HOME}/Downloads/lact.deb"
  chown -R "${U}:${U}" "${PROBE_HOME}/llama.cpp" "${PROBE_HOME}/odysseus" \
                       "${PROBE_HOME}/models" "${PROBE_HOME}/Downloads" 2>/dev/null || true
  mkdir -p "${SANDBOX}/etc" "${SANDBOX}/var"
  printf '[Service]\nExecStart=/x/llama-server --host 127.0.0.1 --port %s -ngl 99\n' "${SEED_PORT_LLAMA:-8020}" \
    > "${SANDBOX}/etc/llama.service"
  printf '[Service]\nExecStart=/x/python -m uvicorn app:app --host 127.0.0.1 --port %s\n' "${SEED_PORT_ODY:-7000}" \
    > "${SANDBOX}/etc/odysseus.service"
  : > "${SANDBOX}/var/llama.service.sha"
  printf '%s render\n%s video\n' "${U}" "${U}" > "${SANDBOX}/var/groups-added"
  printf 'Password: hunter2\n' > "${SANDBOX}/var/odysseus-first-login.txt"
  # The installer's record of the packages it put on the machine. Both --packages
  # and --drivers work from this now, so most cases want a realistic one; a case
  # can pass SEED_PKGS_ADDED="" to model an install from before it existed.
  local pkgs_seed=()
  if [[ -n "${SEED_PKGS_ADDED+set}" ]]; then
    read -r -a pkgs_seed <<<"${SEED_PKGS_ADDED}"
  else
    pkgs_seed=(tmux vulkan-tools glslc libvulkan-dev spirv-headers
               libcurl4-openssl-dev mesa-vulkan-drivers nvidia-driver-580
               libnvidia-compute-580 cuda-toolkit-12-0 nvidia-cuda-toolkit gcc-12 g++-12)
  fi
  if (( ${#pkgs_seed[@]} )); then
    printf '%s\n' "${pkgs_seed[@]}" > "${SANDBOX}/var/packages-added"
  fi
}

# run_case <name> [uninstaller args...]; answers, if any, are fed through a pty.
ANSWERS=""
run_case(){
  local name="$1"; shift
  SANDBOX="$(mktemp -d)"
  export STUB_DIR="${SANDBOX}/bin" STUB_LOG="${SANDBOX}/calls.log"
  # So the systemctl stub can answer "no such unit" honestly for a bare machine.
  export STUB_UNIT_DIR="${SANDBOX}/etc"
  bash "${HERE}/harness/stubs.sh" >/dev/null
  seed_installed
  sed -e "s#/etc/systemd/system#${SANDBOX}/etc#g" \
      -e "s#^STAMP_DIR=\"/var/lib/patteros\"#STAMP_DIR=\"${SANDBOX}/var\"#" \
      "${UNINSTALL}" > "${SANDBOX}/uninstall.sh"
  # Prove the redirection took, rather than trusting it. A missed path here
  # would mean this suite deleting the real machine's services.
  if grep -qE '(^|[^a-zA-Z0-9_])/etc/systemd/system|/var/lib/patteros' "${SANDBOX}/uninstall.sh"; then
    echo "REFUSING TO RUN: a real system path survived the sandbox rewrite"; exit 1
  fi

  OUT="${SANDBOX}/stdout.txt"
  local p; p="$(cat "${STUB_DIR}-path")"
  if [[ -n "${ANSWERS}" ]]; then
    printf '%b' "${ANSWERS}" \
      | script -qec "cd '${SANDBOX}' && PATH='${p}' SUDO_USER='${U}' bash '${SANDBOX}/uninstall.sh' $*" /dev/null \
        > "${OUT}" 2>&1
    RC=$?
    tr -d '\r' < "${OUT}" > "${OUT}.c" && mv "${OUT}.c" "${OUT}"
  else
    ( PATH="${p}"; export PATH
      cd "${SANDBOX}" && env SUDO_USER="${U}" bash "${SANDBOX}/uninstall.sh" "$@"
    ) >"${OUT}" 2>&1
    RC=$?
  fi
  CALLS="${SANDBOX}/calls.log"
  printf '\n  %s (exit %d)\n' "${name}" "${RC}"
}

cleanup(){ rm -rf "${SANDBOX:-}" 2>/dev/null || true; }
trap cleanup EXIT

echo "uninstaller: every flag, and what each one must NOT touch"

# ---------------------------------------------------------------------------
# 1. The default safe reset. Enough to re-run the installer, and no more.
# ---------------------------------------------------------------------------
run_case "default safe reset" -y
exits 0
has_re "${CALLS}" '^systemctl disable --now llama.service'    "stops and disables llama.service"
has_re "${CALLS}" '^systemctl disable --now odysseus.service' "stops and disables odysseus.service"
gone "${SANDBOX}/etc/llama.service"    "removes the llama.service unit file"
gone "${SANDBOX}/etc/odysseus.service" "removes the odysseus.service unit file"
gone "${PROBE_HOME}/llama.cpp" "deletes the llama.cpp directory"
gone "${PROBE_HOME}/odysseus"  "deletes the odysseus directory"
kept "${PROBE_HOME}/models"    "KEEPS the models directory, the slow thing to replace"
has "${OUT}" "use --models to delete it" "says how to delete the models if wanted"
gone "${SANDBOX}/var" "removes PatterOS's own records, including the saved password"
hasnt_re "${CALLS}" '^apt-get purge'   "purges no packages by default"
hasnt_re "${CALLS}" '^ufw --force disable' "leaves the firewall enabled by default"
# The summary has to list what really went, in both directions. Only checking
# that it stays quiet when nothing was removed would pass even if it never
# listed anything at all.
has "${OUT}" "Removed:   services" "the summary lists the services"
has_re "${OUT}" "^ *\+ ${PROBE_HOME}/llama.cpp" "and the llama.cpp directory"
has_re "${OUT}" "^ *\+ ${PROBE_HOME}/odysseus"  "and the odysseus directory"
hasnt_re "${OUT}" "^ *\+ ${PROBE_HOME}/models"  "but not the models, which were kept"

# ---------------------------------------------------------------------------
# 2. --dry-run must be a genuine no-op. If this is wrong, the one command a
#    cautious user reaches for first is the one that catches them out.
# ---------------------------------------------------------------------------
run_case "--dry-run" --dry-run
exits 0
has "${OUT}" "DRY RUN" "announces itself up front"
has "${OUT}" "nothing was actually changed" "says so again at the end"
kept "${SANDBOX}/etc/llama.service" "the unit file is untouched"
kept "${PROBE_HOME}/llama.cpp"      "the llama.cpp directory is untouched"
kept "${PROBE_HOME}/odysseus"       "the odysseus directory is untouched"
kept "${SANDBOX}/var"               "PatterOS's records are untouched"
hasnt_re "${CALLS}" '^systemctl disable' "no service was disabled"
hasnt_re "${CALLS}" '^rm '               "nothing was deleted"

# ---------------------------------------------------------------------------
# 3. --models.
# ---------------------------------------------------------------------------
run_case "--models" -y --models
exits 0
gone "${PROBE_HOME}/models" "deletes the models directory when asked"
gone "${PROBE_HOME}/.cache/huggingface" "also clears the download cache"

# ---------------------------------------------------------------------------
# 4. --packages: purge the project's extras, and NOTHING that is shared. The
#    packages listed as kept are ones whose removal would break unrelated work.
# ---------------------------------------------------------------------------
STUB_INSTALLED="tmux vulkan-tools glslc git cmake python3-pip build-essential ufw mesa-vulkan-drivers" \
  run_case "--packages" -y --packages
exits 0
has_re "${CALLS}" '^apt-get purge.*tmux'         "purges tmux"
has_re "${CALLS}" '^apt-get purge.*vulkan-tools' "purges the Vulkan tools"
for keep in git cmake python3-pip build-essential ufw; do
  hasnt_re "${CALLS}" "^apt-get purge.* ${keep}( |$)" "does NOT purge ${keep}"
done
has "${OUT}" "Keeping core tools" "tells the user what it deliberately kept"
has_re "${CALLS}" '^apt-get autoremove' "cleans up orphaned dependencies afterwards"
# mesa-vulkan-drivers IS the graphics driver on AMD and Intel machines, and
# `apt-cache rdepends --installed` puts libvulkan1 and xserver-xorg on top of it.
# The installer does install it, so a record-based purge would take it, which on
# the AMD rig this project is aimed at means removing the display driver.
hasnt_re "${CALLS}" '^apt-get purge.*mesa-vulkan-drivers' "REFUSES to purge the graphics driver"
has "${OUT}" "Kept on purpose: mesa-vulkan-drivers" "names what it refused, rather than going quiet"
has "${OUT}" "the desktop depends on it" "explains why"

# A package the user already had must survive, even though it is on the list of
# things this project uses. Only the installer's own record can tell them apart.
SEED_PKGS_ADDED="vulkan-tools" STUB_INSTALLED="tmux vulkan-tools" \
  run_case "--packages with tmux already on the machine beforehand" -y --packages
exits 0
has_re "${CALLS}"   '^apt-get purge.*vulkan-tools' "purges what PatterOS installed"
hasnt_re "${CALLS}" '^apt-get purge.*tmux'         "leaves the package the user already had"
has "${OUT}" "Kept (already on this machine before PatterOS): tmux" "says which, and why"

# An install from before the record existed. Guessing from a fixed list is how
# somebody loses a package they needed, so the honest answer is to do nothing and
# say so.
SEED_PKGS_ADDED="" STUB_INSTALLED="tmux vulkan-tools glslc" \
  run_case "--packages with no record of what was installed" -y --packages
exits 0
hasnt_re "${CALLS}" '^apt-get purge' "purges nothing at all"
has "${OUT}" "No record of packages installed by PatterOS" "explains the situation"
has "${OUT}" "guessing from a fixed list" "and why it will not guess"

# ---------------------------------------------------------------------------
# 5. --drivers: the heaviest option. It must find the stack, and warn about the
#    reboot, because a half-unloaded driver is a confusing state to be left in.
#
#    It must also stop there. The old sweep was `dpkg-query -W 'nvidia-*'
#    'libnvidia-*' 'cuda-*'`, which on the machine this was tested on matches 79
#    installed packages: four driver series the installer never touched, plus
#    nvidia-prime, nvidia-settings and the Nsight tools, followed by autoremove.
# ---------------------------------------------------------------------------
STUB_INSTALLED="nvidia-driver-580 libnvidia-compute-580 cuda-toolkit-12-0 nvidia-cuda-toolkit gcc-12 g++-12 git nvidia-prime nvidia-settings libnvidia-compute-535 nvidia-visual-profiler" \
  run_case "--drivers" -y --drivers
exits 0
has_re "${CALLS}" '^apt-get purge.*nvidia-driver-580' "purges the NVIDIA driver"
has_re "${CALLS}" '^apt-get purge.*cuda-toolkit-12-0' "purges the CUDA toolkit"
hasnt_re "${CALLS}" '^apt-get purge.* git( |$)' "does not take git with it"
for keep in nvidia-prime nvidia-settings libnvidia-compute-535 nvidia-visual-profiler; do
  hasnt_re "${CALLS}" "^apt-get purge.* ${keep}( |$)" "does NOT purge ${keep}, which it never installed"
done
has "${OUT}" "Reboot before re-installing" "warns that a reboot is needed"
has "${OUT}" "driver/CUDA packages this project installed" "describes accurately what it is removing"

SEED_PKGS_ADDED="" STUB_INSTALLED="nvidia-driver-595 libnvidia-compute-595 cuda-toolkit-12-0" \
  run_case "--drivers with no record of what was installed" -y --drivers
exits 0
hasnt_re "${CALLS}" '^apt-get purge' "removes no driver packages on a guess"
has "${OUT}" "No record of what PatterOS installed" "says why it stopped"
has "${OUT}" "leave a machine with no display" "explains the stake"
has "${OUT}" "ubuntu-drivers install" "offers the supported route instead"
has "${OUT}" "not the desktop" "and warns where to run it from"
hasnt "${OUT}" "Reboot before re-installing" "does not demand a reboot for work it did not do"

# ---------------------------------------------------------------------------
# 6. The firewall. By default only OUR port rules go; ufw itself stays on.
# ---------------------------------------------------------------------------
STUB_UFW_RULES="8020 7000" run_case "firewall, default" -y
has_re "${CALLS}" '^ufw delete allow 8020' "drops the model server rule"
has_re "${CALLS}" '^ufw delete allow 7000' "drops the Odysseus rule"
hasnt_re "${CALLS}" '^ufw --force disable' "leaves ufw itself enabled"
has "${OUT}" "use --firewall to disable it" "says how to turn it off"

run_case "--firewall" -y --firewall
has_re "${CALLS}" '^ufw --force disable' "disables ufw when asked"
has "${OUT}" "SSH stays reachable" "reassures the user about SSH"

# ---------------------------------------------------------------------------
# 7. The ports must come from the INSTALLED unit files, not the defaults.
#    Assuming 8020/7000 would delete rules that were never added and leave the
#    user's real ports open.
# ---------------------------------------------------------------------------
SEED_PORT_LLAMA=9100 SEED_PORT_ODY=9200 STUB_UFW_RULES="9100 9200 8020" \
  run_case "custom ports are read back from the units" -y
has "${OUT}" "LAN ports from the installed units: 9100 and 9200" "plan names the ports read from the units"
has_re "${CALLS}" '^ufw delete allow 9100' "removes the rule for the port actually used"
has_re "${CALLS}" '^ufw delete allow 9200' "same for the Odysseus port"
hasnt_re "${CALLS}" '^ufw delete allow 8020' "leaves port 8020 alone, since this install never used it"

# ---------------------------------------------------------------------------
# 8. LACT.
# ---------------------------------------------------------------------------
STUB_INSTALLED="lact" run_case "--lact" -y --lact
has_re "${CALLS}" '^systemctl disable --now lactd' "stops the lactd daemon"
has_re "${CALLS}" '^apt-get purge.*lact' "purges the package"
gone "${PROBE_HOME}/Downloads/lact.deb" "clears the leftover LACT download"

# The same thing again, but with a package list the size of a real machine's.
# `dpkg -l | grep -q` looks correct and passes against a three-line stub, yet on
# a real host grep -q closes the pipe early, dpkg dies of SIGPIPE, and pipefail
# turns the successful match into a failed test, so the purge is skipped in
# silence. Verified on the 3090 Ti host: exit 141 with grep itself returning 0.
STUB_INSTALLED="lact" STUB_DPKG_BULK=1 run_case "--lact on a machine with thousands of packages" -y --lact
has_re "${CALLS}" '^apt-get purge.*lact' "still finds LACT when dpkg's output is bigger than a pipe buffer"
hasnt "${OUT}" "flatpak" "does not fall through to the flatpak branch"

run_case "LACT left alone by default" -y
has "${OUT}" "Leaving LACT as-is" "does not touch LACT unless asked"
hasnt_re "${CALLS}" '^apt-get purge.*lact' "no purge"

# ---------------------------------------------------------------------------
# 9. Group membership is only ever reversed where PatterOS recorded adding it.
#    Most desktops put users in 'video' already, and removing that would break
#    their display for a reason nobody would connect back to this script.
# ---------------------------------------------------------------------------
run_case "recorded group additions are reversed" -y
has "${OUT}" "group" "mentions the group step"

# ---------------------------------------------------------------------------
# 10. --all.
# ---------------------------------------------------------------------------
STUB_INSTALLED="tmux vulkan-tools lact nvidia-driver-580 nvidia-cuda-toolkit" \
  run_case "--all" -y --all
exits 0
gone "${PROBE_HOME}/models"   "removes the models"
gone "${PROBE_HOME}/llama.cpp" "removes the engine"
has_re "${CALLS}" '^ufw --force disable'      "disables the firewall"
has_re "${CALLS}" '^apt-get purge.*tmux'      "purges the extras"
has_re "${CALLS}" '^apt-get purge.*nvidia-driver-580' "purges the driver"

# ---------------------------------------------------------------------------
# 11. A rig where the install only got halfway, or has already been reset. This
#     is the state after a failed install, so it is a likely first use.
# ---------------------------------------------------------------------------
SEED_MODE=none run_case "nothing installed (failed install, or already reset)" -y
exits 0
has "${OUT}" "Service not installed (skipped)" "reports missing services calmly"
has "${OUT}" "Not present (skipped)"           "reports missing directories calmly"
has "${OUT}" "Reset complete"                  "still finishes cleanly"
hasnt "${OUT}" "Refusing"                      "raises no false alarms"
# The summary is the part people screenshot. It used to print "Removed: services
# + ~/llama.cpp + ~/odysseus" on every run, including this one, where none of
# those existed.
has "${OUT}" "Removed:   nothing" "does not claim to have removed things that were never there"
hasnt "${OUT}" "Removed:   services" "no invented list of deletions"
has "${OUT}" "No PatterOS LAN rules to remove" "does not claim to have dropped firewall rules it never found"

# ---------------------------------------------------------------------------
# The firewall rules for 8020/7000 are NOT ours: the installer only ever opens
# SSH. If one exists, the user typed it themselves following Step 10 or 11, so
# it must be reported as theirs and only when it was really removed.
# ---------------------------------------------------------------------------
STUB_UFW_RULES="8020 7000" run_case "the user had opened the LAN ports by hand" -y
exits 0
has "${OUT}" "Removed the LAN rule(s) for port(s) 8020 7000" "names the ports it actually removed"
has "${OUT}" "you had opened for PatterOS" "credits the rule to the user, not to itself"

# A rule added as `ufw allow 8020` is stored without a protocol, and
# `ufw delete allow 8020/tcp` does not match it, yet still exits 0. Claiming
# success from that exit code is how the real script reported dropping two rules
# that were still in place afterwards.
STUB_UFW_RULES="8020/tcp 7000" run_case "rules stored in both ufw styles" -y
exits 0
has "${OUT}" "Removed the LAN rule(s) for port(s) 8020 7000" "removes both, whichever way they were written"
hasnt "${OUT}" "Could not remove" "no false alarm when both really went"

STUB_UFW_RULES="8020 7000" STUB_UFW_DELETE_FAIL="8020" \
  run_case "a firewall rule that refuses to go" -y
exits 0
has "${OUT}" "Could not remove the firewall rule(s) for port(s) 8020" "admits the rule is still there"
has "${OUT}" "sudo ufw delete allow 8020" "gives the exact command to finish the job"
has "${OUT}" "they open nothing" "explains that the leftover rule is not a security hole"
has "${OUT}" "Removed the LAN rule(s) for port(s) 7000" "still reports the one that did go"

run_case "no LAN rules were ever added" -y
exits 0
has "${OUT}" "No PatterOS LAN rules to remove" "says nothing was there to remove"
hasnt "${OUT}" "Removed the LAN rule" "does not claim a removal that did not happen"

# ---------------------------------------------------------------------------
# The user's own work in Odysseus: notes, uploads, settings and chat history.
#
# All of it lives in one directory inside the clone, so "delete ~/odysseus" took
# the lot. The asymmetry is what gave it away: ~/models is kept by default and
# is hundreds of GB of files anyone can download again, while this is the one
# thing on the machine that exists nowhere else. A default reset is supposed to
# be the safe option, so it now moves that folder aside instead.
# ---------------------------------------------------------------------------
run_case "default reset keeps your Odysseus content" -y
exits 0
gone "${PROBE_HOME}/odysseus" "still removes the clone and its venv"
backup="$(find "${PROBE_HOME}" -maxdepth 1 -name 'odysseus-data-backup-*' -type d 2>/dev/null | head -1)"
if [[ -n "${backup}" && -f "${backup}/personal_docs/notes.md" ]]; then
  ok "moves your notes, uploads and history out to ${backup##*/}"
else
  bad "moves your notes, uploads and history out" "no backup directory with the seeded notes"
fi
has "${OUT}" "Kept your Odysseus content" "tells the user it was kept"
has "${OUT}" "notes, uploads, settings and chat history" "says what that folder is, in plain words"
has "${OUT}" "--odysseus-data next time" "explains how to delete it if they want to"
has_re "${OUT}" "^ *Kept: *your Odysseus notes" "and the closing summary points at it"

run_case "--odysseus-data deletes it when explicitly asked" -y --odysseus-data
exits 0
gone "${PROBE_HOME}/odysseus" "removes the directory"
if [[ -z "$(find "${PROBE_HOME}" -maxdepth 1 -name 'odysseus-data-backup-*' 2>/dev/null)" ]]; then
  ok "keeps no copy, which is what was asked for"
else
  bad "keeps no copy, which is what was asked for" "a backup directory was left behind"
fi
has "${OUT}" "Deleting your Odysseus content too" "is explicit about what it is destroying"

SEED_ODY_DATA=no run_case "an Odysseus install with no content yet" -y
exits 0
gone "${PROBE_HOME}/odysseus" "removes the directory"
hasnt "${OUT}" "Kept your Odysseus content" "says nothing about content that does not exist"

run_case "--dry-run says what it would do with your content" --dry-run
exits 0
has "${OUT}" "Your work:" "the plan mentions it before anything happens"
kept "${PROBE_HOME}/odysseus/data/personal_docs/notes.md" "and changes nothing"

# ---------------------------------------------------------------------------
# 12. THE GUARD RAIL. safe_rm must refuse anything that is not under the home.
#     Forcing the home to '/' is the cheapest way to prove the check fires, and
#     the consequence of it not firing would be catastrophic.
# ---------------------------------------------------------------------------
STUB_HOME="/" run_case "refuses to run at all when the home is '/'" -y
if [[ "${RC}" -ne 0 ]]; then ok "refuses (non-zero exit)"; else bad "refuses (non-zero exit)" "got 0"; fi
has "${OUT}" "not a usable home" "explains why it will not proceed"
kept "/bin" "the real filesystem is untouched"
kept "/etc" "and so is /etc"
hasnt_re "${CALLS}" '^rm ' "no rm was issued at all"

# ---------------------------------------------------------------------------
# 13. Declining the confirmation must change nothing.
# ---------------------------------------------------------------------------
ANSWERS='n\n'
run_case "confirmation declined"
ANSWERS=""
if [[ "${RC}" -ne 0 ]]; then ok "refuses (non-zero exit)"; else bad "refuses (non-zero exit)" "got 0"; fi
has "${OUT}" "Cancelled. Nothing changed." "confirms nothing was done"
kept "${PROBE_HOME}/llama.cpp"      "the llama.cpp directory is untouched"
kept "${SANDBOX}/etc/llama.service" "the unit file is untouched"
hasnt_re "${CALLS}" '^systemctl disable' "no service was disabled"

# ---------------------------------------------------------------------------
# 14. Accepting it proceeds.
# ---------------------------------------------------------------------------
ANSWERS='y\n'
run_case "confirmation accepted"
ANSWERS=""
exits 0
gone "${PROBE_HOME}/llama.cpp" "proceeds when confirmed"

# ---------------------------------------------------------------------------
# 15. A typo must stop, not guess.
# ---------------------------------------------------------------------------
run_case "unknown flag" --definitely-not-a-flag
if [[ "${RC}" -ne 0 ]]; then ok "refuses (non-zero exit)"; else bad "refuses (non-zero exit)" "got 0"; fi
has "${OUT}" "Unknown option" "names the offending option"
kept "${PROBE_HOME}/llama.cpp" "nothing was deleted"

# ---------------------------------------------------------------------------
# 16. Every flag the parser accepts must be documented in --help.
# ---------------------------------------------------------------------------
printf '\n  --help documents every flag\n'
HELP="$(bash "${UNINSTALL}" --help 2>&1)"; RC=$?
exits 0
PARSED="$(sed -n '/^while \[\[ \$# -gt 0/,/^done/p' "${UNINSTALL}" \
          | grep -oE '^\s+(--[a-z-]+)' | tr -d ' ' | sort -u)"
missing=""
for f in ${PARSED}; do grep -q -- "${f}" <<<"${HELP}" || missing="${missing} ${f}"; done
if [[ -z "${missing}" ]]; then ok "every parsed flag appears in --help"
else bad "every parsed flag appears in --help" "undocumented:${missing}"; fi

echo
printf '%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
