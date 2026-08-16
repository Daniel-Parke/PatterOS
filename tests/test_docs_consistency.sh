#!/usr/bin/env bash
# =============================================================================
#  Test: the scripts and the documentation must not drift apart.
#
#  Every check here corresponds to a real defect that shipped. The guide told
#  people to use --models-max 0 while the script did too, and both were wrong.
#  The Part 1 guide advertised ports the software had not used for months. The
#  installer told users to run a filename that did not exist. None of that is
#  exotic; it is just what happens when prose and code are edited separately.
#
#  This runs anywhere bash and grep exist, including CI. No root, no container.
#
#  Run:  bash tests/test_docs_consistency.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
INSTALL="${ROOT}/scripts/install_local_ai.sh"
UNINSTALL="${ROOT}/scripts/uninstall_local_ai.sh"
GUIDE="${ROOT}/docs/part-2-manual-setup-guide.md"

PASS=0; FAIL=0
ok(){  printf '  [pass] %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; }

for f in "${INSTALL}" "${UNINSTALL}" "${GUIDE}"; do
  [[ -r "${f}" ]] || { echo "cannot read ${f}"; exit 1; }
done

echo "documentation and scripts agree"

# --- 1. --models-max 0 must not reappear, anywhere -------------------------
# 0 means UNLIMITED in llama.cpp, not "none". This is the single worst bug the
# project has shipped, and it was in the script AND the guide simultaneously.
if grep -rn -- '--models-max[= ]*0' "${INSTALL}" "${UNINSTALL}" "${GUIDE}" >/dev/null 2>&1; then
  bad "--models-max 0 has come back" "$(grep -rn -- '--models-max[= ]*0' "${INSTALL}" "${UNINSTALL}" "${GUIDE}")"
else
  ok "no --models-max 0 anywhere (0 means unlimited, not none)"
fi

# --- 2. the installer's own name ------------------------------------------
# The Part 2 video description links to scripts/install_local_ai.sh, so that is
# the name, and nothing may refer to the old one.
if grep -rn 'setup_local_ai\.sh' "${INSTALL}" "${UNINSTALL}" "${GUIDE}" >/dev/null 2>&1; then
  bad "something still refers to setup_local_ai.sh" "the published video links to install_local_ai.sh"
else
  ok "no stale setup_local_ai.sh references"
fi

# --- 3. Odysseus is cloned from the canonical address ----------------------
# The old address is a GitHub rename redirect over a name slot its previous
# owner no longer uses. If that name is ever reused, we would clone and execute
# whatever is put there.
# Comment lines are excluded on purpose: the installer explains WHY the old
# address must not be used, and that explanation is worth keeping.
if { grep -v '^[[:space:]]*#' "${INSTALL}"; cat "${GUIDE}"; } | grep -q 'pewdiepie-archdaemon'; then
  bad "Odysseus is cloned from the old redirect address" "use github.com/odysseus-dev/odysseus"
else
  ok "Odysseus uses the canonical odysseus-dev address"
fi

# --- 4. installer and uninstaller are a matched pair -----------------------
iv="$(grep -oE 'install_local_ai\.sh  \(v[0-9.]+\)' "${INSTALL}"   | grep -oE 'v[0-9.]+' | head -1)"
uv="$(grep -oE 'uninstall_local_ai\.sh  \(v[0-9.]+\)' "${UNINSTALL}" | grep -oE 'v[0-9.]+' | head -1)"
if [[ -n "${iv}" && "${iv}" == "${uv}" ]]; then ok "installer and uninstaller are both ${iv}"
else bad "version mismatch" "installer=${iv:-none} uninstaller=${uv:-none}"; fi

# --- 5. the guide steps the installer points at must exist -----------------
# The installer prints "guide, Step 10/11/12". If the guide is renumbered those
# messages silently start pointing at the wrong thing.
# Process substitution, not a pipe: a piped `while read` runs in a subshell and
# the accumulated result would be discarded.
missing=""
while IFS= read -r n; do
  [[ -n "${n}" ]] || continue
  grep -qE "^#+ Step ${n}[^0-9]" "${GUIDE}" || missing="${missing} ${n}"
done < <(grep -oE 'guide, Step [0-9]+' "${INSTALL}" | grep -oE '[0-9]+' | sort -u)
if [[ -z "${missing}" ]]; then ok "every 'guide, Step N' reference resolves to a heading"
else bad "installer references guide steps that do not exist:${missing}"; fi

# --- 6. ports agree ---------------------------------------------------------
p_llama="$(grep -oE '^PORT_LLAMA=[0-9]+' "${INSTALL}" | grep -oE '[0-9]+' | head -1)"
p_ody="$(  grep -oE '^PORT_ODY=[0-9]+'   "${INSTALL}" | grep -oE '[0-9]+' | head -1)"
for pair in "llama:${p_llama}" "odysseus:${p_ody}"; do
  name="${pair%%:*}"; port="${pair##*:}"
  if [[ -n "${port}" ]] && grep -q "${port}" "${GUIDE}"; then ok "the guide uses the same ${name} port (${port})"
  else bad "the guide does not mention the ${name} port ${port:-?}"; fi
done

# --- 7. models agree --------------------------------------------------------
# Every model the script downloads must appear in the guide, so a reader
# following either route ends up with the same thing.
mismatch=""
while IFS= read -r repo; do
  [[ -n "${repo}" ]] || continue
  grep -q "${repo}" "${GUIDE}" || mismatch="${mismatch} ${repo}"
done < <(grep -oE 'unsloth/[A-Za-z0-9._-]+' "${INSTALL}" | sort -u)
if [[ -z "${mismatch}" ]]; then ok "every model in the script is named in the guide"
else bad "models in the script but not the guide:${mismatch}"; fi

# --- 8. LACT version agrees -------------------------------------------------
# The guide sat on 0.9.0 for a release after the script moved to 0.10.0, so
# someone following the manual route installed a different build from someone
# running the script, and only one of them was the version we test.
lact_script="$(grep -oE '^LACT_VER="[0-9.]+"' "${INSTALL}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
lact_guide="$(grep -oE 'LACT/releases/download/v[0-9.]+' "${GUIDE}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u)"
if [[ -z "${lact_script}" ]]; then
  bad "could not read LACT_VER out of the installer"
elif [[ "${lact_guide}" == "${lact_script}" ]]; then
  ok "the guide installs the same LACT version as the script (${lact_script})"
else
  bad "LACT version drift: script ${lact_script}, guide ${lact_guide:-none}"
fi

# --- 9. q4 only -------------------------------------------------------------
# A model either fits in memory or it does not. Full-precision weights are never
# downloaded, so no BF16/F16/F32 quant may appear in the model list.
if grep -oE 'unsloth/[A-Za-z0-9._-]+\|[^|]*\|' "${INSTALL}" | grep -qiE 'bf16|f16|f32'; then
  bad "a full-precision model has crept into the download list"
else
  ok "every model in the download list is q4-class"
fi

echo
printf '%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
