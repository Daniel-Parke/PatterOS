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
#    STUB_NVIDIA_AFTER_UPGRADE
#                      if set, nvidia-smi reports this state AFTER apt-get
#                      upgrade runs (the post-upgrade driver-file watchdog)
#    STUB_VRAM_MB      total VRAM nvidia-smi reports
#    STUB_DISK_GB      free space df reports
#    STUB_SSH_PORT     port sshd -T reports
#    STUB_MESA         Mesa version vulkaninfo reports
#    STUB_ICD          radv | amdvlk
#    STUB_BAR_MB       largest prefetchable BAR lspci reports (ReBAR detection)
#    STUB_HAS_HF       1 = 'hf' exists, 0 = only 'huggingface-cli'
#    STUB_DL_FAIL      1 = model downloads fail
#    STUB_NO_NVCC      1 = nvcc absent, so the CUDA build is skipped
#    STUB_INSTALLED    packages `dpkg -l` should report as installed (e.g. lact)
#    STUB_DPKG_BULK    1 = pad `dpkg -l` past a pipe buffer, as a real host does
#    STUB_DRIVER_ADDS  packages `ubuntu-drivers autoinstall` puts on the machine
#    STUB_MASK         commands to make genuinely absent from PATH
#    STUB_GIT_AT       tag an existing llama.cpp checkout reports for HEAD
#    STUB_GIT_DIRTY    1 = that checkout has uncommitted changes
#    STUB_GIT_FETCH_FAIL  1 = git fetch fails (e.g. the tag does not exist)
#    STUB_SVC_DEAD     units `systemctl is-active` should report as not running
#    STUB_SVC_LOOPING  units that start, die, and restart (a rising NRestarts)
#    STUB_CURL_FAIL    ports curl should fail against, i.e. nothing is answering
#    STUB_UFW_RULES    rules `ufw status` should report, as ufw stores them
#    STUB_UFW_DELETE_FAIL ports whose rules cannot be deleted
#    STUB_BUSY_PORTS   port:program pairs `ss` should report as already listening
#    STUB_UNIT_DIR     where units live, so `systemctl status` can say "no such unit"
#    STUB_APT_UPDATE_FAIL 1 = `apt-get update` fails, as with a broken third-party repo
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
# STUB_APT_UPDATE_FAIL models the very common case of a machine with one broken
# third-party repository: `apt-get update` prints a warning and exits non-zero,
# while every other apt operation is perfectly fine.
if [[ "${1:-}" == "update" && "${STUB_APT_UPDATE_FAIL:-0}" == "1" ]]; then
  echo "W: GPG error: https://example.com/aptrepo stable InRelease: NO_PUBKEY 42A1772E62E492D6" >&2
  echo "E: The repository 'https://example.com/aptrepo stable InRelease' is not signed." >&2
  exit 100
fi
# An apt upgrade can replace NVIDIA driver files under a still-loaded module.
# The installer snapshots nvidia_state before the upgrade and must then treat
# a newly-broken driver as "reboot, do not reinstall". Touching this marker
# lets nvidia-smi flip state only after upgrade has run.
if [[ "${1:-}" == "upgrade" && -n "${STUB_NVIDIA_AFTER_UPGRADE:-}" ]]; then
  : > "$(dirname "$0")/.nvidia-after-upgrade"
fi
# Installing makes a package installed, and purging makes it not. dpkg reads this
# file, so the installer's "was it absent before and present after" record has
# something real to measure. A local .deb path is skipped: apt takes the package
# name from inside the file, which a stub cannot know.
_state="$(dirname "$0")/.pkgs-installed"
case "${1:-}" in
  install)
    shift
    for a in "$@"; do
      [[ "${a}" == -* ]] && continue
      # A local .deb carries its package name inside it; take the filename,
      # which is how the LACT download is named.
      [[ "${a}" == *.deb ]] && a="$(basename "${a}" .deb)"
      [[ "${a}" == */* ]] && continue
      grep -qxF -- "${a}" "${_state}" 2>/dev/null || printf '%s\n' "${a}" >> "${_state}"
    done
    ;;
  purge|remove)
    shift
    for a in "$@"; do
      [[ "${a}" == -* ]] && continue
      [[ -f "${_state}" ]] && grep -vxF -- "${a}" "${_state}" > "${_state}.tmp" 2>/dev/null \
        && mv "${_state}.tmp" "${_state}"
    done
    ;;
esac
exit 0
EOF
_mk dpkg <<'EOF'
# "nothing is installed" unless the test says otherwise. STUB_INSTALLED holds a
# space-separated list of packages to report as present, in the "ii  name ver"
# form the installer greps for with '^ii'.
#
# Installing has to change what is installed. The installer now records which
# packages were absent before it ran and present after, so that the uninstaller
# removes what PatterOS added and nothing else; against a stub where apt-get was
# a no-op, that record would always come out empty and the tests would prove
# nothing. Both this and dpkg-query read the same two state files.
_added(){
  local d; d="$(dirname "$0")"
  cat "${d}/.pkgs-installed" "${d}/.pkgs-by-drivers" 2>/dev/null
}
STUB_INSTALLED="${STUB_INSTALLED:-} $(_added | tr '\n' ' ')"
if [[ "${1:-}" == "-l" ]]; then
  # A real `dpkg -l` prints a few hundred KB, far more than a 64 KB pipe can
  # hold, so a reader that stops early kills it with SIGPIPE. Under pipefail
  # that turns a successful match into a failed pipeline. A stub that printed
  # three tidy lines could never reproduce that, and it did hide a live bug
  # where `--lact` skipped its purge on a real machine. STUB_DPKG_BULK pads the
  # output past the pipe buffer so the failure mode is reachable in a test.
  pad(){
    [[ "${STUB_DPKG_BULK:-0}" == "1" ]] || return 0
    local i
    for (( i=0; i<3000; i++ )); do
      printf 'ii  filler-package-%04d  1.0  amd64  padding so the output exceeds one pipe buffer\n' "${i}"
    done
  }
  if [[ -z "${2:-}" ]]; then
    for want in ${STUB_INSTALLED:-}; do echo "ii  ${want}  1.0  amd64  stubbed"; done
    pad
    exit 0
  fi
  for want in ${STUB_INSTALLED:-}; do
    if [[ "${2}" == "${want}" ]]; then echo "ii  ${want}  1.0  amd64  stubbed"; pad; exit 0; fi
  done
  exit 1
fi
exit 0
EOF
_mk dpkg-query <<'EOF'
case "$*" in
  *mesa-vulkan-drivers*) echo "${STUB_MESA:-25.2.8}-0ubuntu1"; exit 0;;
esac
_added(){
  local d; d="$(dirname "$0")"
  cat "${d}/.pkgs-installed" "${d}/.pkgs-by-drivers" 2>/dev/null
}
STUB_INSTALLED="${STUB_INSTALLED:-} $(_added | tr '\n' ' ')"
# `dpkg-query -W -f='${Package}\n' 'nvidia-*' 'cuda-*'`: report the installed
# packages matching each glob, so the uninstaller's driver sweep is testable.
# The installer also asks for '${db:Status-Abbrev} ${Package}', to tell an
# installed package from one apt merely knows about, so honour that too.
prefix=""
for a in "$@"; do case "${a}" in *db:Status-Abbrev*) prefix="ii  ";; esac; done
for pat in "$@"; do
  [[ "${pat}" == -* ]] && continue
  for want in ${STUB_INSTALLED:-}; do
    # shellcheck disable=SC2254  # the glob is the point here
    case "${want}" in ${pat}) echo "${prefix}${want}";; esac
  done
done
exit 0
EOF
_mk ubuntu-drivers <<'EOF'
# A real autoinstall puts driver packages on the machine, and the installer works
# out which ones by comparing dpkg before and after. STUB_DRIVER_ADDS is that
# difference: without it the before/after sets are identical and the recording
# path is never exercised.
if [[ "${1:-}" == "autoinstall" && -n "${STUB_DRIVER_ADDS:-}" ]]; then
  printf '%s\n' ${STUB_DRIVER_ADDS} >> "$(dirname "$0")/.pkgs-by-drivers"
fi
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
if [[ -f "$(dirname "$0")/.nvidia-after-upgrade" && -n "${STUB_NVIDIA_AFTER_UPGRADE:-}" ]]; then
  state="${STUB_NVIDIA_AFTER_UPGRADE}"
fi
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
# Real vulkaninfo --summary lists instance layers before the device block.
# "Mesa Overlay" must not be parsed as the driver version.
echo "VK_LAYER_MESA_overlay       Mesa Overlay layer           1.4.303  version 1"
echo "deviceName = Test GPU"
echo "driverName = ${STUB_ICD:-radv}"
echo "driverInfo = Mesa ${STUB_MESA:-25.2.8}"
EOF

_mk glxinfo <<'EOF'
# AMD/Intel VRAM fallback when nvidia-smi is absent. The installer does not
# ship mesa-utils, but a desktop may already have glxinfo; tests must not
# pick up the host's real card.
echo "Video memory: ${STUB_VRAM_MB:-24576}MB"
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
# STUB_BUSY_PORTS holds space-separated port:program pairs, for testing what
# happens when something already owns a port the installer wants.
for pair in ${STUB_BUSY_PORTS:-}; do
  echo "LISTEN 0 4096 127.0.0.1:${pair%%:*} 0.0.0.0:* users:((\"${pair##*:}\",pid=999,fd=3))"
done
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
# A pretend git, faithful in the one way the installer depends on: a checkout
# REMEMBERS which tag it is at, and reports it back. Real git behaves this way
# even for a shallow clone, because `clone --depth 1 --branch <tag>` fetches the
# tag ref, so `describe --tags --exact-match HEAD` returns it. Getting this
# wrong made every re-run look like it was at an unknown version.
# STUB_GIT_AT overrides the recorded tag when a test needs a specific state.
repo=""; branch=""; is_clone=""; last=""; prev=""
for a in "$@"; do
  case "${prev}" in
    -C) repo="$a";;
    -b|--branch) branch="$a";;
  esac
  case "$a" in
    clone) is_clone=1;;
    -*) ;;
    *) last="$a";;
  esac
  prev="$a"
done
[[ -z "${repo}" ]] && repo="${last}"
case " $* " in
  *" describe "*)
    if [[ -n "${STUB_GIT_AT+x}" ]]; then printf '%s\n' "${STUB_GIT_AT}"
    elif [[ -f "${repo}/.git/stub_tag" ]]; then cat "${repo}/.git/stub_tag"; fi
    exit 0;;
  *" status "*) [[ "${STUB_GIT_DIRTY:-0}" == "1" ]] && echo " M ggml/src/ggml.c"; exit 0;;
  *" fetch "*)  [[ "${STUB_GIT_FETCH_FAIL:-0}" == "1" ]] && exit 1; exit 0;;
  *" checkout "*)
    [[ -d "${repo}/.git" ]] && printf '%s\n' "${last}" > "${repo}/.git/stub_tag"
    exit 0;;
esac
# Create the directory a clone would create, with a .git so re-runs detect it.
if [[ "${is_clone}" == "1" && -n "${last}" ]]; then
  mkdir -p "${last}/.git"
  [[ -n "${branch}" ]] && printf '%s\n' "${branch}" > "${last}/.git/stub_tag"
fi
exit 0
EOF

# ----- services and firewall ------------------------------------------------
_mk systemctl <<'EOF'
# is-active has to be answerable, because the installer uses it to decide
# whether a rewritten unit needs restarting, and whether an answer on the port
# can be trusted as proof that OUR service is the one answering.
# STUB_SVC_DEAD lists units that should report as not running.
if [[ "${1:-}" == "is-active" ]]; then
  for a in "$@"; do
    for dead in ${STUB_SVC_DEAD:-}; do
      [[ "${a}" == "${dead}" ]] && exit 3
    done
  done
  exit 0
fi
# `status` and `list-unit-files` must be able to say "no such unit", because the
# uninstaller uses them to tell an installed service from an absent one. Real
# systemd exits non-zero for a unit it does not know; a stub that always
# succeeded made a bare machine look fully installed.
if [[ "${1:-}" == "status" || "${1:-}" == "list-unit-files" ]]; then
  if [[ -n "${STUB_UNIT_DIR:-}" ]]; then
    for a in "$@"; do
      case "${a}" in *.service) [[ -f "${STUB_UNIT_DIR}/${a}" ]] || exit 4;; esac
    done
  fi
  exit 0
fi
# The restart counter is how the installer spots a service that starts, dies and
# is started again, so a stub that cannot make it move cannot exercise that path.
# Units in STUB_SVC_LOOPING report a counter that climbs on every read.
if [[ "${1:-}" == "show" ]]; then
  unit=""; for a in "$@"; do case "${a}" in *.service) unit="${a}";; esac; done
  for l in ${STUB_SVC_LOOPING:-}; do
    if [[ "${unit}" == "${l}" ]]; then
      c="$(dirname "$0")/.restarts-${unit}"
      n=$(( $(cat "${c}" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "${n}" > "${c}"
      echo "${n}"; exit 0
    fi
  done
  echo 0; exit 0
fi
exit 0
EOF
_mk ufw <<'EOF'
# STUB_UFW_RULES lists rules `ufw status` should show, written exactly as ufw
# stores them: "8020" for a rule added as `ufw allow 8020`, "8020/tcp" for one
# added as `ufw allow 8020/tcp`.
#
# Deleting has to be modelled faithfully, because the real thing has two traps
# the uninstaller has to cope with. `ufw delete allow 8020/tcp` does NOT match a
# rule stored as "8020", and deleting a rule that is not there still exits 0.
# A stub that accepted any delete and reported success would let a broken
# uninstaller pass.
#
# STUB_UFW_DELETE_FAIL lists ports whose rules refuse to go, so the "could not
# remove it, here is the command" path can be checked.
DEL="$(dirname "$0")/.ufw-deleted"
if [[ "${1:-}" == "delete" && "${2:-}" == "allow" ]]; then
  spec="${3:-}"
  for p in ${STUB_UFW_DELETE_FAIL:-}; do
    [[ "${spec}" == "${p}" || "${spec}" == "${p}/tcp" ]] && exit 0
  done
  for r in ${STUB_UFW_RULES:-}; do
    [[ "${spec}" == "${r}" ]] && { printf '%s\n' "${spec}" >> "${DEL}"; exit 0; }
  done
  exit 0   # ufw exits 0 even for a rule that does not exist
fi
if [[ "${1:-}" == "status" ]]; then
  echo "Status: active"
  echo ""
  echo "To                         Action      From"
  echo "--                         ------      ----"
  echo "22/tcp                     ALLOW       Anywhere"
  for r in ${STUB_UFW_RULES:-}; do
    grep -qxF "${r}" "${DEL}" 2>/dev/null && continue
    printf '%-26s ALLOW       Anywhere\n' "${r}"
  done
  exit 0
fi
exit 0
EOF
_mk usermod <<'EOF'
exit 0
EOF
_mk getent <<'EOF'
# STUB_HOME forces the home directory reported for the user, which is how the
# uninstaller's "refuse to delete anything outside the home" guard gets tested.
if [[ "${1:-}" == "passwd" ]]; then echo "${2}:x:1000:1000::${STUB_HOME:-/home/${2}}:/bin/bash"; exit 0; fi
if [[ "${1:-}" == "group"  ]]; then echo "${2}:x:1000:"; exit 0; fi
exit 0
EOF
_mk gpasswd <<'EOF'
exit 0
EOF
_mk flatpak <<'EOF'
exit 0
EOF

# ----- python and model download --------------------------------------------
_mk python3 <<'EOF'
# venv: make the layout the installer expects.
if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
  mkdir -p "${3}/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${3}/bin/pip"; chmod +x "${3}/bin/pip"
  # The venv python has to stand in for upstream's setup.py, because the one
  # thing that matters about it is a decision it makes: create_default_admin()
  # returns at "auth.json already exists" BEFORE it reads
  # ODYSSEUS_ADMIN_PASSWORD, so on a re-run the password the installer generates
  # is applied to nothing. A stub that just exited 0 could not tell the two
  # cases apart, and that is precisely the bug it needs to catch.
  cat > "${3}/bin/python" <<'PY'
#!/usr/bin/env bash
if [[ "${1:-}" == "setup.py" ]]; then
  echo "5. Creating initial admin..."
  if [[ -f data/auth.json ]]; then
    echo "  [skip] auth.json already exists"
    echo "Login with your existing admin credentials."
  else
    mkdir -p data
    printf '{"users":{"%s":{"password_hash":"stub"}}}\n' "${ODYSSEUS_ADMIN_USER:-admin}" > data/auth.json
  fi
fi
exit 0
PY
  chmod +x "${3}/bin/python"
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
# STUB_CURL_FAIL lists ports where nothing is answering, which is what a service
# that has died looks like from the installer's readiness check.
for a in "$@"; do
  for p in ${STUB_CURL_FAIL:-}; do
    case "${a}" in *":${p}/"*|*":${p}") exit 7;; esac
  done
done
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
#
# Deleting our stub is not enough on a developer machine: `hf` from
# `pip install --user huggingface_hub` lives in ~/.local/bin, which is often
# on PATH. Same trap as nvcc below — mask it from the inherited PATH.
if [[ "${STUB_HAS_HF:-1}" != "1" ]]; then
  mv -f "${STUB_DIR}/hf" "${STUB_DIR}/huggingface-cli"
  STUB_MASK="${STUB_MASK:-} hf"
fi

# Same reasoning for nvcc. The installer decides whether to attempt a CUDA
# build with `command -v nvcc`, which tests for the file, not for a working
# compiler. "No CUDA toolkit" therefore has to mean the command is genuinely
# absent.
#
# Deleting our stub is not enough, and neither is leaving a stub that exits
# 127: `command -v` reports the first MATCH on PATH, so a command that is
# present but failing is still found. A command can only be hidden by being
# absent from every directory on PATH. On a developer machine with the CUDA
# toolkit installed, /usr/bin/nvcc would therefore be picked up and the CUDA
# branch taken, so the CPU-fallback assertion failed on exactly the machines
# most likely to run these tests by hand while passing in a bare CI container.
#
# So when something must be masked we rebuild the real half of PATH as a farm
# of symlinks that deliberately omits it, and hand the caller a PATH to use.
STUB_MASK="${STUB_MASK:-}"
[[ "${STUB_NO_NVCC:-0}" == "1" ]] && STUB_MASK="${STUB_MASK} nvcc"
rm -f "${STUB_DIR}/nvcc.disabled"

if [[ -n "${STUB_MASK// /}" ]]; then
  for cmd in ${STUB_MASK}; do rm -f "${STUB_DIR}/${cmd}"; done
  FARM="${STUB_DIR}-real"
  rm -rf "${FARM}"; mkdir -p "${FARM}"
  # Walk the inherited PATH once, in order, linking every command we find
  # except the masked ones. First link wins, which preserves PATH precedence.
  IFS=':' read -r -a _path_dirs <<<"${PATH}"
  for dir in "${_path_dirs[@]}"; do
    [[ -n "${dir}" && -d "${dir}" && "${dir}" != "${STUB_DIR}" ]] || continue
    for real in "${dir}"/*; do
      [[ -x "${real}" && ! -d "${real}" ]] || continue
      name="$(basename "${real}")"
      case " ${STUB_MASK} " in *" ${name} "*) continue;; esac
      [[ -e "${FARM}/${name}" ]] || ln -s "${real}" "${FARM}/${name}"
    done
  done
  printf '%s\n' "${STUB_DIR}:${FARM}" > "${STUB_DIR}-path"
  echo "masked from PATH:${STUB_MASK}"
else
  printf '%s\n' "${STUB_DIR}:${PATH}" > "${STUB_DIR}-path"
fi

echo "stubs written to ${STUB_DIR}"
