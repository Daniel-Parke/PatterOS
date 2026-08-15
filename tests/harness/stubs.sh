#!/usr/bin/env bash
# =============================================================================
#  Sandbox stubs for exercising install_local_ai.sh without touching a machine.
#
#  WHY
#  ---
#  The installer's whole job is to change a system: install drivers, compile
#  llama.cpp, download tens of gigabytes, write systemd units, enable a
#  firewall. None of that can run in CI, and running it for real to find out
#  whether the NVIDIA "driver mismatch" branch works would mean deliberately
#  breaking a driver.
#
#  So this puts fake versions of the external commands on PATH. The installer
#  itself is completely unmodified: it runs its real logic, takes its real
#  branches, and writes its real service files. Only the outside world is
#  pretend. Every stub logs what it was asked to do, so a test can assert on
#  the commands the installer WOULD have run.
#
#  Scenario is driven entirely by environment variables, so one harness covers
#  every hardware path:
#
#    STUB_GPU          nvidia | amd | intel | none      (what lspci reports)
#    STUB_NVIDIA       ok | mismatch | notloaded | missing | broken
#    STUB_VRAM_MB      total VRAM nvidia-smi reports
#    STUB_DISK_GB      free space df reports
#    STUB_SSH_PORT     port sshd -T reports
#    STUB_MESA         Mesa version vulkaninfo reports
#    STUB_ICD          radv | amdvlk
#    STUB_BAR_MB       largest prefetchable BAR lspci reports (ReBAR detection)
#    STUB_HAS_HF       1 = 'hf' exists, 0 = only 'huggingface-cli'
#    STUB_DL_FAIL      1 = model downloads fail
#    STUB_NO_NVCC      1 = nvcc absent, so the CUDA build is skipped
#
#  Everything the stubs are asked to do is appended to $STUB_LOG.
# =============================================================================
set -uo pipefail

STUB_DIR="${STUB_DIR:?STUB_DIR must be set}"
STUB_LOG="${STUB_LOG:?STUB_LOG must be set}"
mkdir -p "${STUB_DIR}"
: > "${STUB_LOG}"

_mk(){ # $1 = command name, stdin = body
  local p="${STUB_DIR}/$1"
  { echo '#!/usr/bin/env bash'
    echo "echo \"\$(basename \"\$0\") \$*\" >> '${STUB_LOG}'"
    cat
  } > "${p}"
  chmod +x "${p}"
}

# ----- package management ---------------------------------------------------
_mk apt-get <<'EOF'
exit 0
EOF
_mk dpkg <<'EOF'
# "nothing is installed" unless the test says otherwise
if [[ "${1:-}" == "-l" ]]; then exit 1; fi
exit 0
EOF
_mk dpkg-query <<'EOF'
case "$*" in
  *mesa-vulkan-drivers*) echo "${STUB_MESA:-25.2.8}-0ubuntu1";;
  *) exit 1;;
esac
EOF
_mk ubuntu-drivers <<'EOF'
exit 0
EOF
_mk mokutil <<'EOF'
echo "SecureBoot disabled"
EOF

# ----- hardware discovery ---------------------------------------------------
_mk lspci <<'EOF'
gpu="${STUB_GPU:-none}"
bar="${STUB_BAR_MB:-16384}"
if [[ "${1:-}" == "-v" ]]; then
  # Used for Resizable BAR detection.
  echo "01:00.0 VGA compatible controller: Test GPU"
  echo "	Memory at c0000000 (64-bit, prefetchable) [size=${bar}M]"
  exit 0
fi
case "${gpu}" in
  nvidia) echo "01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GA102 [GeForce RTX 3090 Ti] [10de:2203] (rev a1)";;
  amd)    echo "03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 31 [Radeon RX 7900 XTX] [1002:744c] (rev c8)";;
  intel)  echo "00:02.0 VGA compatible controller [0300]: Intel Corporation Arc A770 [8086:56a0] (rev 08)";;
  *)      : ;;   # no GPU line at all
esac
EOF

_mk nvidia-smi <<'EOF'
state="${STUB_NVIDIA:-ok}"
[[ "${state}" == "missing" ]] && exit 127
case "${state}" in
  mismatch)  echo "Failed to initialize NVML: Driver/library version mismatch" >&2; exit 1;;
  notloaded) echo "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver." >&2; exit 1;;
  broken)    echo "Unknown Error" >&2; exit 1;;
esac
for a in "$@"; do
  case "$a" in
    --query-gpu=name)          echo "NVIDIA GeForce RTX 3090 Ti"; exit 0;;
    --query-gpu=memory.total)  echo "${STUB_VRAM_MB:-24576}"; exit 0;;
    --query-gpu=compute_cap)   echo "8.6"; exit 0;;
  esac
done
echo "GPU 0: NVIDIA GeForce RTX 3090 Ti"
EOF

_mk vulkaninfo <<'EOF'
echo "deviceName = Test GPU"
echo "driverName = ${STUB_ICD:-radv}"
echo "driverInfo = Mesa ${STUB_MESA:-25.2.8}"
EOF

_mk df <<'EOF'
echo "Filesystem 1G-blocks Used Available Use% Mounted on"
echo "/dev/sda1 1000 100 ${STUB_DISK_GB:-500}G 20% /"
EOF

_mk free <<'EOF'
echo "MemTotal: 65536000 kB"
EOF

_mk sshd <<'EOF'
[[ "${1:-}" == "-T" ]] && echo "port ${STUB_SSH_PORT:-22}"
exit 0
EOF

_mk ss <<'EOF'
echo "LISTEN 0 128 0.0.0.0:${STUB_SSH_PORT:-22} 0.0.0.0:* users:((\"sshd\",pid=1,fd=3))"
EOF

# ----- build toolchain ------------------------------------------------------
_mk cmake <<'EOF'
# Pretend to build: create the binary the installer checks for.
for a in "$@"; do
  case "$a" in
    -B) next_is_build=1;;
    *) if [[ "${next_is_build:-}" == "1" ]]; then mkdir -p "$a/bin"; : > "$a/bin/llama-server"; chmod +x "$a/bin/llama-server"; next_is_build=""; fi;;
  esac
done
if [[ "${1:-}" == "--build" ]]; then mkdir -p "${2}/bin"; : > "${2}/bin/llama-server"; chmod +x "${2}/bin/llama-server"; fi
exit 0
EOF
_mk nproc <<'EOF'
echo 4
EOF
_mk nvcc <<'EOF'
echo "nvcc: NVIDIA (R) Cuda compiler"
EOF
_mk g++-12 <<'EOF'
echo "g++-12"
EOF

# ----- git ------------------------------------------------------------------
_mk git <<'EOF'
# Create the directory a clone would create, with a .git so re-runs detect it.
prev=""
for a in "$@"; do
  case "$a" in
    clone) is_clone=1;;
    -*) ;;
    *) last="$a";;
  esac
done
if [[ "${is_clone:-}" == "1" && -n "${last:-}" ]]; then
  mkdir -p "${last}/.git"
fi
exit 0
EOF

# ----- services and firewall ------------------------------------------------
_mk systemctl <<'EOF'
exit 0
EOF
_mk ufw <<'EOF'
exit 0
EOF
_mk usermod <<'EOF'
exit 0
EOF
_mk getent <<'EOF'
if [[ "${1:-}" == "passwd" ]]; then echo "${2}:x:1000:1000::/home/${2}:/bin/bash"; exit 0; fi
if [[ "${1:-}" == "group"  ]]; then echo "${2}:x:1000:"; exit 0; fi
exit 0
EOF

# ----- python and model download --------------------------------------------
_mk python3 <<'EOF'
# venv: make the layout the installer expects.
if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
  mkdir -p "${3}/bin"
  for b in pip python; do printf '#!/usr/bin/env bash\nexit 0\n' > "${3}/bin/$b"; chmod +x "${3}/bin/$b"; done
fi
exit 0
EOF
_mk hf <<'EOF'
[[ "${STUB_DL_FAIL:-0}" == "1" ]] && exit 1
# Write a plausible file matching the requested glob into the target dir.
repo=""; glob=""; dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --include)   glob="$2"; shift 2;;
    --local-dir) dir="$2";  shift 2;;
    download)    shift;;
    *) [[ -z "$repo" ]] && repo="$1"; shift;;
  esac
done
name="$(basename "${repo}" | sed 's/-GGUF$//')"
mkdir -p "${dir}"
# Just over the installer's 100M "is this a real file" floor. It does not need
# to be the true size: the `du` stub reports that separately, and writing
# 17 GB of zeros per scenario would make this suite unusable.
head -c 110000000 /dev/zero > "${dir}/${name}-UD-Q4_K_XL.gguf"
exit 0
EOF
_mk huggingface-cli <<'EOF'
exec "$(dirname "$0")/hf" "$@"
EOF
_mk curl <<'EOF'
exit 0
EOF
_mk wget <<'EOF'
for a in "$@"; do prev="${cur:-}"; cur="$a"; done
exit 0
EOF
_mk du <<'EOF'
# Report the size the installer expects, so the size sanity check passes.
f="${2:-${1:-}}"
if [[ -f "${f}" ]]; then
  case "${f}" in
    *E2B*) echo -e "2764\t${f}";; *E4B*) echo -e "4403\t${f}";;
    *12B*) echo -e "6963\t${f}";; *31B*) echo -e "17715\t${f}";;
    *) echo -e "3072\t${f}";;
  esac
else echo -e "0\t${f}"; fi
EOF
_mk tmux <<'EOF'
exit 0
EOF
_mk sudo <<'EOF'
# The installer uses `sudo -u user -H cmd`. Just run the command.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) shift 2;;
    -H) shift;;
    -*) shift;;
    *) break;;
  esac
done
exec "$@"
EOF
_mk sha256sum <<'EOF'
exec /usr/bin/sha256sum "$@"
EOF

# An older huggingface_hub ships only huggingface-cli. Remove `hf` entirely
# rather than making it fail: the installer detects with `command -v hf`, so a
# present-but-broken stub would be found and the fallback never tested.
if [[ "${STUB_HAS_HF:-1}" != "1" ]]; then
  mv -f "${STUB_DIR}/hf" "${STUB_DIR}/huggingface-cli"
fi

# Same reasoning for nvcc. The installer decides whether to attempt a CUDA
# build with `command -v nvcc`, which tests for the file, not for a working
# compiler. "No CUDA toolkit" therefore has to mean the command is genuinely
# absent, and the real nvcc must be masked too in case the image has one.
if [[ "${STUB_NO_NVCC:-0}" == "1" ]]; then
  rm -f "${STUB_DIR}/nvcc"
  printf '#!/usr/bin/env bash\nexit 127\n' > "${STUB_DIR}/nvcc.disabled"
fi

echo "stubs written to ${STUB_DIR}"
