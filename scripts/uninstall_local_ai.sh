#!/usr/bin/env bash
# =============================================================================
#  PatterOS · Local AI Budget Build, Part 2 uninstaller / reset
#  uninstall_local_ai.sh  (v1.4)
#
#  The exact inverse of install_local_ai.sh. Use it to wipe a rig back to a
#  clean state between test runs, so a fresh `install_local_ai.sh` starts clean.
#
#  WHAT IT REMOVES BY DEFAULT (safe reset, enough to re-run the installer):
#     - the llama.service and odysseus.service systemd units (stopped first)
#     - ~/llama.cpp        (the clone and the compiled build/)
#     - ~/odysseus         (the clone, its venv, and its local data)
#
#  WHAT IT KEEPS BY DEFAULT (so a re-test is fast and nothing else breaks):
#     - ~/models           (re-downloading big GGUFs is slow, keep unless --models)
#     - apt packages, GPU drivers/CUDA, the firewall  (shared with the rest of
#       the system; only removed when you ask for it with the flags below)
#
#  USAGE
#     less uninstall_local_ai.sh                 # read it first
#     sudo bash uninstall_local_ai.sh            # safe reset (services + repos/builds)
#     sudo bash uninstall_local_ai.sh --all -y   # full wipe, no prompts
#     sudo bash uninstall_local_ai.sh --dry-run  # show what WOULD happen, change nothing
#
#  FLAGS  (each one opts in to removing more)
#     --models      Also delete ~/models (every downloaded GGUF).
#     --packages    Also purge the build/Vulkan extras this project installed
#                   (tmux, Vulkan dev libs/tools). Keeps core tools like git,
#                   curl, cmake, build-essential, python3, they're shared.
#     --drivers     Also purge the NVIDIA driver + CUDA toolkit + gcc-12/g++-12.
#                   Heavy; needs a reboot afterwards.
#     --firewall    Also disable ufw (returns it to the OS default; SSH stays
#                   reachable because filtering is simply turned off).
#     --lact        Also remove LACT and disable its lactd daemon.
#     --all         Everything above (--models --packages --drivers --firewall --lact).
#     --dry-run     Print every action without doing any of it.
#     -y, --yes     Don't prompt for confirmation.
#     -h, --help    Show this help.
#
#  Safe to run repeatedly and safe to run on a rig where setup only got halfway.
# --- end of help ------------------------------------------------------------
# =============================================================================
set -uo pipefail   # NOTE: no -e, an uninstaller must keep going if a step is a no-op

# ----- pretty output --------------------------------------------------------
if [[ -t 1 ]]; then
  C=$'\033[38;5;38m'; OK=$'\033[38;5;42m'; WN=$'\033[38;5;208m'; ER=$'\033[38;5;196m'; B=$'\033[1m'; N=$'\033[0m'
else C=''; OK=''; WN=''; ER=''; B=''; N=''; fi
step(){ echo -e "\n${C}${B}==>${N} ${B}$*${N}"; }
info(){ echo -e "    $*"; }
good(){ echo -e "${OK}[OK]${N} $*"; }
warn(){ echo -e "${WN}[!]${N} $*" >&2; }
die(){  echo -e "${ER}[FAIL]${N} $*" >&2; exit 1; }

# ----- config (kept in sync with install_local_ai.sh) -----------------------
SERVICES=(llama.service odysseus.service)
STAMP_DIR="/var/lib/patteros"     # unit checksums + the first-login file
# Default ports. These are only a fallback: the installer lets the user pick
# different ones, and if we assumed 8020/7000 here we would delete firewall
# rules that were never added and leave the user's real ports open. So we read
# the ports back out of the installed unit files first, below.
PORT_LLAMA=8020
PORT_ODY=7000
# Build/Vulkan extras the installer added FOR THIS PROJECT (safe to purge).
# Core tools (git curl wget cmake build-essential python3-* pciutils ufw) are
# deliberately NOT here, they are commonly shared and risky to remove.
PURGE_EXTRAS=(tmux libvulkan-dev glslc spirv-headers vulkan-tools mesa-vulkan-drivers libcurl4-openssl-dev)

# ----- args -----------------------------------------------------------------
DO_MODELS="no"; DO_PKGS="no"; DO_DRIVERS="no"; DO_FW="no"; DO_LACT="no"; DRY="no"; YES="no"
# Reads to a sentinel, not a hard-coded line number. See the matching note in
# install_local_ai.sh: counting lines meant any header edit silently truncated
# the help or leaked code into it.
show_help(){ sed -n '2,/^# --- end of help/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --models)   DO_MODELS="yes";;
    --packages) DO_PKGS="yes";;
    --drivers)  DO_DRIVERS="yes";;
    --firewall) DO_FW="yes";;
    --lact)     DO_LACT="yes";;
    --all)      DO_MODELS="yes"; DO_PKGS="yes"; DO_DRIVERS="yes"; DO_FW="yes"; DO_LACT="yes";;
    --dry-run)  DRY="yes";;
    -y|--yes)   YES="yes";;
    -h|--help)  show_help; exit 0;;
    *) die "Unknown option: $1   (try -h)";;
  esac
  shift
done

# ----- run wrapper (honours --dry-run) --------------------------------------
RUN(){ if [[ "${DRY}" == "yes" ]]; then echo "    ${C}[dry-run]${N} $*"; else "$@"; fi; }
ok_did(){ if [[ "${DRY}" == "yes" ]]; then info "would: $*"; else good "$*"; fi; }

# ----- pre-flight -----------------------------------------------------------
[[ ${EUID} -eq 0 ]] || die "Run with sudo:  sudo bash $(basename "$0")"
REAL_USER="${SUDO_USER:-}"
[[ -n "${REAL_USER}" && "${REAL_USER}" != "root" ]] || die "Run via sudo as your normal user:  sudo bash $(basename "$0")"
USER_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
[[ -d "${USER_HOME}" ]] || die "Could not find the home directory for ${REAL_USER}."
# Invoked indirectly, as an argument to RUN (see safe_rm and the LACT step).
# The call sites are therefore invisible to static analysis, which reports this
# as an unused function; SC2329 is disabled here for that reason.
# shellcheck disable=SC2329
as_user(){ sudo -u "${REAL_USER}" -H "$@"; }

MODELS_DIR="${USER_HOME}/models"
LLAMA_DIR="${USER_HOME}/llama.cpp"
ODY_DIR="${USER_HOME}/odysseus"

# Recover the ports the installer actually used, rather than assuming the
# defaults. The installer's Customise menu lets people change both, and a user
# who chose port 9000 would otherwise keep an open 9000 rule forever while we
# cheerfully deleted a rule for 8020 that never existed.
read_port(){ # $1 unit file, $2 fallback
  local p=""
  [[ -r "$1" ]] && p="$(grep -oE -- '--port[= ]+[0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
  [[ "${p}" =~ ^[0-9]+$ ]] && echo "${p}" || echo "$2"
}
PORT_LLAMA="$(read_port /etc/systemd/system/llama.service    "${PORT_LLAMA}")"
PORT_ODY="$(  read_port /etc/systemd/system/odysseus.service "${PORT_ODY}")"

# refuse to rm anything that isn't safely under the user's home
safe_rm(){
  local p="$1"
  if [[ -z "${p}" || "${p}" == "/" || "${p}" == "${USER_HOME}" || "${p}" != "${USER_HOME}"/* ]]; then
    warn "Refusing to remove unsafe path: '${p}'"; return 0
  fi
  if [[ -e "${p}" ]]; then RUN as_user rm -rf -- "${p}"; ok_did "Removed ${p}"
  else info "Not present (skipped): ${p}"; fi
}

echo -e "${C}${B}"
echo "  ============================================================"
echo "     PatterOS  ·  Local AI Budget Build"
echo "     Part 2 uninstaller / reset  ·  v1.4"
echo "  ============================================================"
echo -e "     Your hardware. Your data. Your control.${N}"
echo
info "As with any script, ours included, have a look inside before you run it:"
echo -e "      ${C}less $(basename "$0")${N}        (arrow keys to scroll, q to quit)"
echo
info "User: ${REAL_USER}   Home: ${USER_HOME}"
[[ "${DRY}" == "yes" ]] && warn "DRY RUN, nothing will actually be changed."

# ----- plan + confirm -------------------------------------------------------
echo
echo -e "${B}Plan${N}"
echo "  Always:    stop+remove services (${SERVICES[*]}); delete ${LLAMA_DIR} and ${ODY_DIR}"
echo "  Models:    $([[ ${DO_MODELS}  == yes ]] && echo "DELETE ${MODELS_DIR}" || echo "keep ${MODELS_DIR}")"
echo "  Packages:  $([[ ${DO_PKGS}    == yes ]] && echo "purge build/Vulkan extras" || echo "keep")"
echo "  Drivers:   $([[ ${DO_DRIVERS} == yes ]] && echo "purge NVIDIA + CUDA + gcc-12/g++-12 (reboot after)" || echo "keep")"
echo "  Firewall:  $([[ ${DO_FW}      == yes ]] && echo "disable ufw" || echo "leave as-is")"
echo "  LACT:      $([[ ${DO_LACT}    == yes ]] && echo "remove + disable lactd" || echo "leave as-is")"
echo
if [[ "${YES}" != "yes" && "${DRY}" != "yes" ]]; then
  read -r -p "Proceed with the above? [y/N]: " a </dev/tty || true
  [[ "${a,,}" == "y" || "${a,,}" == "yes" ]] || die "Cancelled. Nothing changed."
fi

# ======================================================================== 1 ==
step "1  Stopping and removing services"
SVC_TOUCHED="no"
for svc in "${SERVICES[@]}"; do
  unit="/etc/systemd/system/${svc}"
  if systemctl list-unit-files "${svc}" >/dev/null 2>&1 && systemctl status "${svc}" >/dev/null 2>&1 || [[ -f "${unit}" ]]; then
    RUN systemctl disable --now "${svc}" >/dev/null 2>&1 || warn "Could not disable ${svc} (maybe already stopped)."
    [[ -f "${unit}" ]] && { RUN rm -f "${unit}"; ok_did "Removed ${unit}"; }
    SVC_TOUCHED="yes"
  else
    info "Service not installed (skipped): ${svc}"
  fi
done
if [[ "${SVC_TOUCHED}" == "yes" ]]; then
  RUN systemctl daemon-reload
  for svc in "${SERVICES[@]}"; do RUN systemctl reset-failed "${svc}" >/dev/null 2>&1 || true; done
fi
# The installer keeps a copy of any unit it declined to overwrite. Those are
# the user's own edits, so mention them rather than deleting them silently.
for svc in "${SERVICES[@]}"; do
  bak="/etc/systemd/system/${svc}.patteros-backup"
  if [[ -f "${bak}" ]]; then
    RUN rm -f "${bak}"; ok_did "Removed the saved copy of your edited ${svc}"
  fi
done

# NOTE: PatterOS's own state under ${STAMP_DIR} is removed at the END, in step
# 9, because the group-membership step still needs to read it.

# ======================================================================== 2 ==
step "2  Removing llama.cpp (clone + build)"
safe_rm "${LLAMA_DIR}"

# ======================================================================== 3 ==
step "3  Removing Odysseus (clone + venv + local data)"
safe_rm "${ODY_DIR}"

# ======================================================================== 4 ==
step "4  Models"
if [[ "${DO_MODELS}" == "yes" ]]; then
  warn "Deleting all downloaded models in ${MODELS_DIR}."
  safe_rm "${MODELS_DIR}"
  safe_rm "${USER_HOME}/.cache/huggingface"
else
  info "Keeping ${MODELS_DIR} (use --models to delete it)."
fi

# ======================================================================== 5 ==
step "5  Firewall"
# Always drop the project-specific LAN rules we may have added (ports are ours).
if command -v ufw >/dev/null 2>&1; then
  RUN ufw delete allow "${PORT_ODY}/tcp"   >/dev/null 2>&1 || true
  RUN ufw delete allow "${PORT_LLAMA}/tcp" >/dev/null 2>&1 || true
fi
if [[ "${DO_FW}" == "yes" ]]; then
  RUN ufw --force disable >/dev/null 2>&1 || warn "Could not disable ufw."
  ok_did "ufw disabled (back to OS default; SSH stays reachable)."
else
  info "Dropped our ${PORT_LLAMA}/${PORT_ODY} rules; left ufw itself as-is (use --firewall to disable it)."
fi

# ======================================================================== 6 ==
step "6  LACT"
if [[ "${DO_LACT}" == "yes" ]]; then
  RUN systemctl disable --now lactd >/dev/null 2>&1 || true
  if dpkg -l 2>/dev/null | grep -q '^ii  lact '; then RUN apt-get purge -y -qq lact || warn "apt purge lact failed."
  elif command -v flatpak >/dev/null 2>&1; then RUN flatpak uninstall -y io.github.ilya_zlobintsev.LACT >/dev/null 2>&1 || true; fi
  [[ -f "${USER_HOME}/Downloads/lact.deb" ]] && { RUN as_user rm -f "${USER_HOME}/Downloads/lact.deb"; ok_did "Removed leftover ~/Downloads/lact.deb"; }
  ok_did "LACT removed (if it was installed)."
else
  info "Leaving LACT as-is (use --lact to remove it)."
fi

# ======================================================================== 7 ==
step "7  GPU group membership"
# On AMD/Intel rigs the installer may add the user to 'render' and 'video' so
# the background service can reach the GPU. Reverse ONLY what we recorded
# adding: plenty of desktops put users in 'video' by default, and removing that
# would break their graphics for reasons they would never connect to us.
GROUPS_FILE="${STAMP_DIR}/groups-added"
if [[ -r "${GROUPS_FILE}" ]]; then
  while read -r guser ggroup; do
    [[ -n "${guser}" && -n "${ggroup}" ]] || continue
    if id -nG "${guser}" 2>/dev/null | grep -qw "${ggroup}"; then
      RUN gpasswd -d "${guser}" "${ggroup}" >/dev/null 2>&1 || warn "Could not remove ${guser} from '${ggroup}'."
      ok_did "Removed ${guser} from the '${ggroup}' group (PatterOS added it)"
    fi
  done < "${GROUPS_FILE}"
  info "Log out and back in for the group change to take effect."
else
  info "No group changes were recorded, so nothing to undo here."
fi

# ======================================================================== 8 ==
step "8  Packages"
NEED_AUTOREMOVE="no"
if [[ "${DO_PKGS}" == "yes" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  present=()
  for p in "${PURGE_EXTRAS[@]}"; do dpkg -l "${p}" 2>/dev/null | grep -q "^ii  ${p} " && present+=("${p}"); done
  if (( ${#present[@]} > 0 )); then
    info "Purging: ${present[*]}"
    RUN apt-get purge -y -qq "${present[@]}" || warn "Some packages refused to purge; continuing."
    NEED_AUTOREMOVE="yes"
  else info "None of the project's build/Vulkan extras are installed."; fi
  info "Keeping core tools (git, curl, cmake, build-essential, python3, ufw, pciutils)."
else
  info "Leaving apt packages as-is (use --packages to purge build/Vulkan extras)."
fi

# ======================================================================== 9 ==
step "9  GPU drivers / CUDA"
NEED_REBOOT="no"
if [[ "${DO_DRIVERS}" == "yes" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  # gather installed NVIDIA/CUDA packages + the toolchain we added, de-duplicated,
  # skipping blank lines so an empty match never yields a phantom entry
  declare -A seen=(); present=()
  while IFS= read -r p; do
    [[ -n "${p}" ]] || continue
    [[ -n "${seen[${p}]:-}" ]] && continue
    dpkg -l "${p}" 2>/dev/null | grep -q "^ii  ${p} " && { present+=("${p}"); seen[${p}]=1; }
  done < <(
    dpkg-query -W -f='${Package}\n' 'nvidia-*' 'libnvidia-*' 'cuda-*' 2>/dev/null
    printf '%s\n' nvidia-cuda-toolkit ubuntu-drivers-common gcc-12 g++-12
  )
  if (( ${#present[@]} > 0 )); then
    warn "Purging the NVIDIA/CUDA stack: ${present[*]}"
    RUN apt-get purge -y -qq "${present[@]}" || warn "Some driver packages refused to purge; continuing."
    NEED_AUTOREMOVE="yes"; NEED_REBOOT="yes"
  else info "No NVIDIA/CUDA packages found to remove."; fi
else
  info "Leaving GPU drivers/CUDA as-is (use --drivers to purge them)."
fi

[[ "${NEED_AUTOREMOVE}" == "yes" ]] && { step "Cleaning up orphaned dependencies"; RUN apt-get autoremove -y -qq || true; }

# ======================================================================= 10 ==
step "10  PatterOS's own records"
# Done last, because the group step above reads the file this removes.
# Leaving it behind would make a future install think it still owned service
# files it no longer wrote, and would leave the saved first-login password on
# disk after everything it unlocked has gone.
if [[ -d "${STAMP_DIR}" ]]; then
  RUN rm -rf -- "${STAMP_DIR}"
  ok_did "Removed ${STAMP_DIR} (service checksums, group record, saved first-login details)"
else
  info "Not present (skipped): ${STAMP_DIR}"
fi

# ======================================================================= 11 ==
echo -e "${OK}${B}"
echo "=============================================================="
echo "   Reset complete."
echo -e "==============================================================${N}"
echo "  Removed:   services + ${LLAMA_DIR} + ${ODY_DIR}"
[[ "${DO_MODELS}" == "yes" ]] && echo "             + ${MODELS_DIR}"
[[ "${DO_PKGS}"   == "yes" ]] && echo "             + build/Vulkan extras"
[[ "${DO_DRIVERS}" == "yes" ]] && echo "             + NVIDIA/CUDA stack"
echo
echo "  Left alone: huggingface_hub (per-user pip), any models you kept, core tools."
echo "  You can now re-run a clean install:  sudo bash install_local_ai.sh"
if [[ "${NEED_REBOOT}" == "yes" ]]; then
  echo -e "${WN}  Reboot before re-installing so the old driver fully unloads:  sudo reboot${N}"
fi
if [[ "${DRY}" == "yes" ]]; then
  warn "That was a DRY RUN, so nothing was actually changed."
fi

# Exit 0 explicitly. The last statement used to be a bare
# `[[ "${DRY}" == "yes" ]] && warn ...`, which evaluates to FALSE on a real
# run, so a successful uninstall returned 1 and only a dry run returned 0,
# exactly backwards. Anything checking the exit code (CI, a wrapper script, or
# `&&` on the command line) was told every successful reset had failed.
exit 0
