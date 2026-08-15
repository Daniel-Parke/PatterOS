#!/usr/bin/env bash
# =============================================================================
#  Drive install_local_ai.sh through every hardware path it claims to support.
#
#  MUST BE RUN AS ROOT IN A DISPOSABLE CONTAINER:
#    docker run --rm -v "$PWD:/mnt" -w /mnt ubuntu:24.04 \
#      bash tests/test_install_paths.sh
#
#  The installer runs completely unmodified. Only the outside world is faked,
#  by putting stubs ahead of the real commands on PATH (see harness/stubs.sh).
#  So the branching, the service files and the decisions are all real; the
#  driver installs, the compile and the 26 GB of downloads are not.
#
#  This exists because the interesting paths are the ones nobody can safely
#  test for real: a mismatched NVIDIA driver, an 8 GB card asked to hold a
#  19 GB model, SSH on a non-standard port, Resizable BAR switched off.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
INSTALL="${ROOT}/scripts/install_local_ai.sh"
[[ -r "${INSTALL}" ]] || { echo "cannot read ${INSTALL}"; exit 1; }
[[ "${EUID}" -eq 0 ]] || { echo "must run as root, in a disposable container"; exit 1; }

PASS=0; FAIL=0
ok(){  printf '    [pass] %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '    [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && printf '           %s\n' "$2"; }
has(){   if grep -q -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "expected to find: $2"; fi; }
hasnt(){ if grep -q -- "$2" "$1" 2>/dev/null; then bad "$3" "did not expect: $2"; else ok "$3"; fi; }
completes(){ if [[ ${RC} -eq 0 ]]; then ok "completes"; else bad "completes" "exit ${RC}"; fi; }

U="patteros_probe"
id -u "${U}" >/dev/null 2>&1 || useradd -m "${U}" >/dev/null 2>&1
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum required"; exit 1; }

# Run the installer in a sandbox with a given scenario.
# Usage: run_case <name> <extra installer args...>   (scenario via STUB_* env)
run_case(){
  local name="$1"; shift
  SANDBOX="$(mktemp -d)"
  export STUB_DIR="${SANDBOX}/bin" STUB_LOG="${SANDBOX}/calls.log"
  bash "${HERE}/harness/stubs.sh" >/dev/null

  # Redirect the paths the installer writes to, so nothing escapes the sandbox.
  mkdir -p "${SANDBOX}/etc" "${SANDBOX}/var"
  sed -e "s#/etc/systemd/system#${SANDBOX}/etc#g" \
      -e "s#^STAMP_DIR=\"/var/lib/patteros\"#STAMP_DIR=\"${SANDBOX}/var\"#" \
      "${INSTALL}" > "${SANDBOX}/install.sh"

  OUT="${SANDBOX}/stdout.txt"
  ( export PATH="${STUB_DIR}:${PATH}"
    export SUDO_USER="${U}"
    cd "${SANDBOX}" && bash "${SANDBOX}/install.sh" -y "$@" >"${OUT}" 2>&1 )
  RC=$?
  UNIT="${SANDBOX}/etc/llama.service"
  printf '\n  %s (exit %d)\n' "${name}" "${RC}"
}

cleanup(){ rm -rf "${SANDBOX:-}" 2>/dev/null || true; }
trap cleanup EXIT

echo "installer: every hardware path"

# ---------------------------------------------------------------------------
# 1. NVIDIA, healthy driver, 24 GB card, express tier
# ---------------------------------------------------------------------------
STUB_GPU=nvidia STUB_NVIDIA=ok STUB_VRAM_MB=24576 STUB_DISK_GB=500 \
  run_case "NVIDIA, healthy driver, 24 GB, express" --no-odysseus --skip-firewall
completes
has "${OUT}" "driver is loaded and healthy" "leaves a healthy driver alone"
hasnt "${OUT}" "ubuntu-drivers autoinstall" "does not reinstall a healthy driver"
has "${OUT}" "Engine built (cuda)" "builds the CUDA backend"
has "${UNIT}" "--models-max 1" "unit sets --models-max 1"
has "${UNIT}" "-ngl 999" "whole model on the GPU when it fits"
has "${UNIT}" "--port 8020" "correct port"
has "${UNIT}" "127.0.0.1" "binds to localhost only"

# ---------------------------------------------------------------------------
# 2. NVIDIA, driver/library mismatch. Must NOT reinstall, must ask for a reboot.
# ---------------------------------------------------------------------------
STUB_GPU=nvidia STUB_NVIDIA=mismatch STUB_VRAM_MB=24576 STUB_DISK_GB=500 \
  run_case "NVIDIA, driver mismatch" --no-models --no-odysseus --skip-firewall
completes
has "${OUT}" "mismatch" "detects the mismatch"
hasnt "${SANDBOX}/calls.log" "ubuntu-drivers autoinstall" "does NOT reinstall the driver"
has "${OUT}" "Reboot" "tells the user to reboot"

# ---------------------------------------------------------------------------
# 3. NVIDIA, no driver at all. Must install it.
# ---------------------------------------------------------------------------
STUB_GPU=nvidia STUB_NVIDIA=missing STUB_NO_NVCC=1 STUB_DISK_GB=500 \
  run_case "NVIDIA, no driver present" --no-models --no-odysseus --skip-firewall
completes
has "${SANDBOX}/calls.log" "ubuntu-drivers autoinstall" "installs the driver when genuinely missing"
has "${OUT}" "Engine built (cpu)" "falls back to CPU when nvcc is absent"

# ---------------------------------------------------------------------------
# 4. AMD. Vulkan, Resizable BAR OFF. The bug that halves throughput.
# ---------------------------------------------------------------------------
STUB_GPU=amd STUB_VRAM_MB=24576 STUB_BAR_MB=256 STUB_MESA=25.2.8 STUB_ICD=radv STUB_DISK_GB=500 \
  run_case "AMD, Resizable BAR disabled" --no-models --no-odysseus --skip-firewall
completes
has "${OUT}" "Engine built (vulkan)" "builds the Vulkan backend"
has "${OUT}" "Resizable BAR" "detects Resizable BAR being off"
has "${UNIT}" "GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1" "applies the ReBAR workaround to the service"
has "${UNIT}" "RADV_PERFTEST=nogttspill" "applies the recommended RADV tuning"

# ---------------------------------------------------------------------------
# 5. AMD, everything healthy. No workaround should be applied.
# ---------------------------------------------------------------------------
STUB_GPU=amd STUB_VRAM_MB=24576 STUB_BAR_MB=24576 STUB_MESA=25.2.8 STUB_ICD=radv STUB_DISK_GB=500 \
  run_case "AMD, Resizable BAR enabled" --no-models --no-odysseus --skip-firewall
hasnt "${UNIT}" "GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM" "no ReBAR workaround when it is not needed"
hasnt "${OUT}" "older than the 25.2" "no Mesa warning on a current Mesa"

# ---------------------------------------------------------------------------
# 6. AMD on an old Mesa and the unsupported driver. Both should be called out.
# ---------------------------------------------------------------------------
STUB_GPU=amd STUB_VRAM_MB=16384 STUB_BAR_MB=16384 STUB_MESA=24.0.5 STUB_ICD=amdvlk STUB_DISK_GB=500 \
  run_case "AMD, Mesa 24.0.5 and AMDVLK" --no-models --no-odysseus --skip-firewall
has "${OUT}" "older than the 25.2" "warns about Mesa below 25.2"
has "${OUT}" "AMDVLK" "warns that AMDVLK is in use instead of RADV"

# ---------------------------------------------------------------------------
# 7. Intel. Vulkan, no vendor toolkit.
# ---------------------------------------------------------------------------
STUB_GPU=intel STUB_DISK_GB=500 \
  run_case "Intel Arc" --no-models --no-odysseus --skip-firewall
has "${OUT}" "Engine built (vulkan)" "builds Vulkan on Intel"

# ---------------------------------------------------------------------------
# 8. CPU only. THE REGRESSION THAT MATTERS: --models-max must be 1, not 0.
# ---------------------------------------------------------------------------
STUB_GPU=none STUB_DISK_GB=500 \
  run_case "no GPU, CPU only" --no-models --no-odysseus --skip-firewall
completes
has "${OUT}" "Engine built (cpu)" "builds the CPU backend"
has "${UNIT}" "--models-max 1" "CPU path uses --models-max 1, NOT 0"
hasnt "${UNIT}" "--models-max 0" "0 (unlimited) never reaches the unit"
has "${UNIT}" "-ngl 0" "no GPU offload on a CPU build"

# ---------------------------------------------------------------------------
# 9. Small card, big models. Must offload partially rather than assume it fits.
# ---------------------------------------------------------------------------
STUB_GPU=nvidia STUB_NVIDIA=ok STUB_VRAM_MB=8192 STUB_DISK_GB=500 \
  run_case "8 GB card, --full tier" --full --no-odysseus --skip-firewall
completes
has "${OUT}" "layers will run on the GPU" "computes a partial offload"
hasnt "${UNIT}" "-ngl 999" "does not claim the whole model fits on an 8 GB card"
ngl="$(grep -oE -- '-ngl [0-9]+' "${UNIT}" | grep -oE '[0-9]+' | head -1)"
if [[ -n "${ngl}" && "${ngl}" -gt 0 && "${ngl}" -lt 999 ]]; then ok "chose a sane layer count (${ngl})"
else bad "chose a sane layer count" "got '${ngl}'"; fi

# ---------------------------------------------------------------------------
# 10. Not enough disk. Must refuse BEFORE downloading anything.
# ---------------------------------------------------------------------------
STUB_GPU=nvidia STUB_NVIDIA=ok STUB_VRAM_MB=24576 STUB_DISK_GB=4 \
  run_case "only 4 GB free, express tier" --no-odysseus --skip-firewall
if [[ ${RC} -ne 0 ]]; then ok "refuses to continue"; else bad "refuses to continue" "exit ${RC}"; fi
has "${OUT}" "Not enough disk space" "explains it is a disk problem"
hasnt "${SANDBOX}/calls.log" "hf download" "stops BEFORE downloading anything"

# ---------------------------------------------------------------------------
# 11. Models actually download, and the QAT repos are the ones requested.
# ---------------------------------------------------------------------------
STUB_GPU=nvidia STUB_NVIDIA=ok STUB_VRAM_MB=24576 STUB_DISK_GB=500 \
  run_case "express tier downloads" --no-odysseus --skip-firewall
has "${SANDBOX}/calls.log" "unsloth/gemma-4-E2B-it-qat-GGUF" "requests the E2B QAT repo"
has "${SANDBOX}/calls.log" "unsloth/gemma-4-E4B-it-qat-GGUF" "requests the E4B QAT repo"
has "${OUT}" "All 2 model(s) downloaded" "reports both as downloaded"

# ---------------------------------------------------------------------------
# 11b. REGRESSION. Verification must check the file THIS repo produced.
#
# ~/models accumulates every model you have ever downloaded, and they all match
# a glob like *UD-Q4_K_XL*.gguf. The verification step used the bare glob and
# took the first match, so on a directory already holding a larger model it
# could size-check the wrong file and report a good download as incomplete.
# Whether it happened depended on filesystem ordering, so it passed locally and
# failed in CI. Seed a big unrelated model first and assert both still verify.
# ---------------------------------------------------------------------------
mkdir -p "/home/${U}/models"
head -c 200000000 /dev/zero > "/home/${U}/models/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf"
chown -R "${U}" "/home/${U}/models" 2>/dev/null || true
STUB_GPU=nvidia STUB_NVIDIA=ok STUB_VRAM_MB=24576 STUB_DISK_GB=500 \
  run_case "express tier, models directory not empty" --no-odysseus --skip-firewall
has "${OUT}" "All 2 model(s) downloaded" "verifies the right file when others are present"
hasnt "${OUT}" "may be incomplete" "does not call a good download incomplete"
# The decisive check. Each confirmation must name the file for the repo that was
# just fetched. Matching on the bare glob would confirm whichever file `find`
# happened to return first, which is directory-order dependent: that is why this
# passed locally and failed in CI.
confirmed="$(grep -oE '\[OK\] gemma-4-[A-Za-z0-9._-]+\.gguf' "${OUT}" | awk '{print $2}')"
if [[ "$(echo "${confirmed}" | sed -n 1p)" == gemma-4-E2B* ]]; then ok "confirms the E2B file for the E2B repo"
else bad "confirms the E2B file for the E2B repo" "got: $(echo "${confirmed}" | sed -n 1p)"; fi
if [[ "$(echo "${confirmed}" | sed -n 2p)" == gemma-4-E4B* ]]; then ok "confirms the E4B file for the E4B repo"
else bad "confirms the E4B file for the E4B repo" "got: $(echo "${confirmed}" | sed -n 2p)"; fi
rm -f "/home/${U}/models/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf"

# ---------------------------------------------------------------------------
# 12. Older huggingface_hub: only huggingface-cli exists.
# ---------------------------------------------------------------------------
STUB_GPU=none STUB_HAS_HF=0 STUB_DISK_GB=500 \
  run_case "only huggingface-cli available" --no-odysseus --skip-firewall
has "${OUT}" "huggingface-cli" "falls back to huggingface-cli"

# ---------------------------------------------------------------------------
# 13. Download failure must be reported, not silently called success.
# ---------------------------------------------------------------------------
STUB_GPU=none STUB_DL_FAIL=1 STUB_DISK_GB=500 \
  run_case "downloads fail" --no-odysseus --skip-firewall
has "${OUT}" "No models were downloaded successfully" "reports total download failure honestly"

# ---------------------------------------------------------------------------
# 14. Firewall must allow the REAL ssh port, not assume 22.
# ---------------------------------------------------------------------------
STUB_GPU=none STUB_SSH_PORT=2222 STUB_DISK_GB=500 \
  run_case "SSH on port 2222" --no-models --no-odysseus
has "${OUT}" "Allowed SSH on port 2222" "allows the real SSH port"
has "${SANDBOX}/calls.log" "ufw allow 2222/tcp" "adds the rule for 2222"
if grep -q 'ufw allow 2222/tcp' "${SANDBOX}/calls.log" && \
   [[ "$(grep -n 'ufw allow 2222/tcp' "${SANDBOX}/calls.log" | head -1 | cut -d: -f1)" -lt \
      "$(grep -n 'ufw --force enable'  "${SANDBOX}/calls.log" | head -1 | cut -d: -f1)" ]]; then
  ok "allows SSH BEFORE enabling the firewall"
else bad "allows SSH BEFORE enabling the firewall"; fi

# ---------------------------------------------------------------------------
# 15. Odysseus: canonical address, pinned commit, password not printed.
# ---------------------------------------------------------------------------
STUB_GPU=none STUB_DISK_GB=500 \
  run_case "Odysseus install" --no-models --skip-firewall
has "${SANDBOX}/calls.log" "odysseus-dev/odysseus" "clones the canonical address"
hasnt "${SANDBOX}/calls.log" "pewdiepie-archdaemon" "never touches the old redirect address"
has "${SANDBOX}/calls.log" "checkout -q cf4e240a" "checks out the pinned commit"
has "${OUT}" "AGPL-3.0" "states the licence to the user"
has "${OUT}" "root-only file" "saves the password to a file"
pw_file="${SANDBOX}/var/odysseus-first-login.txt"
if [[ -f "${pw_file}" ]]; then
  ok "writes the first-login file"
  mode="$(stat -c '%a' "${pw_file}")"
  if [[ "${mode}" == "600" ]]; then ok "first-login file is mode 600"; else bad "first-login file is mode 600" "got ${mode}"; fi
  pw="$(grep -oE 'Password: .*' "${pw_file}" | cut -d' ' -f2)"
  if [[ -n "${pw}" ]] && ! grep -q "${pw}" "${OUT}"; then ok "the password never appears in terminal output"
  else bad "the password never appears in terminal output"; fi
else bad "writes the first-login file"; fi

# ---------------------------------------------------------------------------
# 16. Idempotency: a second run must not fight the first.
# ---------------------------------------------------------------------------
STUB_GPU=nvidia STUB_NVIDIA=ok STUB_VRAM_MB=24576 STUB_DISK_GB=500 \
  run_case "first run" --no-models --no-odysseus --skip-firewall
first_unit="$(cat "${UNIT}" 2>/dev/null)"
KEEP="${SANDBOX}"
STUB_GPU=nvidia STUB_NVIDIA=ok STUB_VRAM_MB=24576 STUB_DISK_GB=500 \
  run_case "second run (idempotency)" --no-models --no-odysseus --skip-firewall
if [[ ${RC} -eq 0 ]]; then ok "a repeat run still succeeds"; else bad "a repeat run still succeeds" "exit ${RC}"; fi
if [[ "$(cat "${UNIT}" 2>/dev/null)" == "${first_unit}" ]]; then ok "produces an identical service file"; else bad "produces an identical service file"; fi
rm -rf "${KEEP}"

# ---------------------------------------------------------------------------
# 17. The generated unit is a VALID systemd unit, per systemd itself.
# ---------------------------------------------------------------------------
if command -v systemd-analyze >/dev/null 2>&1; then
  STUB_GPU=amd STUB_VRAM_MB=24576 STUB_BAR_MB=256 STUB_DISK_GB=500 \
    run_case "unit validation" --no-models --skip-firewall
  for u in "${SANDBOX}/etc/llama.service" "${SANDBOX}/etc/odysseus.service"; do
    [[ -f "${u}" ]] || continue
    v="$(systemd-analyze verify "${u}" 2>&1 | grep -vE 'Unknown key name .WantedBy|/dev/null|Failed to (create|prepare)|systemd-analyze' || true)"
    if [[ -z "${v}" ]]; then ok "$(basename "${u}") is valid systemd syntax"
    else bad "$(basename "${u}") is valid systemd syntax" "${v}"; fi
  done
else
  echo "    [skip] systemd-analyze not installed, unit syntax not validated"
fi

echo
printf '%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
