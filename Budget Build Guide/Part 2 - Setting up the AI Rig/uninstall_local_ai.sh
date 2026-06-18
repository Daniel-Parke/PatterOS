#!/usr/bin/env bash
# =============================================================================
#  PatterOS · Local AI Budget Build — Part 2 uninstaller / reset
#  uninstall_local_ai.sh  (v1.2)
#
#  The exact inverse of setup_local_ai.sh. Use it to wipe a rig back to a
#  clean state between test runs, so a fresh `setup_local_ai.sh` starts clean.
#
#  WHAT IT REMOVES BY DEFAULT (safe reset — enough to re-run the installer):
#     - the llama.service and odysseus.service systemd units (stopped first)
#     - ~/llama.cpp        (the clone and the compiled build/)
#     - ~/odysseus         (the clone, its venv, and its local data)
#
#  WHAT IT KEEPS BY DEFAULT (so a re-test is fast and nothing else breaks):
#     - ~/models           (re-downloading big GGUFs is slow — keep unless --models)
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
#                   curl, cmake, build-essential, python3 — they're shared.
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
# =============================================================================
set -uo pipefail   # NOTE: no -e — an uninstaller must keep going if a step is a no-op

# ----- pretty output --------------------------------------------------------
if [[ -t 1 ]]; then
  C=$'\033[38;5;38m'; OK=$'\033[38;5;42m'; WN=$'\033[38;5;208m'; ER=$'\033[38;5;196m'; B=$'\033[1m'; N=$'\033[0m'
else C=''; OK=''; WN=''; ER=''; B=''; N=''; fi
step(){ echo -e "\n${C}${B}==>${N} ${B}$*${N}"; }
info(){ echo -e "    $*"; }
good(){ echo -e "${OK}[OK]${N} $*"; }
warn(){ echo -e "${WN}[!]${N} $*" >&2; }
die(){  echo -e "${ER}[FAIL]${N} $*" >&2; exit 1; }

# ----- config (kept in sync with setup_local_ai.sh) -------------------------
SERVICES=(llama.service odysseus.service)
PORT_LLAMA=8020
PORT_ODY=7000
# Build/Vulkan extras the installer added FOR THIS PROJECT (safe to purge).
# Core tools (git curl wget cmake build-essential python3-* pciutils ufw) are
# deliberately NOT here — they are commonly shared and risky to remove.
PURGE_EXTRAS=(tmux libvulkan-dev glslc spirv-headers vulkan-tools mesa-vulkan-drivers libcurl4-openssl-dev)

# ----- args -----------------------------------------------------------------
DO_MODELS="no"; DO_PKGS="no"; DO_DRIVERS="no"; DO_FW="no"; DO_LACT="no"; DRY="no"; YES="no"
show_help(){ sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; }
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
as_user(){ sudo -u "${REAL_USER}" -H "$@"; }

MODELS_DIR="${USER_HOME}/models"
LLAMA_DIR="${USER_HOME}/llama.cpp"
ODY_DIR="${USER_HOME}/odysseus"

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
echo "     PatterOS  —  Local AI Budget Build"
echo "     Part 2 uninstaller / reset  ·  v1.2"
echo "  ============================================================"
echo -e "     Your hardware. Your data. Your control.${N}"
echo
info "As with any script — ours included — have a look inside before you run it:"
echo -e "      ${C}less $(basename "$0")${N}        (arrow keys to scroll, q to quit)"
echo
info "User: ${REAL_USER}   Home: ${USER_HOME}"
[[ "${DRY}" == "yes" ]] && warn "DRY RUN — nothing will actually be changed."

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
step "7  Packages"
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

# ======================================================================== 8 ==
step "8  GPU drivers / CUDA"
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

# ======================================================================== 9 ==
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
echo "  You can now re-run a clean install:  sudo bash setup_local_ai.sh"
if [[ "${NEED_REBOOT}" == "yes" ]]; then
  echo -e "${WN}  Reboot before re-installing so the old driver fully unloads:  sudo reboot${N}"
fi
[[ "${DRY}" == "yes" ]] && warn "That was a DRY RUN — nothing was actually changed."
