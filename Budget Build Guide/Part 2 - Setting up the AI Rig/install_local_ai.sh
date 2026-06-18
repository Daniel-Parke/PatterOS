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
trap 'die "Error on line ${LINENO}. Nothing else was changed — fix the cause and re-run (it is safe to re-run)."' ERR

# ----- config (the few things we pin on purpose) ----------------------------
LLAMA_REPO="https://github.com/ggml-org/llama.cpp"
# Router mode (--models-dir) needs a build from Dec 2025 or newer, so we track
# the latest by default. Override with LLAMA_VERSION=<tag> for a pinned build.
LLAMA_VERSION="${LLAMA_VERSION:-master}"
PORT_LLAMA=8020          # the model server
PORT_ODY=7000            # the Odysseus workspace
CTX="${CTX:-16384}"      # context window per model (bounded to protect memory)
LACT_VER="0.9.0"         # GPU power/fan tuning GUI (guide, Step 12)
LACT_DEB_URL="https://github.com/ilya-zlobintsev/LACT/releases/download/v${LACT_VER}/lact-${LACT_VER}-0.amd64.ubuntu-2404.deb"

# Models: "HF repo | filename glob". Add a line to bless another model.
EXPRESS_MODELS=(
  "unsloth/gemma-4-E2B-it-GGUF|*UD-Q4_K_XL*.gguf"   # tiny, runs anywhere
  "unsloth/gemma-4-E4B-it-GGUF|*UD-Q4_K_XL*.gguf"   # small but capable
)
FULL_MODELS=(
  "unsloth/gemma-4-12b-it-GGUF|*UD-Q4_K_XL*.gguf"   # strong mid-size all-rounder
  "unsloth/gemma-4-31B-it-GGUF|*UD-Q4_K_XL*.gguf"   # top quality on a 24 GB card
)

# ----- args -----------------------------------------------------------------
TIER="express"; WANT_MODELS="yes"; WANT_ODY="yes"; FORCE_CPU="no"
SKIP_UPGRADE="no"; SKIP_DRIVERS="no"; SKIP_BUILD="no"; REBUILD="no"; SKIP_FW="no"; YES="no"
WANT_LACT="ask"   # ask = yes on GPU rigs unless changed at the menu"
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
nvidia_state(){
  command -v nvidia-smi >/dev/null 2>&1 || { echo missing; return 0; }
  local out="" rc=0
  out="$(nvidia-smi 2>&1)" || rc=$?
  if (( rc == 0 )); then echo ok
  elif grep -qi 'mismatch'    <<<"${out}"; then echo mismatch
  elif grep -qi 'communicate' <<<"${out}"; then echo notloaded
  else echo broken; fi
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

show_plan(){
  echo
  echo -e "${B}Plan${N}"
  echo "  GPU path:      ${VENDOR}"
  echo "  llama.cpp:     ${LLAMA_VERSION}  → router mode on port ${PORT_LLAMA}, context ${CTX}"
  echo "  Models dir:    ${MODELS_DIR}"
  if (( ${#MODEL_SET[@]} > 0 )); then echo "  Download:      ${#MODEL_SET[@]} model(s) — tier '${TIER}'"
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
  v="$(ask_val "Model server port" "${PORT_LLAMA}")"; valid_port "${v}" && PORT_LLAMA="${v}" || warn "Invalid port; keeping ${PORT_LLAMA}."
  v="$(ask_val "Odysseus port" "${PORT_ODY}")"
  if valid_port "${v}"; then [[ "${v}" == "${PORT_LLAMA}" ]] && warn "Same as the model server; keeping ${PORT_ODY}." || PORT_ODY="${v}"
  else warn "Invalid port; keeping ${PORT_ODY}."; fi
  v="$(ask_val "Context window (tokens, min 2048)" "${CTX}")"
  [[ "${v}" =~ ^[0-9]+$ ]] && (( v >= 2048 )) && CTX="${v}" || warn "Invalid context; keeping ${CTX}."
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
  info "No vendor toolkit needed — Vulkan (installed in step 1) drives AMD/Intel; CPU needs nothing extra."
  # Vulkan from a systemd service needs the render/video groups; fix quietly if missing.
  if [[ "${VENDOR}" == "amd" || "${VENDOR}" == "intel" ]]; then
    for grp in render video; do
      if getent group "${grp}" >/dev/null 2>&1 && ! id -nG "${REAL_USER}" 2>/dev/null | grep -qw "${grp}"; then
        usermod -aG "${grp}" "${REAL_USER}" && info "Added ${REAL_USER} to the '${grp}' group (GPU access for services)."
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
  hostcxx=""; command -v g++-12 >/dev/null 2>&1 && hostcxx="-DCMAKE_CUDA_HOST_COMPILER=$(command -v g++-12)"
  info "Building the CUDA engine (arch ${archs})..."
  if build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="${archs}" ${hostcxx}; then BUILT="cuda"; else warn "CUDA build failed; falling back to CPU."; fi
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

# GPU offload only when we built a GPU engine; --models-max 1 keeps one model
# resident at a time (safe on a single card; swapping evicts the old one).
if [[ "${BUILT}" == "cuda" || "${BUILT}" == "vulkan" ]]; then NGL=999; MODELS_MAX=1; else NGL=0; MODELS_MAX=0; fi

# ======================================================================== 4 ==
step "4/9  Downloading models into ${MODELS_DIR}"
as_user mkdir -p "${MODELS_DIR}"
if (( ${#MODEL_SET[@]} > 0 )); then
  as_user python3 -m pip install -q --user --break-system-packages -U huggingface_hub \
    || die "Could not install the Hugging Face downloader."
  for entry in "${MODEL_SET[@]}"; do
    repo="${entry%%|*}"; glob="${entry##*|}"
    info "Fetching ${repo}  (${glob})"
    hf_user hf download "${repo}" --include "${glob}" --local-dir "${MODELS_DIR}" \
      || warn "Download failed for ${repo}. Re-run later — it resumes."
  done
  good "Models in ${MODELS_DIR}: $(as_user find "${MODELS_DIR}" -maxdepth 2 -name '*.gguf' 2>/dev/null | wc -l) file(s)."
else
  info "Skipping downloads (--no-models). Add GGUF files to ${MODELS_DIR} any time."
fi

# ======================================================================== 5 ==
step "5/9  llama.cpp router service (port ${PORT_LLAMA})"
cat > /etc/systemd/system/llama.service <<EOF
[Unit]
Description=Local AI (llama.cpp router)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
User=${REAL_USER}
WorkingDirectory=${LLAMA_DIR}
ExecStart=${LLAMA_DIR}/build/bin/llama-server \\
  --models-dir ${MODELS_DIR} \\
  --host 127.0.0.1 --port ${PORT_LLAMA} \\
  --models-max ${MODELS_MAX} -ngl ${NGL} -c ${CTX} --jinja
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now llama.service >/dev/null 2>&1 || warn "Service didn't start yet (NVIDIA usually needs the reboot for its driver)."
good "Service installed and enabled on boot."

# quick readiness check (don't fail the install if it's still loading / pre-reboot)
sleep 3
if curl -fsS "http://127.0.0.1:${PORT_LLAMA}/v1/models" >/dev/null 2>&1; then good "Server is answering on http://localhost:${PORT_LLAMA}/v1"
else info "Server not answering yet — normal if a model is loading, or before the NVIDIA reboot."; fi

# ======================================================================== 6 ==
ODY_PW_LINE=""
if [[ "${WANT_ODY}" == "yes" ]]; then
  step "6/9  Installing Odysseus (workspace, port ${PORT_ODY})"
  if [[ ! -d "${ODY_DIR}/.git" ]]; then
    as_user git clone -b main https://github.com/pewdiepie-archdaemon/odysseus.git "${ODY_DIR}"
  else info "Odysseus already cloned; reusing it."; fi
  as_user python3 -m venv "${ODY_DIR}/venv"
  info "Installing Odysseus dependencies — this can take several minutes; the terminal may look quiet."
  # install deps and run setup with llama-server on PATH (so Cookbook can find it)
  ODY_LOG="$(mktemp)"
  as_user env PATH="${LLAMA_DIR}/build/bin:${ODY_DIR}/venv/bin:${PATH}" bash -lc \
    "cd '${ODY_DIR}' && ./venv/bin/pip install -q -r requirements.txt && ./venv/bin/python setup.py" 2>&1 \
    | tee "${ODY_LOG}" \
    || die "Odysseus setup failed. See the output above."
  ODY_PW_LINE="$(sed 's/\x1b\[[0-9;]*m//g' "${ODY_LOG}" | grep -i 'password' | tail -1 | sed 's/^[[:space:]]*//' || true)"
  rm -f "${ODY_LOG}"

  cat > /etc/systemd/system/odysseus.service <<EOF
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
  systemctl daemon-reload
  systemctl enable --now odysseus.service >/dev/null 2>&1 || warn "Odysseus service didn't start; check: journalctl -u odysseus -e"
  good "Odysseus installed and enabled on boot."
  info "First-run admin password (copy it):  sudo journalctl -u odysseus | grep -i password | tail -1"
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
ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true
good "Firewall on. The model server and Odysseus listen on localhost only — private by default."
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
[[ -n "${ODY_PW_LINE}" ]] && echo "  Admin login:   ${ODY_PW_LINE}"
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
