#!/usr/bin/env bash
# =============================================================================
#  PatterOS · Local AI Budget Build — Part 2 companion installer
#  setup_local_ai.sh  (v1.3)
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
#       swapping, no restart) — listening on localhost only, private by default
#    7. Install Odysseus (the web workspace) and run it as a service
#    8. Turn on the firewall (SSH allowed first, so you can't lock yourself out)
#
#  This is the SIMPLE sibling of the full PatterOS install.sh: one model server,
#  one workspace, no multi-GPU endpoints or extra tooling. The heavy PatterOS
#  provisioning lives in the main install.sh.
#
#  USAGE
#     less setup_local_ai.sh           # read it first — never blind-run a script
#     sudo bash setup_local_ai.sh      # interactive
#     sudo bash setup_local_ai.sh -y   # no prompts (express models)
#
#  FLAGS
#     --full           Also download bigger models (needs a 24 GB card + disk).
#     --no-models      Don't download anything (you'll add models later).
#     --no-odysseus    Inference server only; skip the Odysseus workspace.
#     --cpu            Force CPU-only (ignore any GPU).
#     --skip-upgrade   Don't run 'apt upgrade' (apt update still refreshes lists).
#     --skip-drivers   Don't touch GPU drivers or toolchains at all.
#     --skip-build     Reuse an existing llama.cpp build if one is present.
#     --rebuild        Force a fresh llama.cpp build even if one exists.
#     --skip-firewall  Don't enable or modify ufw.
#     --lact           Install LACT (GPU power/fan tuning GUI). Default on GPU rigs.
#     --no-lact        Skip LACT.
#     -y, --yes        Assume yes; don't prompt. Implies you've already read this
#                      script — the habit below still applies!
#     -h, --help       Show this help.
#
#  Re-running is safe AND smart: a healthy NVIDIA driver is never reinstalled,
#  a finished build is reused, and the interactive menu lets you skip phases
#  or customise ports, context size, model tier, LACT and the firewall.
#
#  FIRST, A HABIT WORTH KEEPING: never run a script from the internet (ours
#  included) without looking inside it. The comments explain every phase:
#      less setup_local_ai.sh        (press q to quit the viewer)
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
# All entries are q4-class on purpose: a model either fits in memory or it
# does not, and q4 is what makes these fit on a real budget card.
EXPRESS_MODELS=(
  "unsloth/gemma-4-E2B-it-GGUF|*UD-Q4_K_XL*.gguf|3.2"    # tiny, runs anywhere
  "unsloth/gemma-4-E4B-it-GGUF|*UD-Q4_K_XL*.gguf|5.2"    # small but capable
)
FULL_MODELS=(
  "unsloth/gemma-4-12b-it-GGUF|*UD-Q4_K_XL*.gguf|7.4"    # strong mid-size all-rounder
  "unsloth/gemma-4-31B-it-GGUF|*UD-Q4_K_XL*.gguf|18.9"   # top quality on a 24 GB card
)

# ----- args -----------------------------------------------------------------
TIER="express"; WANT_MODELS="yes"; WANT_ODY="yes"; FORCE_CPU="no"
SKIP_UPGRADE="no"; SKIP_DRIVERS="no"; SKIP_BUILD="no"; REBUILD="no"; SKIP_FW="no"; YES="no"
REPLACE_UNITS="no"   # overwrite systemd units even if they were edited by hand
WANT_LACT="ask"      # ask = yes on GPU rigs unless changed at the menu
show_help(){ sed -n '2,51p' "$0" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do case "$1" in
  --full)        TIER="full";;
  --no-models)   WANT_MODELS="no";;
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
[[ ${EUID} -eq 0 ]] || die "Run with sudo:  sudo bash setup_local_ai.sh"
REAL_USER="${SUDO_USER:-}"
[[ -n "${REAL_USER}" && "${REAL_USER}" != "root" ]] || die "Run via sudo as your normal user:  sudo bash setup_local_ai.sh"
USER_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
[[ -d "${USER_HOME}" ]] || die "Could not find the home directory for ${REAL_USER}."
as_user(){ sudo -u "${REAL_USER}" -H "$@"; }     # run a command as the real user
hf_user(){ as_user env PATH="${USER_HOME}/.local/bin:${PATH}" "$@"; }

MODELS_DIR="${USER_HOME}/models"
LLAMA_DIR="${USER_HOME}/llama.cpp"
ODY_DIR="${USER_HOME}/odysseus"

echo -e "${C}${B}"
echo "  ============================================================"
echo "     PatterOS  —  Local AI Budget Build"
echo "     Part 2 companion installer  ·  v1.3"
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
echo "  Never run a script from the internet — ours included — without looking inside"
echo "  it first. You don't need to be a programmer: open it with the command below,"
echo "  and the plain-English comments will walk you through every phase."
echo
echo -e "      ${C}less setup_local_ai.sh${N}        (arrow keys to scroll, q to quit)"
echo
if [[ "${YES}" != "yes" ]]; then
  read -r -p "  Happy you know what this script does, and ready to go? [y/N]: " a </dev/tty || true
  if [[ "${a,,}" != "y" && "${a,,}" != "yes" ]]; then
    echo
    info "No problem at all — have a read and come back whenever. It'll be here."
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
vram_gb(){
  local mb=""
  if command -v nvidia-smi >/dev/null 2>&1 && [[ "$(nvidia_state)" == "ok" ]]; then
    mb="$(LC_ALL=C nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | sort -rn | head -1 || true)"
  fi
  if [[ -z "${mb}" ]] && command -v glxinfo >/dev/null 2>&1; then
    mb="$(LC_ALL=C glxinfo -B 2>/dev/null | awk -F': *' '/Video memory/{gsub(/MB.*/,"",$2); print $2+0; exit}' || true)"
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
  drv="$(awk -F'= *' '/driverName/{print $2; exit}' <<<"${summary}" | tr -d ' ' || true)"
  if [[ "${drv}" == *"amdvlk"* || "${drv}" == *"AMDVLK"* ]]; then
    warn "Your system is using the AMDVLK Vulkan driver."
    info "AMD no longer supports it and recommends RADV, which is the one built into Linux."
    info "If models run slowly, removing the amdvlk package usually fixes it."
  fi

  # --- Mesa version ---
  mesa="$(awk -F'Mesa ' '/driverInfo|Mesa/{print $2; exit}' <<<"${summary}" | awk '{print $1}' || true)"
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
VENDOR="cpu"
if [[ "${FORCE_CPU}" != "yes" ]]; then
  ids="$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | grep -oE '\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]' | tr -d '[]' | cut -d: -f1 | tr 'A-F' 'a-f' || true)"
  if   grep -q '10de' <<<"${ids}"; then VENDOR="nvidia"
  elif grep -q '1002' <<<"${ids}"; then VENDOR="amd"
  elif grep -q '8086' <<<"${ids}"; then VENDOR="intel"; fi
fi
NEED_REBOOT="no"
NV_BEFORE="n/a"; [[ "${VENDOR}" == "nvidia" ]] && NV_BEFORE="$(nvidia_state)"
case "${VENDOR}" in
  nvidia) info "Found an NVIDIA GPU  → Path A (CUDA, fastest)   [driver: ${NV_BEFORE}]";;
  amd)    info "Found an AMD GPU    → Path B (Vulkan, universal)";;
  intel)  info "Found an Intel GPU  → Path B (Vulkan, universal)";;
  cpu)    info "No GPU detected (or --cpu) → Path C (CPU only). 1 tok/s beats 0.";;
esac

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

# Tell the user BEFORE downloading tens of gigabytes whether this will fit.
# Refuses on disk (a hard failure), warns on VRAM (partial offload still works,
# it is just slower, and 1 token/s beats 0).
preflight_models(){
  (( ${#MODEL_SET[@]} > 0 )) || return 0
  local need free vram largest
  need="$(models_total_gb)"; largest="$(models_largest_gb)"
  free="$(free_gb "${USER_HOME}")"; vram="$(vram_gb)"

  if [[ -n "${free}" ]] && (( free < need + 5 )); then
    warn "Not enough disk space for the '${TIER}' model set."
    info "It needs about ${need} GB, plus a few GB of headroom. You have ${free} GB free in ${USER_HOME}."
    info "Options: choose the 'express' tier, free up some space, or re-run with --no-models"
    info "and add models later into ${MODELS_DIR}."
    die "Stopping before anything was downloaded."
  fi

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
  [[ "${SKIP_UPGRADE}" == "yes" ]] && skips+=" upgrade" || true
  [[ "${SKIP_DRIVERS}" == "yes" ]] && skips+=" drivers" || true
  [[ "${SKIP_BUILD}"   == "yes" ]] && skips+=" build"   || true
  if [[ -n "${skips}" ]]; then echo "  Skipping:     ${skips}"; fi
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
      "") break;;
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

# ======================================================================== 1 ==
step "1/9  System packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
if [[ "${SKIP_UPGRADE}" == "yes" ]]; then
  info "Skipping 'apt upgrade' (--skip-upgrade / chosen at the prompt). Lists were still refreshed."
else
  apt-get upgrade -y -qq || warn "System upgrade had issues; continuing."
  # Watchdog: an upgrade can replace NVIDIA driver files underneath the loaded
  # module. If the driver was healthy before this run and isn't now, ONE reboot
  # fixes it — and phase 2 must NOT reinstall on top.
  if [[ "${VENDOR}" == "nvidia" && "${NV_BEFORE}" == "ok" ]] && [[ "$(nvidia_state)" != "ok" ]]; then
    NEED_REBOOT="yes"
    warn "The system upgrade replaced NVIDIA driver files; the loaded driver no longer matches."
    info "Nothing is broken — one reboot reloads it. Phase 2 will leave the driver alone."
  fi
fi
apt-get install -y -qq \
  build-essential cmake git curl wget ca-certificates pkg-config \
  libcurl4-openssl-dev libssl-dev python3-pip python3-venv python3-dev \
  pciutils tmux ufw \
  libvulkan-dev glslc spirv-headers vulkan-tools mesa-vulkan-drivers \
  || die "Could not install the base packages. Check apt/network and re-run."
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
  else
    info "CUDA toolkit and compiler already present."
  fi
}
secureboot_hint(){
  if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    warn "Secure Boot is ENABLED. If the GPU is still missing AFTER the reboot, Secure Boot is"
    warn "blocking the driver module: complete the blue MOK enrolment screen during boot, or"
    warn "disable Secure Boot in the BIOS, then reboot again."
  fi
}
offer_reboot(){
  if [[ "${YES}" != "yes" ]]; then
    read -r -p "    Reboot now, then re-run this script (recommended)? [y/N]: " a </dev/tty || true
    if [[ "${a,,}" == "y" || "${a,,}" == "yes" ]]; then
      info "After the reboot, run it again:  sudo bash setup_local_ai.sh"
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
      good "NVIDIA driver is loaded and healthy${gpuname:+ (${gpuname})} — leaving it completely alone."
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
      info "Not reinstalling — the files are already in place."
      ensure_cuda_toolkit
      secureboot_hint
      offer_reboot
      ;;
    missing|broken)
      info "No working NVIDIA driver found (state: ${NV_STATE}) — installing driver + CUDA toolchain."
      info "The driver only becomes active after a reboot — that's expected."
      apt-get install -y -qq ubuntu-drivers-common || true
      command -v ubuntu-drivers >/dev/null 2>&1 && { ubuntu-drivers autoinstall || warn "ubuntu-drivers reported an issue; continuing."; }
      ensure_cuda_toolkit
      if [[ "$(nvidia_state)" == "ok" ]]; then
        info "Driver loaded without a reboot — rare, but lovely."
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
      if getent group "${grp}" >/dev/null 2>&1 && ! id -nG "${REAL_USER}" 2>/dev/null | grep -qw "${grp}"; then
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
info "Compiling the inference engine from source — the slow part (a few minutes)."
if [[ ! -d "${LLAMA_DIR}/.git" ]]; then
  if [[ "${LLAMA_VERSION}" == "master" ]]; then as_user git clone --depth 1 "${LLAMA_REPO}" "${LLAMA_DIR}"
  else as_user git clone --depth 1 --branch "${LLAMA_VERSION}" "${LLAMA_REPO}" "${LLAMA_DIR}" \
        || { warn "Tag ${LLAMA_VERSION} not found; using master."; as_user git clone --depth 1 "${LLAMA_REPO}" "${LLAMA_DIR}"; }; fi
else info "llama.cpp already cloned; reusing it."; fi

build(){ # $@ = extra cmake flags ; builds into build/ and checks the binary exists
  as_user rm -rf "${LLAMA_DIR}/build"
  as_user cmake -S "${LLAMA_DIR}" -B "${LLAMA_DIR}/build" -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON "$@" \
    && as_user cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)" \
    && [[ -x "${LLAMA_DIR}/build/bin/llama-server" ]]
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
  good "Engine already built (${BUILT}) — reusing it. Use --rebuild to force a fresh build."
  if grep -q 'all-major' "${MARKER}" 2>/dev/null && [[ "$(nvidia_state)" == "ok" ]]; then
    info "(It was built generically pre-reboot; '--rebuild' would optimise for your exact card. Optional.)"
  fi
elif [[ "${REBUILD}" != "yes" && "${SKIP_BUILD}" == "yes" && -n "${EXISTING}" ]]; then
  BUILT="${EXISTING}"
  warn "Reusing the existing ${BUILT} build (--skip-build), though ${DESIRED} is what this machine wants."
elif [[ -n "${EXISTING}" && "${EXISTING}" != "${DESIRED}" ]]; then
  info "Existing build is ${EXISTING} but this machine now wants ${DESIRED} — rebuilding."
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
  build || die "Even the CPU build failed. Scroll up for the compiler error."
  BUILT="cpu"
fi
# Record what we built so re-runs can reuse it intelligently (skip if unchanged reuse)
if [[ "${EXISTING}" != "${BUILT}" || "${REBUILD}" == "yes" || ! -f "${MARKER}" ]]; then
  printf '%s %s\n' "${BUILT}" "${archs:-}" | as_user tee "${MARKER}" >/dev/null 2>&1 || true
fi
good "Engine built (${BUILT})."

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
# an 8 GB card with a --full tier whose largest model is ~19 GB, which would
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
  preflight_models
  as_user python3 -m pip install -q --user --break-system-packages -U huggingface_hub \
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
    got="$(as_user find "${MODELS_DIR}" -maxdepth 2 -name "${glob##*/}" -size +100M 2>/dev/null | head -1 || true)"
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
install_unit(){
  local unit="$1" content="$2" path="/etc/systemd/system/$1" stamp="${STAMP_DIR}/$1.sha" now ours=""
  mkdir -p "${STAMP_DIR}"
  now="$(printf '%s' "${content}" | sha256sum | awk '{print $1}')"

  if [[ ! -f "${path}" ]]; then
    printf '%s' "${content}" > "${path}"; printf '%s\n' "${now}" > "${stamp}"
    return 0
  fi

  local disk; disk="$(sha256sum "${path}" | awk '{print $1}')"
  [[ "${disk}" == "${now}" ]] && { info "${unit} is already exactly as we want it."; printf '%s\n' "${now}" > "${stamp}"; return 0; }
  [[ -f "${stamp}" ]] && [[ "${disk}" == "$(cat "${stamp}")" ]] && ours="yes"

  if [[ "${ours}" == "yes" ]]; then
    printf '%s' "${content}" > "${path}"; printf '%s\n' "${now}" > "${stamp}"
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
  if [[ "${YES}" != "yes" ]]; then
    read -r -p "    Replace it with the standard PatterOS version anyway? [y/N]: " a </dev/tty || true
  else
    info "(-y given, so your version is kept. Use --replace-units to overwrite.)"
  fi
  if [[ "${REPLACE_UNITS}" == "yes" || "${a,,}" == "y" || "${a,,}" == "yes" ]]; then
    printf '%s' "${content}" > "${path}"; printf '%s\n' "${now}" > "${stamp}"
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
systemctl enable --now llama.service >/dev/null 2>&1 || warn "Service didn't start yet (NVIDIA usually needs the reboot for its driver)."
good "Service installed and enabled on boot."

# quick readiness check (don't fail the install if it's still loading / pre-reboot)
sleep 3
if curl -fsS "http://127.0.0.1:${PORT_LLAMA}/v1/models" >/dev/null 2>&1; then good "Server is answering on http://localhost:${PORT_LLAMA}/v1"
else info "Server not answering yet — normal if a model is loading, or before the NVIDIA reboot."; fi

# ======================================================================== 6 ==
ODY_PW=""; ODY_PW_SET="no"; ODY_PW_FILE=""
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

  as_user python3 -m venv "${ODY_DIR}/venv"
  info "Installing Odysseus dependencies. This can take several minutes and the terminal may look quiet."

  # Generate the first-run admin password ourselves rather than scraping it
  # from setup.py's output. Upstream branches on sys.stdin.isatty(): under this
  # script stdin IS a terminal, so it takes the interactive path, prompts with
  # getpass, and never prints the "Temporary password:" line the old grep
  # looked for. On a re-run it prints "[skip] auth.json already exists" and
  # returns early, so there is no password line then either. Setting the
  # environment variable makes the behaviour deterministic in both cases.
  ODY_PW="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)"
  as_user env PATH="${LLAMA_DIR}/build/bin:${ODY_DIR}/venv/bin:${PATH}" \
    ODYSSEUS_ADMIN_USER="admin" ODYSSEUS_ADMIN_PASSWORD="${ODY_PW}" \
    bash -lc "cd '${ODY_DIR}' && ./venv/bin/pip install -q -r requirements.txt && ./venv/bin/python setup.py" \
    || die "Odysseus setup failed. See the output above."
  ODY_PW_SET="yes"

  ODY_UNIT="$(cat <<EOF
[Unit]
Description=Odysseus AI workspace
After=network-online.target llama.service
Wants=network-online.target

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
  systemctl enable --now odysseus.service >/dev/null 2>&1 || warn "Odysseus service didn't start; check: journalctl -u odysseus -e"
  good "Odysseus installed and enabled on boot."

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
  fi
else
  step "6/9  Skipping Odysseus (not selected)"
fi

# ======================================================================== 7 ==
step "7/9  LACT — GPU power & fan tuning (optional)"
if [[ "${VENDOR}" == "cpu" ]]; then
  info "No GPU on this machine — nothing to tune. Skipping."
elif [[ "${WANT_LACT}" != "yes" ]]; then
  info "Skipping LACT (not selected). The manual route lives in the guide, Step 12."
elif dpkg -l lact 2>/dev/null | grep -q '^ii'; then
  good "LACT is already installed."
  systemctl enable --now lactd >/dev/null 2>&1 || true
else
  info "Installing LACT ${LACT_VER} — the GUI we use on every rig to cap power and tame fans."
  as_user mkdir -p "${USER_HOME}/Downloads"
  if as_user wget -q -O "${USER_HOME}/Downloads/lact.deb" "${LACT_DEB_URL}" \
     && apt-get install -y -qq "${USER_HOME}/Downloads/lact.deb"; then
    systemctl enable --now lactd >/dev/null 2>&1 || warn "lactd didn't start; settings won't apply until it does."
    good "LACT installed. Open it from your applications menu — the guide (Step 12) shows the two-minute setup."
  else
    warn "LACT install failed (network or packaging). No harm done — everything else is unaffected."
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
good "Firewall on. The model server and Odysseus listen on this computer only, private by default."
info "Phone access to Odysseus:           guide, Step 11  (allow ${PORT_ODY}/tcp + bind 0.0.0.0)"
info "Other apps/machines (Cursor etc.):  guide, Step 10  (allow ${PORT_LLAMA}/tcp + --api-key)"
fi

# ======================================================================== 8 ==
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
    ok) GPU_VERDICT="CUDA — driver healthy, GPU active" ;;
    mismatch|notloaded) GPU_VERDICT="CUDA built — GPU returns after ONE reboot (do not reinstall drivers)" ;;
    *) GPU_VERDICT="CUDA built — driver not working; see the phase 2 notes above" ;;
  esac
elif [[ "${BUILT}" == "vulkan" ]]; then
  if vulkaninfo --summary 2>/dev/null | grep -q deviceName; then GPU_VERDICT="Vulkan — GPU visible and active"
  else GPU_VERDICT="Vulkan built — GPU not visible yet (groups fixed this run; restart the service or reboot)"; fi
fi
echo "  Model server:  http://localhost:${PORT_LLAMA}/v1   (engine: ${BUILT})"
echo "  GPU status:    ${GPU_VERDICT}"
[[ "${WANT_ODY}" == "yes" ]] && echo "  Workspace:     http://localhost:${PORT_ODY}            (log in as 'admin')"
[[ -n "${ODY_PW_FILE}" ]] && echo "  Admin login:   sudo cat ${ODY_PW_FILE}   (username 'admin')"
echo "  Models dir:    ${MODELS_DIR}"
echo "  Connect apps:  base URL http://localhost:${PORT_LLAMA}/v1, any API key  (guide Step 10 for other machines)"
echo
echo "  See models:        curl http://localhost:${PORT_LLAMA}/v1/models"
echo "  Switch model:      use a different model id in your request (loads live)"
echo "  Add a model:       hf download <repo> --include '*.gguf' --local-dir ${MODELS_DIR}"
echo "                     then: curl 'http://localhost:${PORT_LLAMA}/v1/models?reload=1'"
echo "  Restart server:    sudo systemctl restart llama.service"
[[ "${WANT_ODY}" == "yes" ]] && echo "  Odysseus log/pw:   sudo journalctl -u odysseus -e"
echo
if [[ "${NEED_REBOOT}" == "yes" ]]; then
  echo -e "${WN}  Reboot once so the NVIDIA driver loads:  sudo reboot${N}"
  echo    "  After the reboot the model server starts automatically with GPU offload."
fi
if [[ "${VENDOR}" != "cpu" ]]; then
  if dpkg -l lact 2>/dev/null | grep -q '^ii'; then
    echo "  LACT:          installed — open it from your menu and set a power cap (guide, Step 12)."
  else
    echo "  LACT:          not installed — Software Manager or the guide, Step 12, when you want it."
  fi
fi
