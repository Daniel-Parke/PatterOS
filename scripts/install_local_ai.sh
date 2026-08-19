#!/usr/bin/env bash
# =============================================================================
#  PatterOS · Local AI Budget Build · Part 2 companion installer
#  install_local_ai.sh  (v1.5)
#
#  Automates EXACTLY what the Manual Setup Guide does, for people who would
#  rather run a script than type the steps by hand:
#
#    1. Update the system and install build tools + Vulkan libraries
#    2. Detect the GPU (NVIDIA / AMD / Intel / none) by PCI vendor ID
#    3. Install drivers / toolchains for that GPU
#    4. Build llama.cpp (CUDA on NVIDIA, Vulkan on AMD/Intel, CPU otherwise)
#    5. Download a small model (or more) into ~/models
#    6. Run llama.cpp in ROUTER MODE as a service (--models-dir, hot model
#       swapping, no restart), listening on this computer only
#    7. Install Odysseus (the web workspace) and run it as a service
#    8. Turn on the firewall (SSH allowed first, so you can't lock yourself out)
#
#  Everything is optional. Nothing here is installed unless you choose it, and
#  every part can be removed again with uninstall_local_ai.sh.
#
#  USAGE
#     less install_local_ai.sh           # read it first, never blind-run a script
#     sudo bash install_local_ai.sh      # interactive
#     sudo bash install_local_ai.sh -y   # no prompts (express models)
#
#  FLAGS
#     --full           Also download bigger models (24 GB card, ~70 GB free disk).
#     --no-models      Don't download anything (you'll add models later).
#     --no-odysseus    Inference server only; skip the Odysseus workspace.
#     --cpu            Force CPU-only (ignore any GPU).
#     --skip-upgrade   Don't run 'apt upgrade' (apt update still refreshes lists).
#     --skip-drivers   Don't touch GPU drivers or toolchains at all.
#     --skip-build     Reuse an existing llama.cpp build if one is present.
#     --rebuild        Force a fresh llama.cpp build even if one exists.
#     --skip-firewall  Don't enable or modify ufw.
#     --replace-units  Overwrite service files even if you edited them by hand.
#     --lact           Install LACT (GPU power/fan tuning GUI). Default on GPU rigs.
#     --no-lact        Skip LACT.
#     -y, --yes        Assume yes; don't prompt. Implies you've already read this
#                      script. The habit below still applies!
#     -h, --help       Show this help.
#
#  SETTINGS you can pass as environment variables
#     LLAMA_VERSION=<tag>  llama.cpp version to build   (default: a tested tag)
#     CTX=<tokens>         context window per model     (default: 16384)
#     NGL=<layers>         layers to put on the GPU     (default: automatic)
#     JOBS=<n>             compilers to run at once     (default: as many as
#                          your cores and free memory allow, whichever is lower)
#
#  Re-running is safe AND smart: a healthy NVIDIA driver is never reinstalled,
#  a finished build is reused, service files you edited yourself are kept, and
#  the interactive menu lets you skip phases or customise ports, context size,
#  model tier, LACT and the firewall.
#
#  FIRST, A HABIT WORTH KEEPING: never run a script from the internet (ours
#  included) without looking inside it. The comments explain every phase:
#      less install_local_ai.sh        (press q to quit the viewer)
# --- end of help ------------------------------------------------------------
#
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Daniel Parke. See LICENSE and NOTICE.
# =============================================================================
set -Eeuo pipefail

# ----- pretty output --------------------------------------------------------
if [[ -t 1 ]]; then
  C=$'\033[38;5;38m'; OK=$'\033[38;5;42m'; WN=$'\033[38;5;208m'; ER=$'\033[38;5;196m'; B=$'\033[1m'; N=$'\033[0m'
else C=''; OK=''; WN=''; ER=''; B=''; N=''; fi
step(){ echo -e "\n${C}${B}==>${N} ${B}$*${N}"; }
info(){ echo -e "    $*"; }
good(){ echo -e "${OK}[OK]${N} $*"; }
warn(){ echo -e "${WN}[!]${N} $*" >&2; }
die(){  echo -e "${ER}[FAIL]${N} $*" >&2; exit 1; }
# Be honest here. By the time most errors fire we may already have installed
# packages, touched drivers or written a service file, so "nothing was changed"
# would be a lie. What IS true is that re-running is safe and picks up where it
# left off, and that the uninstaller will clean up.
trap 'echo >&2; die "Stopped at line ${LINENO}. Anything already finished above has been left in place; it is safe to fix the cause and run this again. To undo everything, run: sudo bash uninstall_local_ai.sh"' ERR

# ----- config (the few things we pin on purpose) ----------------------------
LLAMA_REPO="https://github.com/ggml-org/llama.cpp"
# Router mode needs a recent build, but "latest" is not the safe default it
# looks like. Two upstream facts decide this pin:
#   - Before tag b9702 (18 Jun 2026) the router PARSED --gpu-layers/-c/--jinja
#     and then silently discarded them, so every model ran with upstream
#     defaults and the GPU sat idle. Fixed by ggml-org/llama.cpp#24760.
#   - ?reload=1 on /v1/models only exists from tag b9023 (04 May 2026).
# b10313 is comfortably past both and adds the LRU scheduler. Override with
# LLAMA_VERSION=<tag>, or LLAMA_VERSION=master to track the tip (you will be
# warned, because master is not tested against this script).
LLAMA_VERSION="${LLAMA_VERSION:-b10313}"
PORT_LLAMA=8020          # the model server
PORT_ODY=7000            # the Odysseus workspace
STAMP_DIR="/var/lib/patteros"   # what PatterOS changed, so it can be undone
CTX="${CTX:-16384}"      # context window per model (bounded to protect memory)
NGL_OVERRIDE="${NGL:-}"  # layers to put on the GPU; empty = decide automatically
JOBS_OVERRIDE="${JOBS:-}"  # compilers to run at once; empty = cores vs memory
LACT_VER="0.10.0"        # GPU power/fan tuning GUI (guide, Step 12)
LACT_DEB_URL="https://github.com/ilya-zlobintsev/LACT/releases/download/v${LACT_VER}/lact-${LACT_VER}-0.amd64.ubuntu-2404.deb"

# Odysseus (third-party AGPL-3.0 workspace, github.com/odysseus-dev/odysseus).
# NOTE: the old pewdiepie-archdaemon/odysseus address still "works", but only
# as a GitHub rename redirect over a name slot that account no longer uses.
# If that account ever creates a repo called odysseus, the redirect silently
# points somewhere else and this script would clone and execute it. Always use
# the canonical address below. Upstream publishes no tags or releases, so the
# only thing we can pin to is a commit.
ODY_REPO="https://github.com/odysseus-dev/odysseus.git"
ODY_BRANCH="main"        # upstream's own docs recommend main for stability
ODY_COMMIT="${ODY_COMMIT:-cf4e240ad1622da6a904f496b19d656a2b9c6393}"

# Models: "HF repo | filename glob | approx GB". The size is used to check you
# have the disk and the memory BEFORE anything is downloaded.
#
# All entries are q4-class on purpose: a model either fits in memory or it does
# not, and q4 is what makes these fit on a real budget card. We never download
# full-precision weights.
#
# Gemma entries are the QAT (quantisation-aware training) builds. Google trains
# these with the quantisation in mind rather than compressing afterwards, and
# they are 0.6 to 1.6 GB smaller per model than the standard builds at the same
# UD-Q4_K_XL level, which matters on the 512 GB drive in the Part 1 build.
#
# Qwen 3.8 27B entries are the Unsloth UD-Q4_K_XL and AtomicChat AD-Q4_K_M
# builds. Both are q4-class dense 27B files for 24 GB cards. A smaller
# AD-IQ3_XXS exists for 16 GB cards; it is documented in the guide and is not
# downloaded here (this list stays q4-only).
# Every repo below was checked on 18 August 2026: all six resolve, all are
# ungated, and each contains exactly ONE file matching the glob. Gemma and
# Unsloth Qwen3.8 cards are Apache 2.0. AtomicChat did not stamp a licence
# field; it is an ungated quant of Apache 2.0 Qwen/Qwen3.8-27B.
# Watch the casing: E2B and E4B are capitals, and 12B and 31B are capital B in
# the QAT repos (the non-QAT 12b repo uses a lowercase b). Qwen3.8 uses a
# dotted 3.8 in both the repo and the filename.
EXPRESS_MODELS=(
  "unsloth/gemma-4-E2B-it-qat-GGUF|*UD-Q4_K_XL*.gguf|2.7"    # tiny, runs anywhere
  "unsloth/gemma-4-E4B-it-qat-GGUF|*UD-Q4_K_XL*.gguf|4.3"    # small but capable
)
FULL_MODELS=(
  "unsloth/gemma-4-12B-it-qat-GGUF|*UD-Q4_K_XL*.gguf|6.8"    # strong mid-size all-rounder
  "unsloth/gemma-4-31B-it-qat-GGUF|*UD-Q4_K_XL*.gguf|17.3"   # top quality on a 24 GB card
  "unsloth/Qwen3.8-27B-GGUF|*UD-Q4_K_XL*.gguf|16.7"          # Qwen 3.8 Unsloth UD Q4
  "AtomicChat/Qwen3.8-27B-GGUF|*AD-Q4_K_M*.gguf|15.9"        # Qwen 3.8 AtomicChat AD Q4
)

# ----- args -----------------------------------------------------------------
TIER="express"; WANT_MODELS="yes"; WANT_ODY="yes"; FORCE_CPU="no"
SKIP_UPGRADE="no"; SKIP_DRIVERS="no"; SKIP_BUILD="no"; REBUILD="no"; SKIP_FW="no"; YES="no"
REPLACE_UNITS="no"   # overwrite systemd units even if they were edited by hand
WANT_LACT="ask"      # ask = yes on GPU rigs unless changed at the menu
# Print the header block as help. Reads to a sentinel rather than a hard-coded
# line number: the old `sed -n '2,51p'` silently truncated the help, or spilled
# code into it, the moment anyone added or removed a line above.
show_help(){ sed -n '2,/^# --- end of help/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do case "$1" in
  --full)        TIER="full";;
  # Set the tier too, not just the flag. recompute_models() decides from TIER,
  # and its fallback arm sets WANT_MODELS back to "yes", so a bare flag was
  # overwritten before it was ever read and the express set downloaded anyway.
  --no-models)   WANT_MODELS="no"; TIER="none";;
  --no-odysseus) WANT_ODY="no";;
  --cpu)         FORCE_CPU="yes";;
  --skip-upgrade)  SKIP_UPGRADE="yes";;
  --skip-drivers)  SKIP_DRIVERS="yes";;
  --skip-build)    SKIP_BUILD="yes";;
  --rebuild)       REBUILD="yes";;
  --skip-firewall) SKIP_FW="yes";;
  --replace-units) REPLACE_UNITS="yes";;
  --lact)          WANT_LACT="yes";;
  --no-lact)       WANT_LACT="no";;
  -y|--yes)      YES="yes";;
  -h|--help)     show_help; exit 0;;
  *) die "Unknown option: $1 (try --help)";;
esac; shift; done

# ----- pre-flight -----------------------------------------------------------
[[ ${EUID} -eq 0 ]] || die "Run with sudo:  sudo bash install_local_ai.sh"
REAL_USER="${SUDO_USER:-}"
[[ -n "${REAL_USER}" && "${REAL_USER}" != "root" ]] || die "Run via sudo as your normal user:  sudo bash install_local_ai.sh"
USER_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
[[ -d "${USER_HOME}" ]] || die "Could not find the home directory for ${REAL_USER}."
# Everything this script creates or rebuilds hangs off USER_HOME, including
# `rm -rf "${LLAMA_DIR}/build"`. With a home of "/" those become paths at the top
# of the filesystem, so refuse it here rather than find out later. The matching
# check in uninstall_local_ai.sh is what keeps its safe_rm guard honest.
[[ "${USER_HOME}" != "/" ]] || die "The home directory for ${REAL_USER} is '/', which is not a usable home."
as_user(){ sudo -u "${REAL_USER}" -H "$@"; }     # run a command as the real user
hf_user(){ as_user env PATH="${USER_HOME}/.local/bin:${PATH}" "$@"; }

MODELS_DIR="${USER_HOME}/models"
LLAMA_DIR="${USER_HOME}/llama.cpp"
ODY_DIR="${USER_HOME}/odysseus"

echo -e "${C}${B}"
echo "  ============================================================"
echo "     PatterOS  ·  Local AI Budget Build"
echo "     Part 2 companion installer  ·  v1.5"
echo "  ============================================================"
echo -e "     Your hardware. Your data. Your control.${N}"
echo
echo -e "  ${B}What this script does${N}"
echo "  Everything from the Part 2 manual guide, on a fresh Mint or Ubuntu machine:"
echo "  system packages → GPU drivers → the llama.cpp engine (router mode) → starter"
echo "  models → background services → the Odysseus workspace → optional LACT GPU"
echo "  tuning → a basic firewall. Hands-on testing and tweaking stays with you,"
echo "  exactly as the guide teaches it. Every phase is safe to re-run."
echo
echo -e "  ${B}One habit worth keeping for life${N}"
echo "  Never run a script from the internet, ours included, without looking inside"
echo "  it first. You don't need to be a programmer: open it with the command below,"
echo "  and the plain-English comments will walk you through every phase."
echo
echo -e "      ${C}less install_local_ai.sh${N}        (arrow keys to scroll, q to quit)"
echo
if [[ "${YES}" != "yes" ]]; then
  read -r -p "  Happy you know what this script does, and ready to go? [y/N]: " a </dev/tty || true
  if [[ "${a,,}" != "y" && "${a,,}" != "yes" ]]; then
    echo
    info "No problem at all, have a read and come back whenever. It'll be here."
    exit 0
  fi
else
  info "(-y given: assuming you've already read it. The habit still applies!)"
fi
echo
info "User: ${REAL_USER}   Home: ${USER_HOME}"
# shellcheck source=/dev/null
if [[ -r /etc/os-release ]]; then . /etc/os-release; info "OS:   ${PRETTY_NAME:-unknown}"
  case "${ID:-}${ID_LIKE:-}" in *ubuntu*|*debian*|*mint*) :;; *) warn "Targets Ubuntu / Mint / Debian; ${PRETTY_NAME:-this OS} is untested.";; esac
fi

# ----- NVIDIA driver health -------------------------------------------------
# Prints one of: ok | mismatch | notloaded | missing | broken
#   ok        loaded and answering                       -> leave it alone
#   mismatch  files on disk newer than loaded module     -> ONE reboot, never reinstall
#   notloaded installed but module not loaded yet        -> ONE reboot, never reinstall
#   missing   nvidia-smi not present (fresh machine)     -> install
#   broken    nvidia-smi present but failing another way -> try install once
# LC_ALL=C matters: we classify by matching English words in nvidia-smi's
# output. On a French or German system the translated message would not match,
# we would fall through to "broken", and the script would reinstall a driver
# that was merely waiting for a reboot. That is the exact failure this function
# exists to prevent, so we force the C locale for the check.
nvidia_state(){
  command -v nvidia-smi >/dev/null 2>&1 || { echo missing; return 0; }
  local out="" rc=0
  out="$(LC_ALL=C nvidia-smi 2>&1)" || rc=$?
  if (( rc == 0 )); then echo ok
  elif grep -qi 'mismatch'    <<<"${out}"; then echo mismatch
  elif grep -qi 'communicate' <<<"${out}"; then echo notloaded
  else echo broken; fi
  return 0
}

# ----- hardware facts we need before we promise the user anything -----------
# Free disk in whole GB on the filesystem holding a given path.
free_gb(){ df -PBG "$1" 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4+0}'; }

# VRAM in whole GB, or empty if we genuinely cannot tell. Never guess.
#
# NVIDIA is nvidia-smi. AMD and Intel have no equivalent that we install:
# glxinfo comes from mesa-utils, which is not in BASE_PKGS, so a machine that
# only has what this script put on it has no glxinfo. The amdgpu/i915 sysfs
# node is always there when the kernel can see the card, and is what ReBAR
# detection and -ngl both need. Without it, AMD installs silently used
# -ngl 999 and skipped the ReBAR workaround.
vram_gb(){
  local mb="" b f this=0
  if command -v nvidia-smi >/dev/null 2>&1 && [[ "$(nvidia_state)" == "ok" ]]; then
    mb="$(LC_ALL=C nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | sort -rn | head -1 || true)"
  fi
  if [[ -z "${mb}" ]] && command -v glxinfo >/dev/null 2>&1; then
    mb="$(LC_ALL=C glxinfo -B 2>/dev/null | awk -F': *' '/Video memory/{gsub(/MB.*/,"",$2); print $2+0; exit}' || true)"
  fi
  if [[ -z "${mb}" ]]; then
    for f in /sys/class/drm/card*/device/mem_info_vram_total; do
      [[ -r "${f}" ]] || continue
      b="$(tr -dc '0-9' < "${f}" 2>/dev/null || true)"
      [[ "${b}" =~ ^[1-9][0-9]*$ ]] || continue
      this=$(( b / 1024 / 1024 ))
      (( this > ${mb:-0} )) && mb="${this}"
    done
  fi
  [[ -n "${mb}" && "${mb}" != "0" ]] && echo $(( mb / 1024 )) || echo ""
}

# ----- AMD/Intel Vulkan health ---------------------------------------------
# Three things quietly cripple the Vulkan backend. None of them look like a
# problem: the GPU is detected, the build succeeds, and it is simply slow.
#
#   1. Resizable BAR turned off in the BIOS. llama.cpp issue #27097 measures
#      token generation collapsing from 37.09 to 13.89 t/s on an RX 7900 XTX,
#      restored by GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1.
#   2. Mesa older than 25.2. Ubuntu 24.04 ships 24.0.5 in the release pocket
#      and only reaches 25.2.x after updates, so a fresh install is below the
#      floor llama.cpp discussion #23295 recommends.
#   3. AMDVLK instead of RADV. AMD no longer supports AMDVLK and recommends
#      RADV; AMDVLK is what fails in issue #15054.
#
# Anything we can fix, we fix. Anything we cannot, we say out loud.
VK_ENV=()   # extra Environment= lines for the service
vulkan_health(){
  [[ "${VENDOR}" == "amd" || "${VENDOR}" == "intel" ]] || return 0
  local summary="" drv="" mesa="" vram_mb bar_mb

  command -v vulkaninfo >/dev/null 2>&1 && summary="$(LC_ALL=C vulkaninfo --summary 2>/dev/null || true)"

  # --- driver in use ---
  # Prefer the GPU0 device block. Instance layers list "Mesa Overlay" first and
  # that is not a driver.
  drv="$(awk -F'= *' '/driverName/{print $2; exit}' <<<"${summary}" | tr -d ' ' || true)"
  if [[ "${drv}" == *"amdvlk"* || "${drv}" == *"AMDVLK"* ]]; then
    warn "Your system is using the AMDVLK Vulkan driver."
    info "AMD no longer supports it and recommends RADV, which is the one built into Linux."
    info "If models run slowly, removing the amdvlk package usually fixes it."
  fi

  # --- Mesa version ---
  # Match driverInfo only. `vulkaninfo --summary` lists instance layers first,
  # including "Mesa Overlay layer", and a looser /Mesa/ match reported that as
  # the graphics driver on this AMD machine.
  mesa="$(awk -F'Mesa ' '/driverInfo/{print $2; exit}' <<<"${summary}" | awk '{print $1}' || true)"
  [[ -z "${mesa}" ]] && mesa="$(dpkg-query -W -f='${Version}' mesa-vulkan-drivers 2>/dev/null | sed 's/[^0-9.].*//' || true)"
  if [[ -n "${mesa}" ]]; then
    local maj min; maj="${mesa%%.*}"; min="$(cut -d. -f2 <<<"${mesa}")"
    if [[ "${maj}" =~ ^[0-9]+$ && "${min}" =~ ^[0-9]+$ ]] && (( maj < 25 || (maj == 25 && min < 2) )); then
      warn "Your graphics driver (Mesa ${mesa}) is older than the 25.2 that works best here."
      info "A full system update usually brings a newer one:  sudo apt update && sudo apt upgrade"
    else
      info "Graphics driver: Mesa ${mesa}."
    fi
  fi

  # --- Resizable BAR ---
  # If the biggest prefetchable window the card exposes is much smaller than
  # its own memory, ReBAR is off. Comparing against VRAM avoids hard-coding
  # the old 256 MB default, which not every card uses.
  vram_mb="$(vram_gb)"; vram_mb=$(( ${vram_mb:-0} * 1024 ))
  bar_mb="$(LC_ALL=C lspci -v 2>/dev/null \
            | awk '/prefetchable/ {
                if (match($0,/size=[0-9]+[MG]/)) {
                  s=substr($0,RSTART+5,RLENGTH-5); u=substr(s,length(s));
                  v=substr(s,1,length(s)-1)+0; if(u=="G") v*=1024;
                  if (v>m) m=v
                }
              } END{print m+0}' || echo 0)"
  if (( vram_mb > 0 && bar_mb > 0 && bar_mb < vram_mb / 2 )); then
    warn "Resizable BAR looks like it is turned off in your BIOS."
    info "Your card has ${vram_mb} MB of memory but only exposes a ${bar_mb} MB window."
    info "This roughly halves speed. Turning on 'Resizable BAR' or 'Above 4G Decoding'"
    info "in the BIOS is the real fix, and is worth doing when you next restart."
    info "In the meantime PatterOS will work around it, which recovers most of the loss."
    VK_ENV+=("Environment=GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1")
  fi

  # Recommended regardless, per llama.cpp discussion #23295.
  [[ "${VENDOR}" == "amd" ]] && VK_ENV+=("Environment=RADV_PERFTEST=nogttspill")
  return 0
}

# ----- detect GPU by PCI vendor ID (robust; never by name text) -------------
step "Detecting your GPU"
command -v lspci >/dev/null 2>&1 || { apt-get update -qq || true; apt-get install -y -qq pciutils || true; }
# DETECTED_VENDOR is the card that is actually there. VENDOR is the path we
# take. --cpu sets VENDOR to cpu without forgetting the card, because a later
# --skip-build can still reuse a vulkan binary and the unit then needs the
# AMD/Intel workarounds. Detecting only when FORCE_CPU is off made
# --cpu --skip-build strip GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM from a live
# AMD service.
DETECTED_VENDOR="cpu"
VENDOR="cpu"
ids="$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | grep -oE '\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]' | tr -d '[]' | cut -d: -f1 | tr 'A-F' 'a-f' || true)"
if   grep -q '10de' <<<"${ids}"; then DETECTED_VENDOR="nvidia"
elif grep -q '1002' <<<"${ids}"; then DETECTED_VENDOR="amd"
elif grep -q '8086' <<<"${ids}"; then DETECTED_VENDOR="intel"; fi
if [[ "${FORCE_CPU}" != "yes" ]]; then
  VENDOR="${DETECTED_VENDOR}"
fi
NEED_REBOOT="no"
NV_BEFORE="n/a"; [[ "${VENDOR}" == "nvidia" ]] && NV_BEFORE="$(nvidia_state)"
case "${VENDOR}" in
  nvidia) info "Found an NVIDIA GPU  → Path A (CUDA, fastest)   [driver: ${NV_BEFORE}]";;
  amd)    info "Found an AMD GPU    → Path B (Vulkan, universal)";;
  intel)
    info "Found an Intel GPU  → Path B (Vulkan, universal)"
    warn "Intel graphics is not tested by us. The installer still takes the Vulkan path, the same as AMD."
    info "If it does not work, re-run with --cpu to use the processor instead, and please open an issue:"
    info "https://github.com/Daniel-Parke/PatterOS/issues"
    ;;
  cpu)    info "No GPU detected (or --cpu) → Path C (CPU only). 1 tok/s beats 0.";;
esac

# ----- what we think your machine is, and one honest warning ----------------
# Shown once, before anything is changed. Two jobs: let the user catch a wrong
# detection while it is still free to do so, and be straight with them that the
# driver step is the one part that carries real risk. Written to inform, not to
# frighten, and short enough that people actually read it.
hardware_summary(){
  local cpu ram disk gpu
  cpu="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  [[ -z "${cpu}" ]] && cpu="unknown"
  ram="$(awk '/^MemTotal:/{printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || true)"
  disk="$(free_gb "${USER_HOME}")"
  case "${VENDOR}" in
    nvidia) gpu="$(LC_ALL=C nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)";;
    amd|intel) gpu="$(LC_ALL=C lspci 2>/dev/null | grep -iE 'vga|3d|display' | sed 's/.*: //' | head -1 || true)";;
    *) gpu="";;
  esac
  if [[ -z "${gpu}" ]]; then
    if [[ "${FORCE_CPU}" == "yes" ]]; then gpu="ignoring any graphics card (--cpu), using the processor"
    else gpu="none found, so the processor will do the work"; fi
  fi

  echo
  echo -e "  ${B}Before we start${N}"
  echo
  echo "  PatterOS has had a look at your computer and thinks it has:"
  echo
  echo "      Processor:  ${cpu}"
  echo "      Graphics:   ${gpu}"
  echo "      Memory:     ${ram:-?} GB"
  echo "      Free disk:  ${disk:-?} GB in ${USER_HOME}"
  echo
  echo "  Please check that looks right, because everything that follows is based on it."
  echo
  if [[ "${SKIP_DRIVERS}" == "yes" ]]; then
    echo "  This installer will update your system. You have asked it to leave graphics"
    echo "  drivers alone, so it will not touch them."
  else
    echo "  This installer will update your system, and on some machines it installs"
    echo "  graphics drivers. That driver step is the one part that carries real risk:"
    echo "  it very rarely goes wrong, but when it does it can mean reinstalling the"
    echo "  system. Please do not run this on a computer you cannot be without for an"
    echo "  evening."
  fi
  echo
  echo "  Everything here is optional. You choose what gets installed, nothing has been"
  echo "  changed yet, and you can stop now or at any prompt. If you change your mind"
  echo "  later, uninstall_local_ai.sh puts things back."
  echo
  return 0
}

hardware_summary
if [[ "${YES}" != "yes" ]]; then
  read -r -p "  Does that look like your computer, and are you happy to continue? [y/N]: " a </dev/tty || true
  if [[ "${a,,}" != "y" && "${a,,}" != "yes" ]]; then
    echo
    info "Stopping here, and nothing has been changed."
    info "If the hardware above looked wrong, that is worth telling us about:"
    info "https://github.com/Daniel-Parke/PatterOS/issues"
    exit 0
  fi
else
  info "(-y given: continuing without asking you to confirm the hardware above.)"
fi

# ----- plan + interactive menu ----------------------------------------------
# Sensible defaults; LACT defaults to yes on GPU rigs (it's our standard tool).
if [[ "${WANT_LACT}" == "ask" ]]; then
  if [[ "${VENDOR}" == "cpu" ]]; then WANT_LACT="no"; else WANT_LACT="yes"; fi
fi
recompute_models(){
  case "${TIER}" in
    full)    MODEL_SET=("${EXPRESS_MODELS[@]}" "${FULL_MODELS[@]}"); WANT_MODELS="yes";;
    none)    MODEL_SET=(); WANT_MODELS="no";;
    *)       TIER="express"; MODEL_SET=("${EXPRESS_MODELS[@]}"); WANT_MODELS="yes";;
  esac
  if [[ "${WANT_MODELS}" == "no" ]]; then MODEL_SET=(); fi
  return 0
}
recompute_models
if [[ "${WANT_MODELS}" == "no" ]]; then TIER="none"; MODEL_SET=(); fi

# Total download size for the current tier, in whole GB (rounded up).
models_total_gb(){
  local sum=0 entry
  for entry in ${MODEL_SET[@]+"${MODEL_SET[@]}"}; do
    sum="$(awk -v a="${sum}" -v b="${entry##*|}" 'BEGIN{printf "%.1f", a+b}')"
  done
  awk -v s="${sum}" 'BEGIN{printf "%d", (s==int(s)?s:int(s)+1)}'
}
# Largest single model in the current tier, in whole GB (rounded up). This is
# the number that decides whether a model fits on the card, not the total.
models_largest_gb(){
  local max=0 entry
  for entry in ${MODEL_SET[@]+"${MODEL_SET[@]}"}; do
    max="$(awk -v a="${max}" -v b="${entry##*|}" 'BEGIN{print (b>a?b:a)}')"
  done
  awk -v s="${max}" 'BEGIN{printf "%d", (s==int(s)?s:int(s)+1)}'
}

# Two questions, asked at two different moments, so two functions.
#
# Disk can be asked before the install starts, and must be: a tier that could
# never fit used to cost you a system upgrade, a driver install and a full
# engine build before anyone mentioned it. It is asked again before the
# download, because the build in between consumes disk of its own.
#
# VRAM cannot be asked that early. On a fresh machine nothing has been
# installed yet: nvidia-smi arrives with the driver in phase 2, mesa-utils is
# never installed at all, and the sysfs fallback is an amdgpu node. vram_gb()
# would return nothing and the warning would silently stop happening, which no
# stub can catch because the stubs always answer.
#
# Neither refuses on VRAM. A model bigger than the card still runs, just partly
# from system memory, and 1 token/s beats 0.
preflight_disk(){
  (( ${#MODEL_SET[@]} > 0 )) || return 0
  local need free
  need="$(models_total_gb)"; free="$(free_gb "${USER_HOME}")"
  [[ -n "${free}" ]] || return 0
  (( free >= need + 5 )) && return 0
  warn "Not enough disk space for the '${TIER}' model set."
  info "It needs about ${need} GB, plus a few GB of headroom. You have ${free} GB free in ${USER_HOME}."
  info "Options: choose the 'express' tier, free up some space, or re-run with --no-models"
  info "and add models later into ${MODELS_DIR}."
  return 1
}

preflight_vram(){
  (( ${#MODEL_SET[@]} > 0 )) || return 0
  local vram largest
  largest="$(models_largest_gb)"; vram="$(vram_gb)"

  if [[ -n "${vram}" ]] && (( largest > vram )); then
    warn "The biggest model in the '${TIER}' set is about ${largest} GB, and your graphics card has ${vram} GB."
    info "It will still run: the parts that do not fit use system memory instead, which is slower."
    info "PatterOS will set the GPU layers automatically to suit your card."
    info "If you would rather stay fully on the GPU, choose the 'express' tier instead."
  elif [[ -z "${vram}" && "${VENDOR}" != "cpu" ]]; then
    info "Could not read how much memory your graphics card has, so nothing is assumed."
  fi
  return 0
}

# Is a package installed?
#
# Not `dpkg -l ... | grep -q`. Under `set -o pipefail`, grep -q exits at its
# first match and closes the pipe, so a producer that is still writing dies of
# SIGPIPE and the pipeline reports 141 even though the match was found. It bites
# in proportion to how much output there is, which makes it look intermittent.
# The uninstaller hit exactly this and silently skipped a purge, so the same
# pattern is avoided here on principle.
pkg_installed(){
  local out
  out="$(dpkg -l "$1" 2>/dev/null || true)"
  grep -qE "^ii[[:space:]]+$1[[:space:]]" <<<"${out}"
}

# Record packages that were absent before this run and are present after it, so
# the uninstaller can remove what we added and nothing else.
#
# This is the same principle the group-membership step already follows, and it
# was missing here with worse consequences. `--packages` purged a fixed list
# including mesa-vulkan-drivers, which is the actual graphics driver on an AMD or
# Intel desktop and which apt-cache shows xserver-xorg depending on; `--drivers`
# purged every nvidia-*, libnvidia-* and cuda-* package on the machine, which on
# this test rig is 79 packages spanning five driver series it never touched, then
# ran autoremove on top. Neither is a reversal of an install; both can leave a
# machine without a display.
record_pkgs(){ # $@ = packages we intended to install
  local p f="${STAMP_DIR}/packages-added"
  mkdir -p "${STAMP_DIR}"
  for p in "$@"; do
    [[ -n "${p}" ]] || continue
    pkg_installed "${p}" || continue
    grep -qxF -- "${p}" "${f}" 2>/dev/null && continue
    printf '%s\n' "${p}" >> "${f}"
  done
}

# Which of these are not installed yet. Call before apt, pass the result to
# record_pkgs after, so a package the user already had is never recorded as ours.
pkgs_absent(){
  local p
  for p in "$@"; do pkg_installed "${p}" || printf '%s\n' "${p}"; done
}

# What, if anything, is already listening on a port. Empty means free.
port_owner(){
  command -v ss >/dev/null 2>&1 || return 0
  ss -lntp 2>/dev/null | awk -v pat=":$1\$" '$4 ~ pat {print $NF; exit}'
}
# Surfaced in the plan, where a port can still be changed for free with 'c'.
# Worth the few lines because a busy port is otherwise reported as a driver
# problem in phase 5, sending the user off to debug the wrong thing.
# A re-run finds PatterOS's own service on the port, which is normal, so that
# case is reported calmly rather than as a clash.
port_notes(){
  local p name svc owner
  for spec in "${PORT_LLAMA}|the model server|llama.service" "${PORT_ODY}|the Odysseus workspace|odysseus.service"; do
    IFS='|' read -r p name svc <<<"${spec}"
    [[ "${svc}" == "odysseus.service" && "${WANT_ODY}" != "yes" ]] && continue
    owner="$(port_owner "${p}")"
    [[ -z "${owner}" ]] && continue
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
      echo "  Port ${p}:      in use by PatterOS's own ${svc}; it will be restarted."
    else
      echo "  Port ${p}:      ALREADY IN USE by ${owner}, which is not PatterOS."
      echo "                 ${name} cannot start while that holds the port. Press 'c' below to"
      echo "                 choose a different port, or stop that program first."
    fi
  done
  return 0
}

# Wait for a service to settle, then say which of three things happened.
#
# `systemctl is-active` the instant after `restart` is worthless as a health
# check: these units are Type=simple, so systemd calls them active the moment
# the process is forked. A service whose Python dies on an import error two
# seconds later therefore reports "active", and the installer used to announce
# success and print a URL for a workspace that was in a permanent crash loop.
#
# Restart=on-failure makes that failure hard to catch at a single instant too,
# because the unit alternates between activating and active while looping. The
# restart counter is the reliable signal: if it moves, the service is dying.
#
# An answer on the port is never taken as proof on its own. If another program
# owns the port it answers too, and reporting that as a healthy PatterOS service
# would be worse than reporting nothing. The unit must be active AND the port
# must answer before this says "serving".
#
# Echoes one of: serving | running | looping | dead
service_health(){
  local unit="$1" port="$2" wait_s="${3:-45}" i restarts0 restarts down=0
  restarts0="$(systemctl show -p NRestarts --value "${unit}" 2>/dev/null || true)"
  [[ "${restarts0}" =~ ^[0-9]+$ ]] || restarts0=0
  for (( i=0; i<wait_s; i++ )); do
    # A moving restart counter is the giveaway for a service that starts, dies,
    # and is started again, which no single-instant check can distinguish from
    # a healthy start.
    restarts="$(systemctl show -p NRestarts --value "${unit}" 2>/dev/null || true)"
    [[ "${restarts}" =~ ^[0-9]+$ ]] || restarts=0
    if (( restarts > restarts0 )); then echo looping; return 0; fi

    if systemctl is-active --quiet "${unit}" 2>/dev/null; then
      down=0
      if curl -fsS --max-time 2 "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1 \
         || curl -fsS --max-time 2 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
        echo serving; return 0
      fi
    else
      # Allow a couple of samples of grace: systemctl returns as soon as the
      # unit is activating, and a slow machine can lag a moment behind.
      down=$(( down + 1 ))
      (( down > 3 )) && { echo dead; return 0; }
    fi
    sleep 1
  done
  systemctl is-active --quiet "${unit}" 2>/dev/null && echo running || echo dead
}

# Show the actual error rather than telling the user to go and find it. Someone
# who has just watched a 15-minute build does not want a homework assignment,
# and the real cause is nearly always in the last few lines.
service_why(){
  local unit="$1"
  warn "The last few lines of its log, which usually say why:"
  journalctl -u "${unit}" -n 12 --no-pager 2>/dev/null \
    | sed 's/^/      /' || info "      (run: journalctl -u ${unit} -n 40 --no-pager)"
}

show_plan(){
  echo
  echo -e "${B}Plan${N}"
  echo "  GPU path:      ${VENDOR}"
  echo "  llama.cpp:     ${LLAMA_VERSION}  → router mode on port ${PORT_LLAMA}, context ${CTX}"
  echo "  Models dir:    ${MODELS_DIR}"
  if (( ${#MODEL_SET[@]} > 0 )); then
    local _free; _free="$(free_gb "${USER_HOME}")"
    echo "  Download:      ${#MODEL_SET[@]} model(s), about $(models_total_gb) GB, tier '${TIER}'${_free:+   (you have ${_free} GB free)}"
  else echo "  Download:      none (add models later into ${MODELS_DIR})"; fi
  echo "  Odysseus:      ${WANT_ODY}   (workspace on port ${PORT_ODY})"
  echo "  LACT tuning:   ${WANT_LACT}$( [[ "${VENDOR}" == "cpu" ]] && echo '   (no GPU to tune)' )"
  echo "  Firewall:      $([[ "${SKIP_FW}" == "yes" ]] && echo "leave as-is" || echo "enable (SSH allowed; everything else stays local)")"
  local skips=""
  if [[ "${SKIP_UPGRADE}" == "yes" ]]; then skips+=" upgrade"; fi
  if [[ "${SKIP_DRIVERS}" == "yes" ]]; then skips+=" drivers"; fi
  if [[ "${SKIP_BUILD}"   == "yes" ]]; then skips+=" build";   fi
  if [[ -n "${skips}" ]]; then echo "  Skipping:     ${skips}"; fi
  port_notes
  return 0
}
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1024 && $1 <= 65535 )); }
ask_val(){ # $1 prompt  $2 default  -> echoes answer (default if empty)
  local v; read -r -p "    $1 [$2]: " v </dev/tty || true; echo "${v:-$2}"
}
customise(){
  echo
  echo -e "  ${B}Customise${N}  (press Enter to keep any default)"
  local v
  v="$(ask_val "Model server port" "${PORT_LLAMA}")"
  if valid_port "${v}"; then PORT_LLAMA="${v}"; else warn "Invalid port; keeping ${PORT_LLAMA}."; fi
  v="$(ask_val "Odysseus port" "${PORT_ODY}")"
  if valid_port "${v}"; then [[ "${v}" == "${PORT_LLAMA}" ]] && warn "Same as the model server; keeping ${PORT_ODY}." || PORT_ODY="${v}"
  else warn "Invalid port; keeping ${PORT_ODY}."; fi
  v="$(ask_val "Context window (tokens, min 2048)" "${CTX}")"
  if [[ "${v}" =~ ^[0-9]+$ ]] && (( v >= 2048 )); then CTX="${v}"; else warn "Invalid context; keeping ${CTX}."; fi
  v="$(ask_val "Model tier: express / full / none" "${TIER}")"; TIER="${v,,}"; recompute_models
  v="$(ask_val "Install Odysseus workspace? y/n" "$( [[ ${WANT_ODY} == yes ]] && echo y || echo n )")"
  [[ "${v,,}" == "n" || "${v,,}" == "no" ]] && WANT_ODY="no" || WANT_ODY="yes"
  if [[ "${VENDOR}" != "cpu" ]]; then
    v="$(ask_val "Install LACT (GPU power/fan tuning GUI)? y/n" "$( [[ ${WANT_LACT} == yes ]] && echo y || echo n )")"
    [[ "${v,,}" == "n" || "${v,,}" == "no" ]] && WANT_LACT="no" || WANT_LACT="yes"
  fi
  v="$(ask_val "Enable the basic firewall? y/n" "$( [[ ${SKIP_FW} == yes ]] && echo n || echo y )")"
  [[ "${v,,}" == "n" || "${v,,}" == "no" ]] && SKIP_FW="yes" || SKIP_FW="no"
}
show_plan
if [[ "${YES}" != "yes" ]]; then
  while true; do
    echo
    echo "  [Enter] run with this plan    [c] customise values    [s] skip phases    [q] quit"
    read -r -p "  Your choice: " choice </dev/tty || true
    case "${choice,,}" in
      # Check the disk while the menu that can fix it is still open, rather
      # than refusing after it has closed and telling you to pick another tier.
      "") if preflight_disk; then break; fi
          info "Press 'c' for a smaller model tier, 's' to skip the download, or 'q' to quit.";;
      q|quit) die "Cancelled. Nothing changed.";;
      c) customise; show_plan;;
      s)
        echo "    Skippable: 1) system upgrade  2) GPU drivers  3) engine build"
        echo "               4) models          5) Odysseus     6) firewall     7) LACT"
        read -r -p "    Numbers to skip (e.g. '1 3'): " a </dev/tty || true
        for tok in ${a}; do case "${tok}" in
          1) SKIP_UPGRADE="yes";;
          2) SKIP_DRIVERS="yes";;
          3) SKIP_BUILD="yes";;
          4) TIER="none"; recompute_models;;
          5) WANT_ODY="no";;
          6) SKIP_FW="yes";;
          7) WANT_LACT="no";;
          *) warn "Ignoring unknown phase '${tok}'";;
        esac; done
        show_plan;;
      *) warn "Unrecognised choice '${choice}'.";;
    esac
  done
fi

# Under -y the menu above never ran, so this is the first and only chance to
# refuse before the upgrade, the drivers and the build have changed anything.
preflight_disk || die "Stopping before anything on this machine was changed."

# ======================================================================== 1 ==
step "1/9  System packages"
export DEBIAN_FRONTEND=noninteractive
# A failing refresh must not end the run. `apt-get update` exits non-zero if ANY
# configured repository fails, and a third-party repo with a missing or expired
# signing key is very common: editors, Docker, Spotify, old PPAs. None of that
# affects whether the packages below can be installed from the lists already on
# disk. This used to be a bare call, so with `set -e` one unrelated broken repo
# ended the install at the very first step with "Stopped at line 580", which
# tells a first-time user nothing about the cause or the cure. The `apt upgrade`
# below was already tolerant, which is the greater risk of the two.
APT_OUT=""
APT_UPDATE_OK="yes"
APT_OUT="$(apt-get update -qq 2>&1)" || APT_UPDATE_OK="no"
if [[ -n "${APT_OUT}" ]]; then
  while IFS= read -r _l; do [[ -n "${_l}" ]] && info "${_l}"; done \
    < <(grep -E '^[WE]:' <<<"${APT_OUT}" | head -8 || true)
fi
if [[ "${APT_UPDATE_OK}" == "no" ]]; then
  warn "Refreshing the package lists reported a problem, shown above."
  info "That is an existing apt setting on this machine, not something PatterOS changed."
  info "It is nearly always a third-party repository whose signing key has expired or"
  info "is missing. It does not stop the install: we continue with the lists already"
  info "on disk. If one of the packages below turns out to be unavailable, fix or"
  info "remove that repository and run this again."
fi
if [[ "${SKIP_UPGRADE}" == "yes" ]]; then
  info "Skipping 'apt upgrade' (--skip-upgrade / chosen at the prompt). Lists were still refreshed."
else
  apt-get upgrade -y -qq || warn "System upgrade had issues; continuing."
  # Watchdog: an upgrade can replace NVIDIA driver files underneath the loaded
  # module. If the driver was healthy before this run and isn't now, ONE reboot
  # fixes it, and phase 2 must NOT reinstall on top.
  if [[ "${VENDOR}" == "nvidia" && "${NV_BEFORE}" == "ok" ]] && [[ "$(nvidia_state)" != "ok" ]]; then
    NEED_REBOOT="yes"
    warn "The system upgrade replaced NVIDIA driver files; the loaded driver no longer matches."
    info "Nothing is broken, one reboot reloads it. Phase 2 will leave the driver alone."
  fi
fi
BASE_PKGS=(
  build-essential cmake git curl wget ca-certificates pkg-config
  libcurl4-openssl-dev libssl-dev python3-pip python3-venv python3-dev
  pciutils tmux ufw
  libvulkan-dev glslc spirv-headers vulkan-tools mesa-vulkan-drivers
)
# Note what is missing first: after apt has run, "installed" no longer
# distinguishes what we added from what was already here.
mapfile -t _base_new < <(pkgs_absent "${BASE_PKGS[@]}")
apt-get install -y -qq "${BASE_PKGS[@]}" \
  || die "Could not install the base packages. Check apt/network and re-run."
(( ${#_base_new[@]} )) && record_pkgs "${_base_new[@]}"
good "Base tools and Vulkan libraries installed."

# ======================================================================== 2 ==
step "2/9  GPU drivers / toolchains"
# CUDA build tools (not the driver): install only what's missing.
ensure_cuda_toolkit(){
  local need=()
  command -v nvcc   >/dev/null 2>&1 || need+=(nvidia-cuda-toolkit)
  command -v g++-12 >/dev/null 2>&1 || need+=(gcc-12 g++-12)
  if (( ${#need[@]} )); then
    info "Installing build tools: ${need[*]}"
    apt-get install -y -qq "${need[@]}" || warn "Some CUDA packages failed; the build may fall back to CPU."
    record_pkgs "${need[@]}"
  else
    info "CUDA toolkit and compiler already present."
  fi
}
secureboot_hint(){
  if command -v mokutil >/dev/null 2>&1 && grep -qi 'enabled' <<<"$(mokutil --sb-state 2>/dev/null || true)"; then
    warn "Secure Boot is ENABLED. If the GPU is still missing AFTER the reboot, Secure Boot is"
    warn "blocking the driver module: complete the blue MOK enrolment screen during boot, or"
    warn "disable Secure Boot in the BIOS, then reboot again."
  fi
}
offer_reboot(){
  if [[ "${YES}" != "yes" ]]; then
    read -r -p "    Reboot now, then re-run this script (recommended)? [y/N]: " a </dev/tty || true
    if [[ "${a,,}" == "y" || "${a,,}" == "yes" ]]; then
      info "After the reboot, run it again:  sudo bash install_local_ai.sh"
      info "It will see the healthy driver, leave it alone, and reuse anything already finished."
      sleep 3; systemctl reboot; exit 0
    fi
  fi
}
if [[ "${SKIP_DRIVERS}" == "yes" ]]; then
  info "Skipping the driver phase entirely (--skip-drivers / chosen at the prompt)."
elif [[ "${VENDOR}" == "nvidia" ]]; then
  NV_STATE="$(nvidia_state)"
  case "${NV_STATE}" in
    ok)
      gpuname="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
      good "NVIDIA driver is loaded and healthy${gpuname:+ (${gpuname})}, leaving it completely alone."
      ensure_cuda_toolkit
      ;;
    mismatch)
      NEED_REBOOT="yes"
      warn "Driver/library version mismatch: newer driver files on disk than the module in memory."
      info "Classic post-upgrade state. The fix is ONE reboot; reinstalling makes it worse, so the"
      info "driver will not be touched. The build continues and the GPU returns after the reboot."
      ensure_cuda_toolkit
      offer_reboot
      ;;
    notloaded)
      NEED_REBOOT="yes"
      info "NVIDIA driver is installed but not loaded yet (normal before the first reboot)."
      info "Not reinstalling, the files are already in place."
      ensure_cuda_toolkit
      secureboot_hint
      offer_reboot
      ;;
    missing|broken)
      info "No working NVIDIA driver found (state: ${NV_STATE}), installing driver + CUDA toolchain."
      info "The driver only becomes active after a reboot, that's expected."
      # ubuntu-drivers picks the packages, so the only way to know what it added
      # is to look before and after. Without this the uninstaller's --drivers
      # had no choice but to guess by wildcard, and guessed far too widely.
      _drv_before="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-*' 'libnvidia-*' 'cuda-*' 2>/dev/null | awk '$1 ~ /^ii/{print $2}' | sort -u || true)"
      pkg_installed ubuntu-drivers-common || _udc_new="ubuntu-drivers-common"
      apt-get install -y -qq ubuntu-drivers-common || true
      command -v ubuntu-drivers >/dev/null 2>&1 && { ubuntu-drivers autoinstall || warn "ubuntu-drivers reported an issue; continuing."; }
      _drv_after="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-*' 'libnvidia-*' 'cuda-*' 2>/dev/null | awk '$1 ~ /^ii/{print $2}' | sort -u || true)"
      mapfile -t _drv_new < <(comm -13 <(printf '%s\n' "${_drv_before}") <(printf '%s\n' "${_drv_after}") | sed '/^$/d')
      (( ${#_drv_new[@]} )) && record_pkgs "${_drv_new[@]}"
      [[ -n "${_udc_new:-}" ]] && record_pkgs "${_udc_new}"
      ensure_cuda_toolkit
      if [[ "$(nvidia_state)" == "ok" ]]; then
        info "Driver loaded without a reboot, rare, but lovely."
      else
        NEED_REBOOT="yes"
        warn "The NVIDIA driver only loads after a reboot."
        secureboot_hint
        offer_reboot
        info "Continuing without the driver: the engine is built for all GPU types and works after your later reboot."
      fi
      ;;
  esac
else
  info "No vendor toolkit needed: Vulkan (installed in step 1) drives AMD and Intel; CPU needs nothing extra."
  vulkan_health
  # Vulkan from a systemd service needs the render/video groups; fix quietly if missing.
  if [[ "${VENDOR}" == "amd" || "${VENDOR}" == "intel" ]]; then
    for grp in render video; do
      if getent group "${grp}" >/dev/null 2>&1 && ! grep -qw -- "${grp}" <<<"$(id -nG "${REAL_USER}" 2>/dev/null || true)"; then
        if usermod -aG "${grp}" "${REAL_USER}"; then
          info "Added ${REAL_USER} to the '${grp}' group (GPU access for services)."
          # Record it so the uninstaller can put this back exactly as it was.
          # Without this it cannot tell a group WE added from one the user was
          # already in, and removing the wrong one breaks their GPU access.
          mkdir -p "${STAMP_DIR}"
          printf '%s %s\n' "${REAL_USER}" "${grp}" >> "${STAMP_DIR}/groups-added"
        fi
      fi
    done
  fi
fi
good "Drivers / toolchains ready."

# ======================================================================== 3 ==
step "3/9  Building llama.cpp (${LLAMA_VERSION})"
info "Compiling the inference engine from source, the slow part (a few minutes)."
if [[ ! -d "${LLAMA_DIR}/.git" ]]; then
  if [[ "${LLAMA_VERSION}" == "master" ]]; then as_user git clone --depth 1 "${LLAMA_REPO}" "${LLAMA_DIR}"
  else as_user git clone --depth 1 --branch "${LLAMA_VERSION}" "${LLAMA_REPO}" "${LLAMA_DIR}" \
        || { warn "Tag ${LLAMA_VERSION} not found; using master."; as_user git clone --depth 1 "${LLAMA_REPO}" "${LLAMA_DIR}"; }; fi
else
  # "Reusing it" must not quietly mean "at some other version". This directory
  # can predate this run in two ways: an earlier install pinned a different tag,
  # or the user cloned llama.cpp themselves by following the manual guide, which
  # leaves them on master. Either way the header above names LLAMA_VERSION, so
  # building whatever happens to be on disk would be a lie, and it would defeat
  # the pin: before b9702 the router accepted -ngl and -c and then discarded
  # them, which presents as a perfectly healthy service running entirely on the
  # CPU. That is close to undiagnosable for a first-time user, so it is worth
  # the extra care here.
  info "llama.cpp already cloned; reusing it."
  at="$(as_user git -C "${LLAMA_DIR}" describe --tags --exact-match HEAD 2>/dev/null || true)"
  if [[ "${LLAMA_VERSION}" != "master" && "${at}" != "${LLAMA_VERSION}" ]]; then
    if [[ -n "$(as_user git -C "${LLAMA_DIR}" status --porcelain 2>/dev/null || true)" ]]; then
      warn "It is at ${at:-an untagged commit}, not the pinned ${LLAMA_VERSION}, and it has uncommitted"
      warn "changes. It has been left exactly as it is, so that is what will be built."
      info "For the pinned version, move ${LLAMA_DIR} aside and run this again."
    else
      info "It is at ${at:-an untagged commit}, so switching it to ${LLAMA_VERSION}."
      if as_user git -C "${LLAMA_DIR}" fetch -q --depth 1 origin "refs/tags/${LLAMA_VERSION}:refs/tags/${LLAMA_VERSION}" 2>/dev/null \
         && as_user git -C "${LLAMA_DIR}" checkout -q "${LLAMA_VERSION}" 2>/dev/null; then
        good "Source is now at ${LLAMA_VERSION}."
        REBUILD="yes"   # the source moved, so anything already compiled is stale
      else
        warn "Could not switch to ${LLAMA_VERSION}, so ${at:-the current commit} is what will be built."
        info "Use LLAMA_VERSION=master to track the tip on purpose, or move ${LLAMA_DIR} aside for a clean clone."
      fi
    fi
  fi
fi

ENGINE_REBUILT="no"            # did we actually produce a new llama-server?
LLAMA_STOPPED_FOR_BUILD="no"   # did we stop a running service to do it?

# How many compilers to run at once. Not simply nproc: a CUDA translation unit
# in llama.cpp can hold well over 2 GB, so on a 16-thread machine with 16 GB the
# honest answer is not 16. Exceeding memory here does not fail cleanly, it takes
# the desktop with it, and the machines most likely to hit it are the budget
# builds this project is aimed at. Allow ~2 GB per job of what is actually
# available, keep at least one, and say so when the cap bites.
build_jobs(){
  local cores mem_kb jobs
  cores="$(nproc 2>/dev/null || echo 1)"
  if [[ -n "${JOBS_OVERRIDE}" ]]; then
    if [[ "${JOBS_OVERRIDE}" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s\n' "${JOBS_OVERRIDE}"; return
    fi
    warn "Ignoring JOBS='${JOBS_OVERRIDE}': it must be a whole number of 1 or more."
  fi
  mem_kb="$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null || true)"
  [[ "${mem_kb}" =~ ^[0-9]+$ ]] || { printf '%s\n' "${cores}"; return; }
  jobs=$(( mem_kb / 1024 / 1024 / 2 ))
  (( jobs < 1 ))     && jobs=1
  (( jobs > cores )) && jobs="${cores}"
  printf '%s\n' "${jobs}"
}

build(){ # $@ = extra cmake flags ; builds into build/ and checks the binary exists
  local jobs cores; jobs="$(build_jobs)"; cores="$(nproc 2>/dev/null || echo "${jobs}")"
  if [[ -n "${JOBS_OVERRIDE}" && "${jobs}" == "${JOBS_OVERRIDE}" ]]; then
    info "Compiling with ${jobs} parallel jobs, from JOBS in the environment."
  elif [[ "${jobs}" != "${cores}" ]]; then
    info "Compiling with ${jobs} of your ${cores} cores, to stay inside available memory."
    info "Slower, and much safer than running out of memory mid-build. Override with JOBS=<n>."
  fi
  # Stop the service before the build directory goes, for two reasons. Deleting
  # the binary out from under a running llama-server leaves it serving from a
  # file that no longer exists, and if systemd restarts it during the build it
  # fails on a missing executable. It is brought back up in phase 5.
  if [[ -d "${LLAMA_DIR}/build" ]] && systemctl is-active --quiet llama.service 2>/dev/null; then
    info "Stopping llama.service while the engine rebuilds."
    systemctl stop llama.service >/dev/null 2>&1 || true
    LLAMA_STOPPED_FOR_BUILD="yes"
  fi
  as_user rm -rf "${LLAMA_DIR}/build"
  as_user cmake -S "${LLAMA_DIR}" -B "${LLAMA_DIR}/build" -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON "$@" \
    && as_user cmake --build "${LLAMA_DIR}/build" --config Release -j"${jobs}" \
    && [[ -x "${LLAMA_DIR}/build/bin/llama-server" ]] \
    && ENGINE_REBUILT="yes"
}
# What we'd build for THIS machine today
DESIRED="cpu"
if   [[ "${VENDOR}" == "nvidia" ]] && command -v nvcc >/dev/null 2>&1; then DESIRED="cuda"
elif [[ "${VENDOR}" == "amd" || "${VENDOR}" == "intel" ]]; then DESIRED="vulkan"; fi
MARKER="${LLAMA_DIR}/build/.patteros_backend"
BUILT=""
EXISTING=""; [[ -x "${LLAMA_DIR}/build/bin/llama-server" && -f "${MARKER}" ]] && EXISTING="$(cut -d' ' -f1 "${MARKER}" 2>/dev/null || true)"
if [[ "${REBUILD}" != "yes" && -n "${EXISTING}" && "${EXISTING}" == "${DESIRED}" ]]; then
  BUILT="${EXISTING}"
  good "Engine already built (${BUILT}), reusing it. Use --rebuild to force a fresh build."
  if grep -q 'all-major' "${MARKER}" 2>/dev/null && [[ "$(nvidia_state)" == "ok" ]]; then
    info "(It was built generically pre-reboot; '--rebuild' would optimise for your exact card. Optional.)"
  fi
elif [[ "${REBUILD}" != "yes" && "${SKIP_BUILD}" == "yes" && -n "${EXISTING}" ]]; then
  BUILT="${EXISTING}"
  warn "Reusing the existing ${BUILT} build (--skip-build), though ${DESIRED} is what this machine wants."
elif [[ -n "${EXISTING}" && "${EXISTING}" != "${DESIRED}" ]]; then
  info "Existing build is ${EXISTING} but this machine now wants ${DESIRED}, rebuilding."
fi
if [[ -z "${BUILT}" ]] && [[ "${VENDOR}" == "nvidia" ]] && command -v nvcc >/dev/null 2>&1; then
  archs="all-major"   # works even before the driver loads
  if command -v nvidia-smi >/dev/null 2>&1; then
    cc="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | tr -d ' .' | sort -u | paste -sd';' - || true)"; [[ -n "${cc}" ]] && archs="${cc}"
  fi
  # An array, not a string: an unquoted string would word-split (shellcheck
  # SC2086) and quoting it would hand cmake an empty argument when g++-12 is
  # absent. An empty array simply expands to nothing.
  hostcxx=(); command -v g++-12 >/dev/null 2>&1 && hostcxx=(-DCMAKE_CUDA_HOST_COMPILER="$(command -v g++-12)")
  info "Building the CUDA engine (arch ${archs})..."
  if build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="${archs}" ${hostcxx[@]+"${hostcxx[@]}"}; then BUILT="cuda"; else warn "CUDA build failed; falling back to CPU."; fi
elif [[ -z "${BUILT}" ]] && [[ "${VENDOR}" == "amd" || "${VENDOR}" == "intel" ]]; then
  info "Building the Vulkan engine (universal GPU backend)..."
  if build -DGGML_VULKAN=ON; then BUILT="vulkan"; else warn "Vulkan build failed; falling back to CPU."; fi
fi
if [[ -z "${BUILT}" ]]; then
  info "Building the CPU engine..."
  if ! build; then
    # If we stopped a working server to make room for this build, say so. The
    # binary went with the build directory, so it cannot simply be started again.
    if [[ "${LLAMA_STOPPED_FOR_BUILD}" == "yes" ]]; then
      warn "llama.service was stopped for this rebuild and cannot start again until a build succeeds."
      warn "Nothing else has been touched: your models and settings are where they were."
    fi
    die "Even the CPU build failed. Scroll up for the compiler error."
  fi
  BUILT="cpu"
fi
# Record what we built so re-runs can reuse it intelligently (skip if unchanged reuse)
if [[ "${EXISTING}" != "${BUILT}" || "${REBUILD}" == "yes" || ! -f "${MARKER}" ]]; then
  printf '%s %s\n' "${BUILT}" "${archs:-}" | as_user tee "${MARKER}" >/dev/null 2>&1 || true
fi
good "Engine built (${BUILT})."

# vulkan_health ran in the driver step against VENDOR. Under --cpu that is
# cpu, so VK_ENV stayed empty. If the engine we are actually going to run is
# still vulkan (the --skip-build reuse path), fill the workarounds now or the
# unit rewrite drops them from a working AMD/Intel service.
if [[ "${BUILT}" == "vulkan" && ${#VK_ENV[@]} -eq 0 ]]; then
  if [[ "${DETECTED_VENDOR}" == "amd" || "${DETECTED_VENDOR}" == "intel" ]]; then
    VENDOR="${DETECTED_VENDOR}"
    vulkan_health
    [[ "${FORCE_CPU}" == "yes" ]] && VENDOR="cpu"
  fi
fi

# --models-max 1 keeps ONE model resident at a time. This applies to every
# build, including CPU.
#
# It used to be 0 on the CPU path, on the assumption that 0 was the more
# restrictive setting. It is the opposite. From llama.cpp's own common/arg.cpp:
#     "maximum number of models to load simultaneously (default: 4, 0 = unlimited)"
# and three places in tools/server/server-models.cpp treat <= 0 as no limit,
# disabling the capacity check, the LRU eviction and the idle queue. Since -c
# applies per model and each model is a separate child process, 0 meant
# unbounded memory growth, on the CPU-only machines least able to survive it.
MODELS_MAX=1

# GPU offload. 999 means "put the whole model on the card". That is right when
# the model fits and wrong when it does not: the budget build in Part 1 pairs
# an 8 GB card with a --full tier whose largest model is ~18 GB, which would
# simply run out of memory. So when we can see both numbers and the model is
# bigger than the card, offload a proportion of the layers instead and let the
# rest run from system RAM. Slower, but it runs, and 1 token/s beats 0.
if [[ "${BUILT}" == "cuda" || "${BUILT}" == "vulkan" ]]; then
  NGL=999
  _vram="$(vram_gb)"; _largest="$(models_largest_gb)"
  if [[ -n "${_vram}" ]] && (( _largest > 0 && _largest > _vram )); then
    # Leave ~1 GB for the desktop, then scale layers by the fraction that fits.
    NGL=$(( ( (_vram > 1 ? _vram - 1 : 1) * 60 ) / _largest ))
    (( NGL < 4 ))  && NGL=4
    (( NGL > 999 )) && NGL=999
    info "Your card has ${_vram} GB and the biggest model is about ${_largest} GB,"
    info "so ${NGL} layers will run on the GPU and the rest from system memory."
    info "Override any time with:  sudo NGL=<number> bash install_local_ai.sh"
  fi
else
  NGL=0
fi
# An explicit NGL=... from the environment always wins.
if [[ -n "${NGL_OVERRIDE}" ]]; then
  if [[ "${NGL_OVERRIDE}" =~ ^[0-9]+$ ]]; then
    NGL="${NGL_OVERRIDE}"; info "Using GPU layers from the environment: -ngl ${NGL}"
  else
    warn "Ignoring NGL='${NGL_OVERRIDE}': it must be a whole number."
  fi
fi

# ======================================================================== 4 ==
step "4/9  Downloading models into ${MODELS_DIR}"
as_user mkdir -p "${MODELS_DIR}"
if (( ${#MODEL_SET[@]} > 0 )); then
  # Asked again, because the engine build since the plan has taken disk of its
  # own, and this is the number that decides whether the download completes.
  preflight_disk || die "Stopping before anything was downloaded."
  preflight_vram
  # --no-warn-script-location silences three paragraphs of pip warnings about
  # ~/.local/bin not being on PATH. They are alarming to read, they arrive right
  # after the longest wait so far, and they describe something this script
  # already handles: hf_user puts that directory on PATH for the commands below.
  as_user python3 -m pip install -q --user --break-system-packages \
    --no-warn-script-location -U huggingface_hub \
    || die "Could not install the Hugging Face downloader."

  # Newer huggingface_hub ships 'hf'; older installs only have 'huggingface-cli'.
  # Pick whichever exists rather than assuming, because a missing command here
  # looks like a network failure to anyone reading the output.
  HF_CMD=""
  if hf_user sh -c 'command -v hf'             >/dev/null 2>&1; then HF_CMD="hf"
  elif hf_user sh -c 'command -v huggingface-cli' >/dev/null 2>&1; then HF_CMD="huggingface-cli"
  else die "Neither 'hf' nor 'huggingface-cli' is available after installing huggingface_hub."; fi
  info "Using the '${HF_CMD}' downloader."

  DL_OK=0; DL_FAIL=0
  for entry in "${MODEL_SET[@]}"; do
    repo="${entry%%|*}"; rest="${entry#*|}"; glob="${rest%%|*}"; want_gb="${entry##*|}"
    info "Fetching ${repo}  (${glob}, about ${want_gb} GB)"
    if ! hf_user "${HF_CMD}" download "${repo}" --include "${glob}" --local-dir "${MODELS_DIR}"; then
      warn "Download failed for ${repo}. It resumes, so re-running this script will pick it up."
      DL_FAIL=$((DL_FAIL+1)); continue
    fi
    # Trust nothing: confirm a file actually landed and is a plausible size.
    # A truncated or zero-byte file otherwise fails much later, at load time,
    # where the error makes no sense to a beginner.
    # Look for the file THIS repo just produced, not merely something matching
    # the quantisation pattern. ~/models holds every model you have ever
    # downloaded, and they all match a glob like *UD-Q4_K_XL*.gguf, so a bare
    # glob can pick up a different model entirely. When it picked a smaller one
    # the size check below then failed and reported a perfectly good download as
    # incomplete. Hugging Face names the file after the repo, so anchoring on
    # the repo name makes the match specific.
    base="$(basename "${repo}")"; base="${base%-GGUF}"
    got="$(as_user find "${MODELS_DIR}" -maxdepth 2 -name "${base}${glob}" -size +100M 2>/dev/null | head -1 || true)"
    # Fall back to the plain glob for any repo that does not follow that naming.
    [[ -n "${got}" ]] || got="$(as_user find "${MODELS_DIR}" -maxdepth 2 -name "${glob##*/}" -size +100M 2>/dev/null | head -1 || true)"
    if [[ -z "${got}" ]]; then
      warn "${repo} reported success but no file matching ${glob} of a sensible size is in ${MODELS_DIR}."
      DL_FAIL=$((DL_FAIL+1)); continue
    fi
    got_gb="$(as_user du -m "${got}" 2>/dev/null | awk '{printf "%.1f", $1/1024}')"
    if awk -v g="${got_gb}" -v w="${want_gb}" 'BEGIN{exit !(g < w*0.7)}'; then
      warn "$(basename "${got}") is ${got_gb} GB but about ${want_gb} GB was expected. It may be incomplete."
      info "Re-running this script will resume the download."
      DL_FAIL=$((DL_FAIL+1)); continue
    fi
    good "$(basename "${got}")  (${got_gb} GB)"
    DL_OK=$((DL_OK+1))
  done

  if (( DL_OK == 0 )); then
    warn "No models were downloaded successfully. The server will start but will have nothing to serve."
    info "Re-run this script when your connection is happier; downloads resume where they stopped."
  elif (( DL_FAIL > 0 )); then
    warn "${DL_OK} model(s) downloaded, ${DL_FAIL} did not. Re-run to retry just the missing ones."
  else
    good "All ${DL_OK} model(s) downloaded into ${MODELS_DIR}."
  fi
else
  info "Skipping downloads (--no-models). Add GGUF files to ${MODELS_DIR} any time."
fi

# Write a systemd unit WITHOUT destroying changes the user made by hand.
#
# The manual guide tells people to edit these units (Step 10 adds --api-key and
# --host 0.0.0.0, Step 11 does the same for Odysseus), while this script's own
# banner promises that re-running is safe. Both cannot be true if we overwrite
# unconditionally, and silently deleting someone's API key is a nasty surprise.
#
# So: we record a checksum of every unit we write. On a later run, if the file
# on disk still matches that checksum, it is ours and we update it freely. If
# it does not, the user changed it, and we keep their version.
#   $1 = unit name   $2 = desired content

# Set by install_unit: "yes" when the file on disk actually changed. The caller
# needs this because `systemctl start` is a no-op on a running service, so a
# service whose unit we just rewrote keeps running with its OLD command line
# until something restarts it. Without this the installer would report the new
# port or context window while the old one was still in effect.
UNIT_WROTE="no"

install_unit(){
  local unit="$1" content="$2" path="/etc/systemd/system/$1" stamp="${STAMP_DIR}/$1.sha" now ours=""
  mkdir -p "${STAMP_DIR}"
  now="$(printf '%s' "${content}" | sha256sum | awk '{print $1}')"
  UNIT_WROTE="no"

  if [[ ! -f "${path}" ]]; then
    printf '%s' "${content}" > "${path}"; printf '%s\n' "${now}" > "${stamp}"
    UNIT_WROTE="yes"
    return 0
  fi

  local disk; disk="$(sha256sum "${path}" | awk '{print $1}')"
  [[ "${disk}" == "${now}" ]] && { info "${unit} is already exactly as we want it."; printf '%s\n' "${now}" > "${stamp}"; return 0; }
  [[ -f "${stamp}" ]] && [[ "${disk}" == "$(cat "${stamp}")" ]] && ours="yes"

  if [[ "${ours}" == "yes" ]]; then
    printf '%s' "${content}" > "${path}"; printf '%s\n' "${now}" > "${stamp}"
    UNIT_WROTE="yes"
    info "Updated ${unit}."
    return 0
  fi

  # Not ours. Someone edited it, most likely by following the guide.
  local backup="${path}.patteros-backup"
  cp -p "${path}" "${backup}" 2>/dev/null || true
  warn "${unit} has been edited since PatterOS wrote it (or was not written by us)."
  info "Your version has been left running, and copied to ${backup}."
  info "That is deliberate: if you followed the guide and added an API key or"
  info "changed the address it listens on, we are not going to throw that away."
  local a="n"
  if [[ "${REPLACE_UNITS}" == "yes" ]]; then
    a="y"
  elif [[ "${YES}" != "yes" ]]; then
    read -r -p "    Replace it with the standard PatterOS version anyway? [y/N]: " a </dev/tty || true
  else
    info "(-y given, so your version is kept. Use --replace-units to overwrite.)"
  fi
  if [[ "${a,,}" == "y" || "${a,,}" == "yes" ]]; then
    printf '%s' "${content}" > "${path}"; printf '%s\n' "${now}" > "${stamp}"
    UNIT_WROTE="yes"
    info "Replaced ${unit}. The previous version is still at ${backup}."
  else
    info "Keeping your ${unit} unchanged."
  fi
  return 0
}

# ======================================================================== 5 ==
step "5/9  llama.cpp router service (port ${PORT_LLAMA})"
LLAMA_UNIT="$(cat <<EOF
[Unit]
Description=Local AI (llama.cpp router)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
User=${REAL_USER}
WorkingDirectory=${LLAMA_DIR}
$(printf '%s\n' ${VK_ENV[@]+"${VK_ENV[@]}"})
ExecStart=${LLAMA_DIR}/build/bin/llama-server \\
  --models-dir ${MODELS_DIR} \\
  --host 127.0.0.1 --port ${PORT_LLAMA} \\
  --models-max ${MODELS_MAX} -ngl ${NGL} -c ${CTX} --jinja
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
)"
install_unit llama.service "${LLAMA_UNIT}"
systemctl daemon-reload
systemctl enable llama.service >/dev/null 2>&1 || warn "Could not enable llama.service to start at boot."
# `start` is a no-op on a service that is already running, so on a re-run that
# changed the port or the context window the OLD process would keep serving with
# the OLD settings while everything here reported success. Restart when we have
# just rewritten the file, and when it is not running for any reason.
#
# A new engine needs the same treatment, and for a less obvious reason. On Linux
# a running process keeps its executable alive by inode, so after --rebuild the
# old llama-server carried on quite happily from a deleted file. Nothing looked
# wrong: the port answered, the summary named the new engine, and the machine
# went on running the old one until its next reboot.
if [[ "${UNIT_WROTE}" == "yes" || "${ENGINE_REBUILT}" == "yes" ]] \
   || ! systemctl is-active --quiet llama.service; then
  systemctl restart llama.service >/dev/null 2>&1 || true
  [[ "${ENGINE_REBUILT}" == "yes" ]] && info "Restarted llama.service so it runs the engine just built."
fi
good "Service installed and enabled on boot."

# Readiness check, deliberately not fatal: before the first NVIDIA reboot, or
# while a model loads, "not answering yet" is the correct state.
#
# Two traps to avoid. Blaming the NVIDIA driver for every failure sends people
# to debug the wrong thing, because a port clash looks identical from here. And
# an answer on the port is NOT proof of success: if another program owns the
# port, it answers, and we would report a healthy server that is not ours.
LLAMA_OK="no"
case "$(service_health llama.service "${PORT_LLAMA}" 20)" in
  serving)
    LLAMA_OK="yes"
    good "Server is answering on http://localhost:${PORT_LLAMA}/v1"
    ;;
  running)
    LLAMA_OK="yes"
    info "Server is up but not answering yet, normal while a model loads."
    ;;
  looping|dead)
    warn "llama.service is not running."
    _owner="$(port_owner "${PORT_LLAMA}")"
    if [[ -n "${_owner}" ]]; then
      warn "Port ${PORT_LLAMA} is held by ${_owner}, so the server could not bind to it."
      info "Stop that program, or re-run choosing another port, then: sudo systemctl restart llama.service"
    elif [[ "${NEED_REBOOT}" == "yes" ]]; then
      info "Expected right now: the NVIDIA driver needs that reboot first. It will start afterwards."
    else
      service_why llama.service
    fi
    ;;
esac

# ======================================================================== 6 ==
ODY_PW=""; ODY_PW_SET="no"; ODY_PW_FILE=""; ODY_OK="no"; ODY_HAD_AUTH="no"
if [[ "${WANT_ODY}" == "yes" ]]; then
  step "6/9  Installing Odysseus (workspace, port ${PORT_ODY})"
  info "Odysseus is a separate open-source project (AGPL-3.0), not part of PatterOS."
  info "Source: ${ODY_REPO}"
  info "Pinned to commit ${ODY_COMMIT:0:12} so everyone installs the same code."
  info "It includes an AI agent that can run commands and read files, so it is"
  info "kept on this computer only (127.0.0.1). Never expose it to the internet."
  if [[ ! -d "${ODY_DIR}/.git" ]]; then
    as_user git clone -b "${ODY_BRANCH}" "${ODY_REPO}" "${ODY_DIR}" \
      || die "Could not download Odysseus from ${ODY_REPO}."
  else info "Odysseus already cloned; reusing it."; fi
  # Pin. Upstream publishes no tags or releases, so a commit is the only thing
  # we can hold still. Without this, two people following the same guide a month
  # apart get different code and we cannot support either of them.
  if ! as_user git -C "${ODY_DIR}" checkout -q "${ODY_COMMIT}" 2>/dev/null; then
    as_user git -C "${ODY_DIR}" fetch -q --depth 50 origin "${ODY_BRANCH}" 2>/dev/null || true
    as_user git -C "${ODY_DIR}" checkout -q "${ODY_COMMIT}" 2>/dev/null \
      || warn "Could not check out the pinned commit; using whatever '${ODY_BRANCH}' currently points at."
  fi

  # Carry one upstream fix that has not reached the pinned branch.
  #
  # src/agent_loop.py annotates two helpers with dict[str, Any] but does not
  # import Any, so importing the module raises NameError and the workspace dies
  # on every start, for ever. Upstream fixed it on their dev branch in d96c7af,
  # "fix(agent): import Any for tool event helper", but it has never been merged
  # to main, and main is what a pinned install gets.
  #
  # The alternative to carrying it is a workspace that cannot start on any
  # machine. The check is narrow on purpose: it only fires when that exact
  # defect is present, so it becomes a no-op the moment upstream merges.
  _ody_al="${ODY_DIR}/src/agent_loop.py"
  if [[ -f "${_ody_al}" ]] \
     && grep -q 'dict\[str, Any\]' "${_ody_al}" \
     && ! grep -qE '^from typing import .*\bAny\b' "${_ody_al}"; then
    if as_user sed -i 's/^from typing import /from typing import Any, /' "${_ody_al}" \
       && grep -qE '^from typing import Any,' "${_ody_al}"; then
      info "Applied one upstream Odysseus fix (missing 'Any' import) that is not yet on ${ODY_BRANCH}."
    else
      warn "Could not apply the known Odysseus 'Any' import fix; the workspace may fail to start."
    fi
  fi

  as_user python3 -m venv "${ODY_DIR}/venv"
  info "Installing Odysseus dependencies. This can take several minutes and the terminal may look quiet."

  # Generate the first-run admin password ourselves rather than scraping it
  # from setup.py's output. Upstream branches on sys.stdin.isatty(): under this
  # script stdin IS a terminal, so it takes the interactive path, prompts with
  # getpass, and never prints the "Temporary password:" line the old grep
  # looked for. Setting the environment variable makes the first run
  # deterministic instead.
  #
  # It does NOT make a re-run deterministic, and that is the part that was
  # wrong. create_default_admin() in upstream's setup.py opens with
  #     if os.path.exists(auth_path): print("[skip] auth.json already exists"); return
  # before it reads either variable. So on every re-run the password below is
  # never applied to anything, and writing it to the first-login file replaced a
  # working credential with one that cannot log in. Anyone re-running the
  # installer to recover a lost password got a file that looked authoritative
  # and was fiction. Decide from the auth file, which is the same thing upstream
  # decides from.
  ODY_AUTH_FILE="${ODY_DIR}/data/auth.json"      # src/constants.py: DATA_DIR/auth.json
  ODY_HAD_AUTH="no"; [[ -f "${ODY_AUTH_FILE}" ]] && ODY_HAD_AUTH="yes"
  ODY_PW="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)"
  as_user env PATH="${LLAMA_DIR}/build/bin:${ODY_DIR}/venv/bin:${PATH}" \
    ODYSSEUS_ADMIN_USER="admin" ODYSSEUS_ADMIN_PASSWORD="${ODY_PW}" \
    bash -lc "cd '${ODY_DIR}' && ./venv/bin/pip install -q -r requirements.txt && ./venv/bin/python setup.py" \
    || die "Odysseus setup failed. See the output above."
  # Only claim a password if the account did not exist before and does now.
  if [[ "${ODY_HAD_AUTH}" == "no" && -f "${ODY_AUTH_FILE}" ]]; then
    ODY_PW_SET="yes"
  fi

  ODY_UNIT="$(cat <<EOF
[Unit]
Description=Odysseus AI workspace
After=network-online.target llama.service
Wants=network-online.target
# Give up after ten failed starts in five minutes. Without a limit, a workspace
# that cannot start retries every ten seconds forever, filling the journal and
# burning CPU on a machine whose owner has been told everything is fine.
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
User=${REAL_USER}
WorkingDirectory=${ODY_DIR}
Environment=PATH=${LLAMA_DIR}/build/bin:${ODY_DIR}/venv/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${ODY_DIR}/venv/bin/python -m uvicorn app:app --host 127.0.0.1 --port ${PORT_ODY}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
)"
  install_unit odysseus.service "${ODY_UNIT}"
  systemctl daemon-reload
  systemctl enable odysseus.service >/dev/null 2>&1 || warn "Could not enable odysseus.service to start at boot."
  # Same reasoning as llama.service: `start` would leave an already-running
  # Odysseus on the old port after a re-run that changed it.
  if [[ "${UNIT_WROTE}" == "yes" ]] || ! systemctl is-active --quiet odysseus.service; then
    systemctl restart odysseus.service >/dev/null 2>&1 || true
  fi
  # Odysseus imports a large dependency tree before it binds the port, so give
  # it appreciably longer than llama.cpp to come up on a cold start.
  info "Waiting for the workspace to start, this takes up to a minute the first time."
  case "$(service_health odysseus.service "${PORT_ODY}" 90)" in
    serving)
      ODY_OK="yes"
      good "Odysseus installed, enabled on boot, and answering on http://localhost:${PORT_ODY}"
      ;;
    running)
      ODY_OK="yes"
      good "Odysseus installed and enabled on boot."
      info "It has not answered on port ${PORT_ODY} yet; give it another minute, then reload the page."
      ;;
    looping)
      warn "Odysseus is installed, but it starts and then immediately exits, over and over."
      warn "This is a fault in the Odysseus application itself, not in your machine or"
      warn "your GPU. Everything else on this install is unaffected: the model server"
      warn "on port ${PORT_LLAMA} works, and you can use it from any app (guide, Step 10)."
      service_why odysseus.service
      info "Stop the retry loop with:  sudo systemctl disable --now odysseus.service"
      ;;
    dead)
      warn "Odysseus is installed and enabled, but it is not running."
      _ody_owner="$(port_owner "${PORT_ODY}")"
      if [[ -n "${_ody_owner}" ]]; then
        warn "Port ${PORT_ODY} is held by ${_ody_owner}, so Odysseus could not bind to it."
        info "Stop that program, or re-run choosing another port."
      else
        service_why odysseus.service
      fi
      ;;
  esac

  # Write the password to a root-only file instead of printing it. It ends up in
  # scrollback, in `script` logs and in anything recording the terminal
  # otherwise, and it unlocks an agent that can run commands on this machine.
  if [[ "${ODY_PW_SET}" == "yes" ]]; then
    ODY_PW_FILE="${STAMP_DIR}/odysseus-first-login.txt"
    mkdir -p "${STAMP_DIR}"
    printf 'Odysseus first login\n  URL:      http://localhost:%s\n  Username: admin\n  Password: %s\n\nChange this in Settings after you log in, then delete this file.\n' \
      "${PORT_ODY}" "${ODY_PW}" > "${ODY_PW_FILE}"
    chmod 600 "${ODY_PW_FILE}"
    info "First-run login for Odysseus has been saved to a root-only file."
    info "Read it with:  sudo cat ${ODY_PW_FILE}"
  elif [[ "${ODY_HAD_AUTH}" == "yes" ]]; then
    # Your account already existed, so this run did not set a password and must
    # not pretend it did. Point at the original file only if it is still there.
    info "Odysseus already had an admin account, so your existing login still applies."
    if [[ -f "${STAMP_DIR}/odysseus-first-login.txt" ]]; then
      ODY_PW_FILE="${STAMP_DIR}/odysseus-first-login.txt"
      info "The login saved by the first install is still at ${ODY_PW_FILE}."
    else
      info "If you have lost that password, delete ${ODY_AUTH_FILE} and re-run this"
      info "installer: Odysseus will then create a fresh admin account for you."
    fi
  fi
else
  step "6/9  Skipping Odysseus (not selected)"
fi

# ======================================================================== 7 ==
step "7/9  LACT, GPU power & fan tuning (optional)"
if [[ "${VENDOR}" == "cpu" ]]; then
  info "No GPU on this machine, nothing to tune. Skipping."
elif [[ "${WANT_LACT}" != "yes" ]]; then
  info "Skipping LACT (not selected). The manual route lives in the guide, Step 12."
elif pkg_installed lact; then
  good "LACT is already installed."
  systemctl enable --now lactd >/dev/null 2>&1 || true
else
  info "Installing LACT ${LACT_VER}, the GUI we use on every rig to cap power and tame fans."
  as_user mkdir -p "${USER_HOME}/Downloads"
  if as_user wget -q -O "${USER_HOME}/Downloads/lact.deb" "${LACT_DEB_URL}" \
     && apt-get install -y -qq "${USER_HOME}/Downloads/lact.deb"; then
    record_pkgs lact
    systemctl enable --now lactd >/dev/null 2>&1 || warn "lactd didn't start; settings won't apply until it does."
    good "LACT installed. Open it from your applications menu, the guide (Step 12) shows the two-minute setup."
  else
    warn "LACT install failed (network or packaging). No harm done, everything else is unaffected."
    warn "Easy fallbacks: Software Manager → search 'LACT', or the manual route in the guide, Step 12."
  fi
fi

# ======================================================================== 8 ==
step "8/9  Firewall (SSH first, so you can't lock yourself out)"
if [[ "${SKIP_FW}" == "yes" ]]; then
  info "Skipping firewall changes (--skip-firewall / chosen at the prompt)."
else
# Work out which port SSH is ACTUALLY on before turning the firewall on.
# The old code allowed the OpenSSH profile (port 22 by definition) and then
# force-enabled ufw. Anyone running sshd on a non-standard port was locked out
# of their own machine by the very step whose comment promises otherwise, and
# on a headless rig that means a physical trip to the box.
SSH_PORTS="$(sshd -T 2>/dev/null | awk '/^port /{print $2}' || true)"
if [[ -z "${SSH_PORTS}" ]] && [[ -r /etc/ssh/sshd_config ]]; then
  SSH_PORTS="$(awk '/^[[:space:]]*[Pp]ort[[:space:]]+[0-9]+/{print $2}' /etc/ssh/sshd_config || true)"
fi
if [[ -z "${SSH_PORTS}" ]] && command -v ss >/dev/null 2>&1; then
  SSH_PORTS="$(ss -lntp 2>/dev/null | awk '/sshd/{split($4,a,":"); print a[length(a)]}' | sort -u || true)"
fi

if [[ -n "${SSH_PORTS}" ]]; then
  for p in ${SSH_PORTS}; do
    [[ "${p}" =~ ^[0-9]+$ ]] || continue
    ufw allow "${p}/tcp" >/dev/null 2>&1 || true
    info "Allowed SSH on port ${p} before enabling the firewall."
  done
else
  # No SSH server found. Allow the standard port anyway: it costs nothing if
  # sshd is not installed, and it saves anyone who adds it later.
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
  info "No SSH server detected; allowed the standard port 22 just in case."
fi
ufw --force enable >/dev/null 2>&1 || true

# What the units on disk actually bind to. This used to be asserted rather than
# checked: the message said "listen on this computer only", which is true of the
# units we write and false of a unit we preserved. Steps 10 and 11 of the guide
# tell people to bind 0.0.0.0 for LAN or phone access, and install_unit keeps
# edited files on purpose, so a re-run met exactly that case and then enabled a
# firewall that blocked the port, silently, having just called it private.
LAN_UNITS=()
for _u in llama.service:"${PORT_LLAMA}" odysseus.service:"${PORT_ODY}"; do
  _f="/etc/systemd/system/${_u%%:*}"; _p="${_u##*:}"
  [[ -r "${_f}" ]] || continue
  grep -qE -- '--host[= ]+(0\.0\.0\.0|::|\*)' "${_f}" && LAN_UNITS+=("${_u%%:*}:${_p}")
done

if (( ${#LAN_UNITS[@]} == 0 )); then
  good "Firewall on. The model server and Odysseus listen on this computer only, private by default."
else
  good "Firewall on. Incoming connections are blocked except SSH."
  for _u in "${LAN_UNITS[@]}"; do
    _n="${_u%%:*}"; _p="${_u##*:}"
    warn "${_n} is set to listen on your whole network (--host 0.0.0.0), but port ${_p} is now blocked."
    info "That was your edit, so it is left alone. To reach it from other devices:"
    info "    sudo ufw allow ${_p}/tcp"
    info "Only do that on a network you trust, and read the guide's Step $([[ "${_n}" == odysseus.service ]] && echo 11 || echo 10) first."
  done
fi
info "Phone access to Odysseus:           guide, Step 11  (allow ${PORT_ODY}/tcp + bind 0.0.0.0)"
info "Other apps/machines (Cursor etc.):  guide, Step 10  (allow ${PORT_LLAMA}/tcp + --api-key)"
fi

# ======================================================================== 9 ==
step "9/9  Done"
PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"; [[ -n "${PRIMARY_IP}" ]] || PRIMARY_IP="<this-machine-ip>"
apt-get autoremove -y -qq >/dev/null 2>&1 || true
echo -e "${OK}${B}"
echo "=============================================================="
echo "   Local AI is set up."
echo -e "==============================================================${N}"
GPU_VERDICT="CPU only (by design)"
if [[ "${BUILT}" == "cuda" ]]; then
  case "$(nvidia_state)" in
    ok) GPU_VERDICT="CUDA, driver healthy, GPU active" ;;
    mismatch|notloaded) GPU_VERDICT="CUDA built, GPU returns after ONE reboot (do not reinstall drivers)" ;;
    *) GPU_VERDICT="CUDA built, driver not working; see the phase 2 notes above" ;;
  esac
elif [[ "${BUILT}" == "vulkan" ]]; then
  if grep -q deviceName <<<"$(vulkaninfo --summary 2>/dev/null || true)"; then GPU_VERDICT="Vulkan, GPU visible and active"
  else GPU_VERDICT="Vulkan built, GPU not visible yet (groups fixed this run; restart the service or reboot)"; fi
fi
if [[ "${LLAMA_OK}" == "yes" ]]; then
  echo "  Model server:  http://localhost:${PORT_LLAMA}/v1   (engine: ${BUILT})"
else
  echo "  Model server:  NOT RUNNING (see the phase 5 notes above)   (engine: ${BUILT})"
fi
echo "  GPU status:    ${GPU_VERDICT}"
if [[ "${WANT_ODY}" == "yes" ]]; then
  if [[ "${ODY_OK}" == "yes" ]]; then
    echo "  Workspace:     http://localhost:${PORT_ODY}            (log in as 'admin')"
    [[ -n "${ODY_PW_FILE}" ]] && echo "  Admin login:   sudo cat ${ODY_PW_FILE}   (username 'admin')"
  else
    # Never print a URL for something we have just watched fail. The summary is
    # the one part everybody reads, so it has to agree with reality.
    echo "  Workspace:     NOT RUNNING (see the phase 6 notes above)"
    echo "                 Your model server above is fine and usable on its own."
  fi
fi
echo "  Models dir:    ${MODELS_DIR}"
echo "  Connect apps:  base URL http://localhost:${PORT_LLAMA}/v1, any API key  (guide Step 10 for other machines)"
echo
echo "  See models:        curl http://localhost:${PORT_LLAMA}/v1/models"
echo "  Switch model:      use a different model id in your request (loads live)"
echo "  Add a model:       hf download <repo> --include '*.gguf' --local-dir ${MODELS_DIR}"
echo "                     then: curl 'http://localhost:${PORT_LLAMA}/v1/models?reload=1'"
# pip put hf in ~/.local/bin. Mint and Ubuntu add that to PATH from ~/.profile,
# which is only read at login, so the command above is genuinely not found in
# the terminal the installer was just run from. Saying so costs one line and
# saves a "you told me to run a command that does not exist" moment.
echo "                     ('hf' lives in ~/.local/bin, so open a new terminal first)"
echo "  Restart server:    sudo systemctl restart llama.service"
# The password is in the root-only file above and is deliberately never printed,
# so this line points at the log only.
[[ "${WANT_ODY}" == "yes" ]] && echo "  Odysseus log:      sudo journalctl -u odysseus -e"
echo
if [[ "${NEED_REBOOT}" == "yes" ]]; then
  echo -e "${WN}  Reboot once so the NVIDIA driver loads:  sudo reboot${N}"
  echo    "  After the reboot the model server starts automatically with GPU offload."
fi
if [[ "${VENDOR}" != "cpu" ]]; then
  if pkg_installed lact; then
    echo "  LACT:          installed, open it from your menu and set a power cap (guide, Step 12)."
  else
    echo "  LACT:          not installed, Software Manager or the guide, Step 12, when you want it."
  fi
fi
