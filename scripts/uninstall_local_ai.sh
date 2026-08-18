#!/usr/bin/env bash
# =============================================================================
#  PatterOS · Local AI Budget Build, Part 2 uninstaller / reset
#  uninstall_local_ai.sh  (v1.5)
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
#                   (tmux, Vulkan dev libs/tools). Only ones PatterOS actually
#                   installed, never one you already had. Keeps core tools like
#                   git, curl, cmake, build-essential, python3, they're shared,
#                   and always keeps mesa-vulkan-drivers, which is the graphics
#                   driver on AMD and Intel machines.
#     --drivers     Also purge the GPU driver and CUDA packages PatterOS
#                   installed, and only those: it will not remove a driver that
#                   was here before it. Heavy; needs a reboot afterwards.
#     --firewall    Also disable ufw (returns it to the OS default; SSH stays
#                   reachable because filtering is simply turned off).
#     --lact        Also remove LACT and disable its lactd daemon.
#     --odysseus-data
#                   Also delete your Odysseus content: notes, uploads, settings
#                   and chat history. Without this it is moved to
#                   ~/odysseus-data-backup-<date> and kept.
#     --all         Everything above (--models --packages --drivers --firewall
#                   --lact --odysseus-data).
#     --dry-run     Print every action without doing any of it.
#     -y, --yes     Don't prompt for confirmation.
#     -h, --help    Show this help.
#
#  Safe to run repeatedly and safe to run on a rig where setup only got halfway.
# --- end of help ------------------------------------------------------------
#
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Daniel Parke. See LICENSE and NOTICE.
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
# Build/Vulkan extras the installer may have added FOR THIS PROJECT. A package
# only gets purged if it is BOTH on this list and in the installer's record of
# what it actually installed, because plenty of these ship with a desktop.
# Core tools (git curl wget cmake build-essential python3-* pciutils ufw) are
# deliberately NOT here, they are commonly shared and risky to remove.
PURGE_EXTRAS=(tmux libvulkan-dev glslc spirv-headers vulkan-tools mesa-vulkan-drivers libcurl4-openssl-dev)
# Never purge these, whatever any record says. mesa-vulkan-drivers IS the
# graphics driver on AMD and Intel, and `apt-cache rdepends --installed` shows
# libvulkan1 and xserver-xorg on it, so purging it can cost the user their
# desktop. It stays in PURGE_EXTRAS for the report, and is refused here.
PURGE_NEVER=(mesa-vulkan-drivers libvulkan1 xserver-xorg)
PKGS_ADDED_FILE="${STAMP_DIR}/packages-added"

# ----- args -----------------------------------------------------------------
DO_MODELS="no"; DO_PKGS="no"; DO_DRIVERS="no"; DO_FW="no"; DO_LACT="no"; DRY="no"; YES="no"
DO_ODY_DATA="no"
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
    --odysseus-data) DO_ODY_DATA="yes";;
    --all)      DO_MODELS="yes"; DO_PKGS="yes"; DO_DRIVERS="yes"; DO_FW="yes"; DO_LACT="yes"
                DO_ODY_DATA="yes";;
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
# safe_rm below refuses any path that is not under USER_HOME. That check is only
# as good as USER_HOME itself: with a home of "/", "//llama.cpp" counts as being
# inside it and the guard waves through deletions at the top of the filesystem.
# A misconfigured account like that is rare, but the whole point of the guard is
# to hold when something unexpected has happened, so stop rather than trust it.
[[ "${USER_HOME}" != "/" ]] || die "The home directory for ${REAL_USER} is '/', which is not a usable home. Refusing to delete anything."
# Invoked indirectly, as an argument to RUN (see safe_rm and the LACT step).
# The call sites are therefore invisible to static analysis, which reports this
# as an unused or unreachable function. Two codes because different shellcheck
# versions report it differently: 0.9 says SC2317, 0.11 says SC2329.
# shellcheck disable=SC2317,SC2329
as_user(){ sudo -u "${REAL_USER}" -H "$@"; }

MODELS_DIR="${USER_HOME}/models"
LLAMA_DIR="${USER_HOME}/llama.cpp"
ODY_DIR="${USER_HOME}/odysseus"

# Recover the ports the installer actually used, rather than assuming the
# defaults. The installer's Customise menu lets people change both, and a user
# who chose port 9000 would otherwise keep an open 9000 rule forever while we
# cheerfully deleted a rule for 8020 that never existed.
# Is a package installed?
#
# Not `dpkg -l | grep -q`. Under `set -o pipefail`, grep -q exits at its first
# match and closes the pipe; on a real machine `dpkg -l` has a few hundred KB of
# output, so it is still writing, dies of SIGPIPE, and the pipeline reports 141
# even though grep matched. `--lact` on this very host failed that way: LACT was
# installed, grep found it, and the purge was skipped without a word. Querying
# one package keeps the output small, and reading it into a variable removes the
# pipe from the equation entirely.
pkg_installed(){
  local out
  out="$(dpkg -l "$1" 2>/dev/null || true)"
  grep -qE "^ii[[:space:]]+$1[[:space:]]" <<<"${out}"
}

# Did the installer record putting this package on the machine?
pkg_was_added(){
  [[ -r "${PKGS_ADDED_FILE}" ]] || return 1
  grep -qxF -- "$1" "${PKGS_ADDED_FILE}"
}
pkg_protected(){
  local p
  for p in "${PURGE_NEVER[@]}"; do [[ "$1" == "${p}" ]] && return 0; done
  return 1
}

read_port(){ # $1 unit file, $2 fallback
  local p=""
  [[ -r "$1" ]] && p="$(grep -oE -- '--port[= ]+[0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
  [[ "${p}" =~ ^[0-9]+$ ]] && echo "${p}" || echo "$2"
}
PORT_LLAMA="$(read_port /etc/systemd/system/llama.service    "${PORT_LLAMA}")"
PORT_ODY="$(  read_port /etc/systemd/system/odysseus.service "${PORT_ODY}")"

# refuse to rm anything that isn't safely under the user's home
# Sets SAFE_RM_DID so the closing summary can list what was really removed
# rather than what was merely attempted.
SAFE_RM_DID="no"
safe_rm(){
  local p="$1"
  SAFE_RM_DID="no"
  if [[ -z "${p}" || "${p}" == "/" || "${p}" == "${USER_HOME}" || "${p}" != "${USER_HOME}"/* ]]; then
    warn "Refusing to remove unsafe path: '${p}'"; return 0
  fi
  if [[ -e "${p}" ]]; then RUN as_user rm -rf -- "${p}"; ok_did "Removed ${p}"; SAFE_RM_DID="yes"
  else info "Not present (skipped): ${p}"; fi
}

echo -e "${C}${B}"
echo "  ============================================================"
echo "     PatterOS  ·  Local AI Budget Build"
echo "     Part 2 uninstaller / reset  ·  v1.5"
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
if [[ -d "${ODY_DIR}/data" ]]; then
echo "  Your work: $([[ ${DO_ODY_DATA} == yes ]] && echo "DELETE your Odysseus notes, uploads and chat history" || echo "keep (moved to ${USER_HOME}/odysseus-data-backup-<date>)")"
fi
echo "  Packages:  $([[ ${DO_PKGS}    == yes ]] && echo "purge the build/Vulkan extras PatterOS installed" || echo "keep")"
echo "  Drivers:   $([[ ${DO_DRIVERS} == yes ]] && echo "purge the GPU driver/CUDA packages PatterOS installed (reboot after)" || echo "keep")"
echo "  Firewall:  $([[ ${DO_FW}      == yes ]] && echo "disable ufw" || echo "leave as-is")"
echo "             LAN ports from the installed units: ${PORT_LLAMA} and ${PORT_ODY}"
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
safe_rm "${LLAMA_DIR}"; LLAMA_GONE="${SAFE_RM_DID}"

# ======================================================================== 3 ==
step "3  Removing Odysseus (clone + venv)"
# Keep the user's own content by default, which is the point of a "safe reset".
#
# Everything Odysseus persists lives in one directory: src/constants.py derives
# DATA_DIR and every notes, uploads, chat-history and settings path from it. That
# directory sits inside the clone, so deleting the clone deleted the lot. The
# asymmetry gave it away, ~/models is 174 GB of re-downloadable files and is kept
# by default, while a folder of things that exist nowhere else was not. It is
# moved out of the way instead, and only deleted if asked for by name.
ODY_DATA="${ODY_DIR}/data"
ODY_DATA_SAVED=""
ODY_GONE="no"
if [[ "${DO_ODY_DATA}" == "yes" ]]; then
  [[ -d "${ODY_DATA}" ]] && warn "Deleting your Odysseus content too (--odysseus-data): notes, uploads, chat history."
  safe_rm "${ODY_DIR}"; ODY_GONE="${SAFE_RM_DID}"
elif [[ -d "${ODY_DATA}" ]]; then
  ODY_DATA_SAVED="${USER_HOME}/odysseus-data-backup-$(date +%Y%m%d-%H%M%S)"
  if RUN as_user mv "${ODY_DATA}" "${ODY_DATA_SAVED}"; then
    ok_did "Kept your Odysseus content: moved to ${ODY_DATA_SAVED}"
    info "That is your notes, uploads, settings and chat history. Delete it when you are"
    info "sure, or pass --odysseus-data next time to have it go with the rest."
    safe_rm "${ODY_DIR}"; ODY_GONE="${SAFE_RM_DID}"
  else
    warn "Could not move your content out of ${ODY_DATA}, so ${ODY_DIR} is being left alone."
    info "Nothing is lost. Move that folder somewhere safe, then re-run this script."
    ODY_DATA_SAVED=""
  fi
else
  safe_rm "${ODY_DIR}"; ODY_GONE="${SAFE_RM_DID}"
fi

# ======================================================================== 4 ==
step "4  Models"
MODELS_GONE="no"
if [[ "${DO_MODELS}" == "yes" ]]; then
  warn "Deleting all downloaded models in ${MODELS_DIR}."
  safe_rm "${MODELS_DIR}"; MODELS_GONE="${SAFE_RM_DID}"
  safe_rm "${USER_HOME}/.cache/huggingface"
else
  info "Keeping ${MODELS_DIR} (use --models to delete it)."
fi

# ======================================================================== 5 ==
step "5  Firewall"
# These rules are NOT ours: the installer only ever allows SSH. A rule opening
# 8020 or 7000 to the LAN exists because the person followed Step 10 or 11 of
# the guide and typed it themselves, so deleting it silently while calling it
# "our rule" removes someone's deliberate configuration behind their back.
#
# Report only what was really deleted, too. The old code announced dropping
# both rules unconditionally, so it claimed success on machines that had no
# such rules, and on machines whose rules were written as `ufw allow 8020`
# rather than `8020/tcp`, where the delete quietly matched nothing.
# ufw's exit code cannot be used to tell whether a rule went. Deleting a rule
# that does not exist prints "Could not delete non-existent rule" and still
# exits 0, and `delete allow 8020/tcp` does not match a rule that was added as
# `ufw allow 8020`, which covers both protocols. The only trustworthy check is
# to read the rules back afterwards.
# Read the rules into a variable and match against that, rather than piping ufw
# into `grep -q`. Under `set -o pipefail`, grep -q exits on its first match and
# closes the pipe, ufw dies of SIGPIPE, and the pipeline reports 141 even though
# the rule was found. Whether that happens depends on how far down the list the
# match is and on how ufw happens to flush, so the bug appears and disappears
# with the length of the user's rule list.
has_rule(){ grep -qE "^$1(/tcp)?[[:space:]]" <<<"$2"; }
FW_DROPPED=""; FW_STUCK=""
if command -v ufw >/dev/null 2>&1; then
  for p in "${PORT_LLAMA}" "${PORT_ODY}"; do
    rules_before="$(ufw status 2>/dev/null || true)"
    has_rule "${p}" "${rules_before}" || continue
    RUN ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
    RUN ufw delete allow "${p}"     >/dev/null 2>&1 || true
    rules_after="$(ufw status 2>/dev/null || true)"
    if [[ "${DRY}" == "yes" ]] || ! has_rule "${p}" "${rules_after}"; then
      FW_DROPPED="${FW_DROPPED} ${p}"
    else
      FW_STUCK="${FW_STUCK} ${p}"
    fi
  done
fi
if [[ "${DO_FW}" == "yes" ]]; then
  RUN ufw --force disable >/dev/null 2>&1 || warn "Could not disable ufw."
  ok_did "ufw disabled (back to OS default; SSH stays reachable)."
elif [[ -n "${FW_DROPPED}" || -n "${FW_STUCK}" ]]; then
  [[ -n "${FW_DROPPED}" ]] && \
    ok_did "Removed the LAN rule(s) for port(s)${FW_DROPPED}, which you had opened for PatterOS."
  if [[ -n "${FW_STUCK}" ]]; then
    warn "Could not remove the firewall rule(s) for port(s)${FW_STUCK}."
    warn "Nothing is listening on them now, so they open nothing, but you can tidy them up:"
    for p in ${FW_STUCK}; do info "      sudo ufw delete allow ${p}"; done
    info "List them first with:  sudo ufw status numbered"
  fi
  info "Left ufw itself as-is (use --firewall to disable it)."
else
  info "No PatterOS LAN rules to remove; left ufw exactly as-is (use --firewall to disable it)."
fi

# ======================================================================== 6 ==
step "6  LACT"
if [[ "${DO_LACT}" == "yes" ]]; then
  RUN systemctl disable --now lactd >/dev/null 2>&1 || true
  if pkg_installed lact; then RUN apt-get purge -y -qq lact || warn "apt purge lact failed."
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
    if grep -qw -- "${ggroup}" <<<"$(id -nG "${guser}" 2>/dev/null || true)"; then
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
NEED_AUTOREMOVE="no"; PKGS_PURGED="no"; DRV_PURGED="no"
if [[ "${DO_PKGS}" == "yes" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  present=(); kept=(); refused=()
  for p in "${PURGE_EXTRAS[@]}"; do
    pkg_installed "${p}" || continue
    if pkg_protected "${p}"; then refused+=("${p}")
    elif pkg_was_added "${p}"; then present+=("${p}")
    else kept+=("${p}")
    fi
  done
  if (( ${#present[@]} > 0 )); then
    info "Purging what this project installed: ${present[*]}"
    RUN apt-get purge -y -qq "${present[@]}" || warn "Some packages refused to purge; continuing."
    NEED_AUTOREMOVE="yes"; PKGS_PURGED="yes"
  elif [[ ! -r "${PKGS_ADDED_FILE}" ]]; then
    info "No record of packages installed by PatterOS, so none are being purged."
    info "That record is written from this version onwards; an older install has none,"
    info "and guessing from a fixed list is how you lose a package you needed."
  else
    info "Nothing to purge: this project did not install any of its optional extras."
  fi
  (( ${#kept[@]} > 0 )) && info "Kept (already on this machine before PatterOS): ${kept[*]}"
  if (( ${#refused[@]} > 0 )); then
    info "Kept on purpose: ${refused[*]}."
    info "On AMD and Intel machines that is the graphics driver, and the desktop depends on it."
  fi
  info "Keeping core tools (git, curl, cmake, build-essential, python3, ufw, pciutils)."
else
  info "Leaving apt packages as-is (use --packages to purge build/Vulkan extras)."
fi

# ======================================================================== 9 ==
step "9  GPU drivers / CUDA"
NEED_REBOOT="no"
if [[ "${DO_DRIVERS}" == "yes" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  # Only what the installer recorded installing, de-duplicated, blank lines
  # skipped so an empty match never yields a phantom entry.
  #
  # This used to be `dpkg-query -W 'nvidia-*' 'libnvidia-*' 'cuda-*'` plus a
  # fixed toolchain list. On the machine this was tested on that matches 79
  # installed packages, including libnvidia-compute for four driver series the
  # installer never touched, nvidia-prime, nvidia-settings and the Nsight tools,
  # followed by `apt-get autoremove`. A flag documented as removing what PatterOS
  # installed could take out the display driver of a working desktop.
  declare -A seen=(); present=()
  if [[ -r "${PKGS_ADDED_FILE}" ]]; then
    while IFS= read -r p; do
      [[ -n "${p}" ]] || continue
      [[ -n "${seen[${p}]:-}" ]] && continue
      pkg_protected "${p}" && continue
      pkg_installed "${p}" && { present+=("${p}"); seen[${p}]=1; }
    done < "${PKGS_ADDED_FILE}"
  fi
  if (( ${#present[@]} > 0 )); then
    warn "Purging the driver/CUDA packages this project installed: ${present[*]}"
    RUN apt-get purge -y -qq "${present[@]}" || warn "Some driver packages refused to purge; continuing."
    NEED_AUTOREMOVE="yes"; NEED_REBOOT="yes"; DRV_PURGED="yes"
  elif [[ ! -r "${PKGS_ADDED_FILE}" ]]; then
    warn "No record of what PatterOS installed, so no driver packages are being touched."
    info "Removing a GPU driver by pattern can leave a machine with no display, so it is"
    info "not done on a guess. If you do want the NVIDIA stack gone, the supported route is:"
    info "    sudo ubuntu-drivers install --free-only   (or Driver Manager) to choose a driver"
    info "    sudo apt-get purge 'nvidia-*' 'libnvidia-*' 'cuda-*' && sudo apt-get autoremove"
    info "Run that from a text console, not the desktop, and reboot afterwards."
  else
    info "No driver or CUDA packages were installed by PatterOS, so there are none to remove."
  fi
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
# List what was actually removed. This line used to be printed verbatim on every
# run, so a reset on a machine with nothing installed still reported deleting
# the services and both directories. A summary that does not match what happened
# is worse than no summary, because it is the part people screenshot and quote
# back when something is missing.
REMOVED=()
[[ "${SVC_TOUCHED}" == "yes" ]] && REMOVED+=("services")
[[ "${LLAMA_GONE}"  == "yes" ]] && REMOVED+=("${LLAMA_DIR}")
[[ "${ODY_GONE}"    == "yes" ]] && REMOVED+=("${ODY_DIR}")
[[ "${MODELS_GONE}" == "yes" ]] && REMOVED+=("${MODELS_DIR}")
[[ "${PKGS_PURGED}" == "yes" ]] && REMOVED+=("build/Vulkan extras PatterOS installed")
[[ "${DRV_PURGED}"  == "yes" ]] && REMOVED+=("GPU driver/CUDA packages PatterOS installed")
if [[ "${#REMOVED[@]}" -gt 0 ]]; then
  echo "  Removed:   ${REMOVED[0]}"
  for r in "${REMOVED[@]:1}"; do echo "             + ${r}"; done
else
  echo "  Removed:   nothing, there was no PatterOS install left to remove."
fi
echo
if [[ -n "${ODY_DATA_SAVED}" ]]; then
  echo "  Kept:      your Odysseus notes, uploads and chat history"
  echo "             ${ODY_DATA_SAVED}"
fi
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
