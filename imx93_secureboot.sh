#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# i.MX93 Secure Boot Helper Script
# Version: 6.8 [022026]
# -----------------------------------------------------------------------------
SCRIPT_VERSION="6.8 [022026]"

# -----------------------------------------------------------------------------
# i.MX93: Build + Sign U-Boot (AHAB) and create an SD/eMMC-bootable signed image
# using SPSDK (nxpimage bootable-image export).
#
# Features:
#  - Interactive menu (run any step, or run all)
#  - CLI arguments for each step
#  - Optional logging (--log file)
#  - Colored console output (disable with --no-color)
#  - Expanded dependency checks (apt-get list mirrored; no header checks)
#  - Split build into separate ATF + U-Boot steps and renumbered
#  - Run all with optional pause between steps
#  - Run all without generating keys (skips Step 7)
#  - Step 2: choose board target (EVK vs FRDM)
#  - Step 8/9: choose boot media (sd vs emmc)
# -----------------------------------------------------------------------------

# ----------------------------- Defaults --------------------------------------
WORKDIR="${WORKDIR:-work}"
#To be found here: https://www.nxp.com/docs/en/release-note/RN00210.pdf
DDR_EULA_URL="${DDR_EULA_URL:-https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/firmware-imx-8.30-3fa84fd.bin}"
ELE_EULA_URL="${ELE_EULA_URL:-https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/firmware-ele-imx-2.0.4-93492e0.bin}"

# pick the v202201 DDR files like typical examples
DDR_IMEM_1D="lpddr4_imem_1d_v202201.bin"
DDR_IMEM_2D="lpddr4_imem_2d_v202201.bin"
DDR_DMEM_1D="lpddr4_dmem_1d_v202201.bin"
DDR_DMEM_2D="lpddr4_dmem_2d_v202201.bin"

# Behavior toggles
NO_COLOR=0
PAUSE_BETWEEN_STEPS=0
SKIP_KEYGEN=0

# Target selectors (requested defaults)
BOARD_TARGET="${BOARD_TARGET:-frdm}"                 # evk | frdm
BOOT_MEDIA="${BOOT_MEDIA:-serial_downloader}"        # sd | emmc | serial_downloader

# Output run id (set once, after args are parsed)
RUN_ID=""
OUTPUTS_RUN_DIR=""   # e.g. outputs/20260226_134501_frdm_serial_downloader
LAST_OUT_BIN=""

# ----------------------------- Resolve WORKDIR (ABS) --------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${WORKDIR}" = /* ]]; then
  WORKDIR_ABS="${WORKDIR}"
else
  WORKDIR_ABS="${SCRIPT_DIR}/${WORKDIR}"
fi

# ----------------------------- Color -----------------------------------------
if [[ -t 1 ]]; then
  C_RESET="$(tput sgr0 || true)"
  C_RED="$(tput setaf 1 || true)"
  C_GREEN="$(tput setaf 2 || true)"
  C_YELLOW="$(tput setaf 3 || true)"
  C_BLUE="$(tput setaf 4 || true)"
  C_BOLD="$(tput bold || true)"
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

log_i() { echo -e "${C_BLUE}${C_BOLD}[INFO]${C_RESET} $*"; }
log_w() { echo -e "${C_YELLOW}${C_BOLD}[WARN]${C_RESET} $*"; }
log_e() { echo -e "${C_RED}${C_BOLD}[ERR ]${C_RESET} $*" >&2; }
log_ok(){ echo -e "${C_GREEN}${C_BOLD}[OK  ]${C_RESET} $*"; }

die() { log_e "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
step() { echo; echo -e "${C_BOLD}==> $*${C_RESET}"; }

pause_if_enabled() {
  if [[ "$PAUSE_BETWEEN_STEPS" -eq 1 ]]; then
    echo
    read -r -p "Press ENTER to continue..." _ || true
  fi
}

# ----------------------------- Helpers ---------------------------------------
normalize_board_target() {
  case "${BOARD_TARGET,,}" in
    evk|imx93_11x11_evk) BOARD_TARGET="evk" ;;
    frdm|imx93_11x11_frdm) BOARD_TARGET="frdm" ;;
    *) die "Invalid BOARD_TARGET='$BOARD_TARGET' (use: evk or frdm)" ;;
  esac
}

normalize_boot_media() {
  case "${BOOT_MEDIA,,}" in
    sd) BOOT_MEDIA="sd" ;;
    emmc|eMMC) BOOT_MEDIA="emmc" ;;
    serial_downloader|serial|sdp|sdps) BOOT_MEDIA="serial_downloader" ;;
    *) die "Invalid BOOT_MEDIA='$BOOT_MEDIA' (use: sd, emmc, or serial_downloader)" ;;
  esac
}

uboot_defconfig_for_target() {
  normalize_board_target
  if [[ "$BOARD_TARGET" == "frdm" ]]; then
    echo "imx93_11x11_frdm_defconfig"
  else
    echo "imx93_11x11_evk_defconfig"
  fi
}

init_run_outputs() {
  if [[ -n "${RUN_ID}" && -n "${OUTPUTS_RUN_DIR}" ]]; then
    return 0
  fi
  RUN_ID="$(date +%Y%m%d_%H%M%S)"
  OUTPUTS_RUN_DIR="outputs/${RUN_ID}_${BOARD_TARGET}_${BOOT_MEDIA}"
}

# ----------------------------- CLI -------------------------------------------
RUN_MODE="menu"         # menu | all | steps
STEPS_TO_RUN=()         # e.g., (1 3 7)
LOG_FILE=""

usage() {
  cat <<TXT
Usage:
  ./imx93_secureboot.sh [options]

Script version:
  ${SCRIPT_VERSION}

Run modes:
  --menu                 Show interactive menu (default)
  --all                  Run all steps sequentially (1..10)
  --step N               Run a single step (1..10). Can be repeated.

Convenience step flags (same as --step):
  --atf                  Step 1: Build ARM Trusted Firmware (imx-atf)
  --uboot                Step 2: Build U-Boot (uboot-imx)
  --download-ddr         Step 3: Download DDR firmware package
  --download-ele         Step 4: Download ELE firmware container package
  --stage-inputs         Step 5: Stage required binaries into inputs/
  --download             Steps 3..5 (compatibility alias)
  --spsdk                Step 6: Create/activate venv + install SPSDK
  --keys                 Step 7: Generate & verify keys + Compute SRK Table
  --yaml                 Step 8: Write YAML configs
  --export               Step 9: Export signed image
  --verify               Step 10: Verify signed image

Target selection:
  --board evk|frdm        Select U-Boot defconfig (default: frdm)
  --media sd|emmc|serial_downloader
                          Select bootable-image memory_type (default: serial_downloader)

All-step options:
  --all-no-keys          Run all steps but skip key generation (skips Step 7)
  --pause                Pause between each step (works with --all/--all-no-keys)

Other options:
  --workdir DIR          Working directory (default: work)
  --log FILE             Save all stdout+stderr to FILE (also prints to console)
  --no-color             Disable colored output
  -h, --help             Show this help

Examples:
  ./imx93_secureboot.sh --all --pause --log run.log
  ./imx93_secureboot.sh --all-no-keys --pause
  ./imx93_secureboot.sh --atf --uboot --download
  ./imx93_secureboot.sh --all --board frdm --media emmc --pause --log run.log
  ./imx93_secureboot.sh --step 2 --board frdm
  ./imx93_secureboot.sh --step 6 --step 7 --log spsdk_keys.log
TXT
}

add_step() {
  local n="$1"
  case "$n" in
    1|2|3|4|5|6|7|8|9|10) STEPS_TO_RUN+=("$n") ;;
    *) die "Invalid step: $n (valid: 1..10)" ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --menu) RUN_MODE="menu"; shift ;;
      --all) RUN_MODE="all"; shift ;;
      --all-no-keys) RUN_MODE="all"; SKIP_KEYGEN=1; shift ;;
      --pause) PAUSE_BETWEEN_STEPS=1; shift ;;
      --step) RUN_MODE="steps"; add_step "${2:-}"; shift 2 ;;
      --atf) RUN_MODE="steps"; add_step 1; shift ;;
      --uboot) RUN_MODE="steps"; add_step 2; shift ;;
      --download-ddr) RUN_MODE="steps"; add_step 3; shift ;;
      --download-ele) RUN_MODE="steps"; add_step 4; shift ;;
      --stage-inputs) RUN_MODE="steps"; add_step 5; shift ;;
      --download) RUN_MODE="steps"; add_step 3; add_step 4; add_step 5; shift ;;
      --spsdk) RUN_MODE="steps"; add_step 6; shift ;;
      --keys) RUN_MODE="steps"; add_step 7; shift ;;
      --yaml) RUN_MODE="steps"; add_step 8; shift ;;
      --export) RUN_MODE="steps"; add_step 9; shift ;;
      --verify) RUN_MODE="steps"; add_step 10; shift ;;

      --board) BOARD_TARGET="${2:-}"; shift 2; normalize_board_target ;;
      --media) BOOT_MEDIA="${2:-}"; shift 2; normalize_boot_media ;;

      --workdir)
        WORKDIR="${2:-}"
        shift 2
        if [[ "${WORKDIR}" = /* ]]; then
          WORKDIR_ABS="${WORKDIR}"
        else
          WORKDIR_ABS="${SCRIPT_DIR}/${WORKDIR}"
        fi
        ;;
      --log) LOG_FILE="${2:-}"; shift 2 ;;
      --no-color) NO_COLOR=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1 (use --help)" ;;
    esac
  done
}

apply_no_color() {
  if [[ "$NO_COLOR" -eq 1 ]]; then
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
  fi
}

setup_logging() {
  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_i "Logging enabled -> $LOG_FILE"
  fi
}

# ----------------------------- Workspace -------------------------------------
ensure_workspace() {
  mkdir -p "${WORKDIR_ABS}/"{inputs,outputs,keys}
  cd "${WORKDIR_ABS}"
  # init run folder once we are inside workdir
  init_run_outputs
  mkdir -p "${OUTPUTS_RUN_DIR}"
}

delete_workdir() {
  local confirm

  [[ -n "${WORKDIR_ABS}" ]] || die "WORKDIR_ABS is empty; refusing to delete."
  [[ "${WORKDIR_ABS}" != "/" ]] || die "Refusing to delete '/'."
  [[ "${WORKDIR_ABS}" != "${SCRIPT_DIR}" ]] || die "Refusing to delete the script directory."

  if [[ ! -e "${WORKDIR_ABS}" ]]; then
    log_w "Work directory does not exist: ${WORKDIR_ABS}"
    return 0
  fi

  echo
  log_w "This will permanently delete: ${WORKDIR_ABS}"
  read -r -p "Type DELETE to confirm (anything else cancels): " confirm || true
  if [[ "${confirm}" != "DELETE" ]]; then
    log_i "Delete canceled."
    return 0
  fi

  rm -rf -- "${WORKDIR_ABS}"
  log_ok "Deleted work directory: ${WORKDIR_ABS}"

  # Reset run-specific output folder naming for the next action.
  RUN_ID=""
  OUTPUTS_RUN_DIR=""
  init_run_outputs
}

# ----------------------------- Dependencies ----------------------------------
check_host_deps() {
  need git
  need make
  need wget
  need python3
  need pip3
  need gcc
  need aarch64-linux-gnu-gcc
  need aarch64-linux-gnu-objcopy
  need bc
  need bison
  need flex
  need lsblk

  python3 - <<'PY' >/dev/null 2>&1 || die "missing required package: python3-venv (venv module unavailable)"
import venv
PY
}

spsdk_prereqs() {
  if [[ ! -d spsdk-venv ]]; then
    python3 -m venv spsdk-venv
  fi
  # shellcheck disable=SC1091
  source spsdk-venv/bin/activate
  python -m pip install -U "spsdk[examples]" >/dev/null
  need nxpimage
  need nxpcrypto
  nxpimage --version
  nxpcrypto --version
}

# ----------------------------- Steps -----------------------------------------
step1_build_atf() {
  step "Step 1: Build ARM Trusted Firmware (imx-atf)"
  check_host_deps
  ensure_workspace

  if [[ ! -d imx-atf ]]; then
    git clone https://github.com/nxp-imx/imx-atf/
  fi

  pushd imx-atf >/dev/null
  unset LDFLAGS
  make PLAT=imx93 bl31
  popd >/dev/null

  log_ok "Step 1 complete"
  pause_if_enabled
}

step2_build_uboot() {
  normalize_board_target
  local defcfg
  defcfg="$(uboot_defconfig_for_target)"

  step "Step 2: Build U-Boot (uboot-imx) [board=${BOARD_TARGET} -> ${defcfg}]"
  check_host_deps
  ensure_workspace

  if [[ ! -d uboot-imx ]]; then
    git clone https://github.com/nxp-imx/uboot-imx
  fi

  pushd uboot-imx >/dev/null
  make "${defcfg}"

  if [[ -x ./scripts/config ]]; then
    ./scripts/config --enable CONFIG_AHAB_BOOT
    ./scripts/config --enable CONFIG_CONSOLE_MUX
  else
    log_w "uboot-imx/scripts/config not found or not executable; skipping CONFIG_ toggles"
  fi

  make olddefconfig
  make -j"$(nproc)"
  popd >/dev/null

  log_ok "Step 2 complete"
  pause_if_enabled
}

step3_download_ddr() {
  step "Step 3: Download DDR firmware package (EULA)"
  check_host_deps
  ensure_workspace

  if [[ ! -f firmware-imx-8.30-3fa84fd.bin ]]; then
    wget -O firmware-imx-8.30-3fa84fd.bin "${DDR_EULA_URL}"
    chmod +x firmware-imx-8.30-3fa84fd.bin
    ./firmware-imx-8.30-3fa84fd.bin --auto-accept
  else
    log_i "DDR EULA package already present: firmware-imx-8.30-3fa84fd.bin"
  fi

  log_ok "Step 3 complete"
  pause_if_enabled
}

step4_download_ele() {
  step "Step 4: Download ELE firmware container package (EULA)"
  check_host_deps
  ensure_workspace

  if [[ ! -f firmware-ele-imx-2.0.4-93492e0.bin ]]; then
    wget -O firmware-ele-imx-2.0.4-93492e0.bin "${ELE_EULA_URL}"
    chmod +x firmware-ele-imx-2.0.4-93492e0.bin
    ./firmware-ele-imx-2.0.4-93492e0.bin --auto-accept
  else
    log_i "ELE EULA package already present: firmware-ele-imx-2.0.4-93492e0.bin"
  fi
  log_ok "Step 4 complete"
  pause_if_enabled
}

step5_stage_inputs() {
  step "Step 5: Stage required binaries into inputs/"
  check_host_deps
  ensure_workspace

  step "Copy required binaries into inputs/"
  [[ -f imx-atf/build/imx93/release/bl31.bin ]] || die "Missing bl31.bin (run Step 1 first)"
  [[ -f uboot-imx/u-boot.bin ]] || die "Missing u-boot.bin (run Step 2 first)"
  [[ -f uboot-imx/spl/u-boot-spl.bin ]] || die "Missing u-boot-spl.bin (run Step 2 first)"

  cp -f imx-atf/build/imx93/release/bl31.bin inputs/bl31.bin
  cp -f uboot-imx/u-boot.bin inputs/u-boot.bin
  cp -f uboot-imx/spl/u-boot-spl.bin inputs/u-boot-spl.bin

  DDR_DIR="firmware-imx-8.30-3fa84fd/firmware/ddr/synopsys"
  [[ -f "${DDR_DIR}/${DDR_IMEM_1D}" ]] || die "DDR file missing: ${DDR_DIR}/${DDR_IMEM_1D}"
  cp -f "${DDR_DIR}/${DDR_IMEM_1D}" inputs/
  cp -f "${DDR_DIR}/${DDR_IMEM_2D}" inputs/
  cp -f "${DDR_DIR}/${DDR_DMEM_1D}" inputs/
  cp -f "${DDR_DIR}/${DDR_DMEM_2D}" inputs/

  [[ -f firmware-ele-imx-2.0.4-93492e0/mx93a1-ahab-container.img ]] || die "Missing ELE container after EULA extraction"
  cp -f firmware-ele-imx-2.0.4-93492e0/mx93a1-ahab-container.img inputs/

  log_ok "Step 5 complete"
  pause_if_enabled
}

step6_setup_spsdk() {
  step "Step 6: Create/activate venv + install SPSDK"
  check_host_deps
  ensure_workspace
  spsdk_prereqs
  log_ok "Step 6 complete"
  pause_if_enabled
}

step7_keys() {
  step "Step 7: Generate & verify keys (ECC-384 secp384r1) + compute SRKH"
  check_host_deps
  ensure_workspace
  spsdk_prereqs

  step "Generate ECC-384 keys (SRK set)"
  nxpcrypto key generate -k secp384r1 -o keys/srk0.pem --force
  nxpcrypto key generate -k secp384r1 -o keys/srk1.pem --force
  nxpcrypto key generate -k secp384r1 -o keys/srk2.pem --force
  nxpcrypto key generate -k secp384r1 -o keys/srk3.pem --force

  nxpcrypto key verify -k1 keys/srk0.pem -k2 keys/srk0.pub
  nxpcrypto key verify -k1 keys/srk1.pem -k2 keys/srk1.pub
  nxpcrypto key verify -k1 keys/srk2.pem -k2 keys/srk2.pub
  nxpcrypto key verify -k1 keys/srk3.pem -k2 keys/srk3.pub

  [[ -f keys/srk0.pub && -f keys/srk1.pub && -f keys/srk2.pub && -f keys/srk3.pub ]] || \
    die "Expected keys/srk*.pub to exist"

  step "Compute SRK table + SRKH fuse values"
  python3 <<'PY'
import os
from spsdk.crypto.utils import extract_public_key
from spsdk.image.ahab.ahab_srk import SRKTable
from spsdk.utils.misc import Endianness, write_file

WORKSPACE = os.getcwd()
DATA_DIR = os.path.join(WORKSPACE, "keys")
SRK_KEYS = ["srk0.pub","srk1.pub","srk2.pub","srk3.pub"]

ahab_srk = SRKTable()
for key in SRK_KEYS:
    key_path = os.path.join(DATA_DIR, key)
    print(f"Loading SRK key: {key_path}")
    ahab_srk.add_record(extract_public_key(key_path))

ahab_srk.update_fields()
ahab_srk_hash = ahab_srk.compute_srk_hash()

print("\nSRK TABLE:")
print(ahab_srk)

srk_binary = ahab_srk.export()
srk_binary_path = os.path.join(WORKSPACE, "srk_table.bin")
print("\nSRK table (binary hex):")
print(srk_binary.hex())

write_file(srk_binary, srk_binary_path, mode="wb")
print(f"\nSRK table saved to: {srk_binary_path}")

print("\nSRKH fuse values (OTP 128–135):")
for i in range(0, len(ahab_srk_hash), 4):
    word = int.from_bytes(ahab_srk_hash[i : i + 4], byteorder=Endianness.LITTLE.value)
    print(f"SRKH[{i//4}] = 0x{word:08X}")
PY

  log_ok "Step 7 complete (keys + SRKH ready)"
  pause_if_enabled
}

step8_yaml() {
  normalize_boot_media
  step "Step 8: Write YAML configs (container sets + bootable-image) [media=${BOOT_MEDIA}]"
  check_host_deps
  ensure_workspace

  mkdir -p "${OUTPUTS_RUN_DIR}/spl_img" "${OUTPUTS_RUN_DIR}/atf_img"

  # NOTE:
  #  - target_memory is "standard" for SD/eMMC flows
  #  - for serial_downloader flows, use "serial_downloader" (SPSDK examples)
  cat > inputs/u-boot-spl-container-img_config.yaml <<YAML
family: mimx9352
revision: a1
target_memory: standard
output: ../${OUTPUTS_RUN_DIR}/spl_img/u-boot-spl-container.img

containers:
  - binary_container:
      path: inputs/mx93a1-ahab-container.img
  - container:
      srk_set: oem
      used_srk_id: 0
      signer: type=file;file_path=keys/srk0.pem
      images:
        - lpddr_imem_1d: inputs/lpddr4_imem_1d_v202201.bin
          lpddr_imem_2d: inputs/lpddr4_imem_2d_v202201.bin
          lpddr_dmem_1d: inputs/lpddr4_dmem_1d_v202201.bin
          lpddr_dmem_2d: inputs/lpddr4_dmem_2d_v202201.bin
          spl_ddr: inputs/u-boot-spl.bin
      srk_table:
        srk_array:
          - keys/srk0.pub
          - keys/srk1.pub
          - keys/srk2.pub
          - keys/srk3.pub
YAML

  cat > inputs/u-boot-atf-container-img_config.yaml <<YAML
family: mimx9352
revision: a1
target_memory: standard
output: ../${OUTPUTS_RUN_DIR}/atf_img/u-boot-atf-container.img

containers:
  - container:
      srk_set: oem
      used_srk_id: 0
      signer: type=file;file_path=keys/srk0.pem
      images:
        - atf: inputs/bl31.bin
        - uboot: inputs/u-boot.bin
      srk_table:
        srk_array:
          - keys/srk0.pub
          - keys/srk1.pub
          - keys/srk2.pub
          - keys/srk3.pub
YAML

  # Bootable-image config:
  #  - memory_type: sd | emmc | serial_downloader
  #  - init_offset: keep 0 unless you have a specific offset requirement
  cat > inputs/u-boot-bootable.yaml <<YAML
family: mimx9352
revision: a1
memory_type: ${BOOT_MEDIA}
init_offset: 0
primary_image_container_set: ${OUTPUTS_RUN_DIR}/spl_img/u-boot-spl-container.img
secondary_image_container_set: ${OUTPUTS_RUN_DIR}/atf_img/u-boot-atf-container.img
YAML

  log_ok "Step 8 complete"
  log_i  "Bootable-image memory_type=${BOOT_MEDIA}"
  log_i  "Run outputs folder: ${WORKDIR_ABS}/${OUTPUTS_RUN_DIR}"
  pause_if_enabled
}

step9_export_signed_image() {
  normalize_boot_media
  step "Step 9: Export signed images [media=${BOOT_MEDIA}]"
  check_host_deps
  ensure_workspace
  spsdk_prereqs

  [[ -f inputs/u-boot-spl-container-img_config.yaml ]] || die "Missing YAML (run Step 8)"
  [[ -f inputs/u-boot-atf-container-img_config.yaml ]] || die "Missing YAML (run Step 8)"
  [[ -f inputs/u-boot-bootable.yaml ]] || die "Missing YAML (run Step 8)"

  if [[ "$SKIP_KEYGEN" -eq 1 ]]; then
    [[ -f keys/srk0.pem && -f keys/srk0.pub && -f keys/srk1.pub && -f keys/srk2.pub && -f keys/srk3.pub ]] || \
      die "SKIP_KEYGEN enabled but keys are missing. Provide existing keys in ${WORKDIR_ABS}/keys/ (srk0.pem + srk*.pub)."
  fi

  step "nxpimage ahab export -> ${OUTPUTS_RUN_DIR}/spl_img/u-boot-spl-container.img"
  nxpimage -v ahab export -c inputs/u-boot-spl-container-img_config.yaml

  step "nxpimage ahab export -> ${OUTPUTS_RUN_DIR}/atf_img/u-boot-atf-container.img"
  nxpimage -v ahab export -c inputs/u-boot-atf-container-img_config.yaml

  local OUT_BIN
  OUT_BIN="${OUTPUTS_RUN_DIR}/signed-container_${RUN_ID}_${BOARD_TARGET}_${BOOT_MEDIA}.bin"
  LAST_OUT_BIN="${OUT_BIN}"

  step "nxpimage bootable-image export -> ${OUT_BIN}"
  nxpimage bootable-image export --config inputs/u-boot-bootable.yaml --output "${OUT_BIN}"

  # Convenience: create/refresh "latest" pointers without overwriting historical runs.
  # These links live in ./outputs, so targets must be relative to that directory.
  local latest_run_target latest_bin_target
  latest_run_target="${OUTPUTS_RUN_DIR#outputs/}"
  latest_bin_target="${OUT_BIN#outputs/}"
  ln -sfn "${latest_run_target}" outputs/latest
  ln -sfn "${latest_bin_target}" outputs/latest-signed-container.bin

  step "List run outputs"
  ls -alR "${OUTPUTS_RUN_DIR}"

  deactivate || true
  log_ok "Step 9 complete"
  log_i  "Run outputs folder: ${WORKDIR_ABS}/${OUTPUTS_RUN_DIR}"
  log_i  "Signed image:        ${WORKDIR_ABS}/${OUT_BIN}"
  log_i  "Latest pointers:     ${WORKDIR_ABS}/outputs/latest  and  ${WORKDIR_ABS}/outputs/latest-signed-container.bin"
  pause_if_enabled
}

step10_verify_signed_image() {
  normalize_boot_media
  step "Step 10: Verify signed bootable-image [media=${BOOT_MEDIA}]"
  check_host_deps
  ensure_workspace
  spsdk_prereqs

  local verify_bin
  if [[ -n "${LAST_OUT_BIN}" && -f "${LAST_OUT_BIN}" ]]; then
    verify_bin="${LAST_OUT_BIN}"
  elif [[ -f outputs/latest-signed-container.bin ]]; then
    verify_bin="outputs/latest-signed-container.bin"
  else
    die "No signed image found to verify. Run Step 9 first (or ensure outputs/latest-signed-container.bin exists)."
  fi

  step "nxpimage bootable-image verify"
  nxpimage -vv bootable-image verify --family mimx9352 --revision a1 --mem-type "${BOOT_MEDIA}" --binary "${verify_bin}"

  deactivate || true
  log_ok "Step 10 complete"
  log_i  "Run outputs folder: ${WORKDIR_ABS}/${OUTPUTS_RUN_DIR}"
  log_i  "Signed image:        ${WORKDIR_ABS}/${OUT_BIN}"
  log_i  "Latest pointers:     ${WORKDIR_ABS}/outputs/latest  and  ${WORKDIR_ABS}/outputs/latest-signed-container.bin"
  log_i  "Verified image:      ${WORKDIR_ABS}/${verify_bin}"
  pause_if_enabled
}

run_all() {
  step1_build_atf
  step2_build_uboot
  step3_download_ddr
  step4_download_ele
  step5_stage_inputs
  step6_setup_spsdk
  if [[ "$SKIP_KEYGEN" -eq 0 ]]; then
    step7_keys
  else
    log_w "Skipping Step 7 (key generation) due to --all-no-keys"
    pause_if_enabled
  fi
  step8_yaml
  step9_export_signed_image
  step10_verify_signed_image
}

run_steps() {
  local -A seen=()
  local ordered=()
  local s
  for s in "${STEPS_TO_RUN[@]}"; do
    if [[ -z "${seen[$s]+x}" ]]; then
      seen[$s]=1
      ordered+=("$s")
    fi
  done

  for s in "${ordered[@]}"; do
    case "$s" in
      1) step1_build_atf ;;
      2) step2_build_uboot ;;
      3) step3_download_ddr ;;
      4) step4_download_ele ;;
      5) step5_stage_inputs ;;
      6) step6_setup_spsdk ;;
      7)
        if [[ "$SKIP_KEYGEN" -eq 1 ]]; then
          log_w "Skipping Step 7 (key generation) due to --all-no-keys"
          pause_if_enabled
        else
          step7_keys
        fi
        ;;
      8) step8_yaml ;;
      9) step9_export_signed_image ;;
      10) step10_verify_signed_image ;;
    esac
  done
}

menu() {
  apply_no_color
  setup_logging
  normalize_board_target
  normalize_boot_media
  init_run_outputs

  log_i "Script version: ${SCRIPT_VERSION}"
  log_i "WORKDIR=${WORKDIR_ABS}"
  log_i "Board target: ${BOARD_TARGET} (U-Boot defconfig: $(uboot_defconfig_for_target))"
  log_i "Boot media: ${BOOT_MEDIA} (bootable-image memory_type)"
  log_i "Run outputs folder: ${WORKDIR_ABS}/${OUTPUTS_RUN_DIR}"

  echo
  echo -e "${C_BOLD}Select an action:${C_RESET}"
  PS3="$(echo -e "${C_BOLD}Choice> ${C_RESET}")"
  select opt in \
    "Run ALL steps (1..10) [board=${BOARD_TARGET}, media=${BOOT_MEDIA}]" \
    "Run ALL steps (skip key generation) [board=${BOARD_TARGET}, media=${BOOT_MEDIA}]" \
    "Toggle pause between steps" \
    "Set board target (EVK/FRDM)" \
    "Set boot media (SD/eMMC/Serial Downloader)" \
    "Step 1: Build ARM Trusted Firmware (imx-atf)" \
    "Step 2: Build U-Boot (uboot-imx) [EVK/FRDM]" \
    "Step 3: Download DDR firmware package" \
    "Step 4: Download ELE firmware container package" \
    "Step 5: Stage required binaries into inputs/" \
    "Step 6: Setup SPSDK venv/tools" \
    "Step 7: Generate & verify keys + Compute SRK Table" \
    "Step 8: Write YAML configs [SD/eMMC/Serial Downloader]" \
    "Step 9: Export signed image" \
    "Step 10: Verify signed image" \
    "Delete work folder (${WORKDIR_ABS})" \
    "Quit"
  do
    case "$REPLY" in
      1) SKIP_KEYGEN=0; run_all; break ;;
      2) SKIP_KEYGEN=1; run_all; break ;;
      3)
        if [[ "$PAUSE_BETWEEN_STEPS" -eq 0 ]]; then
          PAUSE_BETWEEN_STEPS=1
          log_i "Pause between steps: ON"
        else
          PAUSE_BETWEEN_STEPS=0
          log_i "Pause between steps: OFF"
        fi
        continue
        ;;
      4)
        echo
        echo "Select board target:"
        select b in "EVK (imx93_11x11_evk_defconfig)" "FRDM (imx93_11x11_frdm_defconfig)" "Cancel"; do
          case "$REPLY" in
            1) BOARD_TARGET="evk"; normalize_board_target; init_run_outputs; log_i "Board target set -> ${BOARD_TARGET}"; break ;;
            2) BOARD_TARGET="frdm"; normalize_board_target; init_run_outputs; log_i "Board target set -> ${BOARD_TARGET}"; break ;;
            3) break ;;
            *) log_w "Invalid selection."; continue ;;
          esac
        done
        continue
        ;;
      5)
        echo
        echo "Select boot media:"
        select m in "SD (memory_type: sd)" "eMMC (memory_type: emmc)" "Serial Downloader (memory_type: serial_downloader)" "Cancel"; do
          case "$REPLY" in
            1) BOOT_MEDIA="sd"; normalize_boot_media; init_run_outputs; log_i "Boot media set -> ${BOOT_MEDIA}"; break ;;
            2) BOOT_MEDIA="emmc"; normalize_boot_media; init_run_outputs; log_i "Boot media set -> ${BOOT_MEDIA}"; break ;;
            3) BOOT_MEDIA="serial_downloader"; normalize_boot_media; init_run_outputs; log_i "Boot media set -> ${BOOT_MEDIA}"; break ;;
            4) break ;;
            *) log_w "Invalid selection."; continue ;;
          esac
        done
        continue
        ;;
      6) step1_build_atf; break ;;
      7) step2_build_uboot; break ;;
      8) step3_download_ddr; break ;;
      9) step4_download_ele; break ;;
      10) step5_stage_inputs; break ;;
      11) step6_setup_spsdk; break ;;
      12) step7_keys; break ;;
      13) step8_yaml; break ;;
      14) step9_export_signed_image; break ;;
      15) step10_verify_signed_image; break ;;
      16)
        delete_workdir
        continue
        ;;
      17) log_i "Bye."; break ;;
      *) log_w "Invalid selection."; continue ;;
    esac
  done
}

# ----------------------------- Main ------------------------------------------
parse_args "$@"
apply_no_color
setup_logging

normalize_board_target
normalize_boot_media
init_run_outputs

case "$RUN_MODE" in
  menu)
    menu
    ;;
  all)
    log_i "Script version: ${SCRIPT_VERSION}"
    log_i "Running all steps (board=${BOARD_TARGET}, media=${BOOT_MEDIA}, skip keygen: $SKIP_KEYGEN, pause: $PAUSE_BETWEEN_STEPS)"
    log_i "Run outputs folder: ${WORKDIR_ABS}/${OUTPUTS_RUN_DIR}"
    run_all
    ;;
  steps)
    if [[ ${#STEPS_TO_RUN[@]} -eq 0 ]]; then
      die "No steps provided. Use --step N or --all or --menu."
    fi
    log_i "Script version: ${SCRIPT_VERSION}"
    log_i "Running steps: ${STEPS_TO_RUN[*]} (board=${BOARD_TARGET}, media=${BOOT_MEDIA}, pause: $PAUSE_BETWEEN_STEPS)"
    log_i "Run outputs folder: ${WORKDIR_ABS}/${OUTPUTS_RUN_DIR}"
    run_steps
    ;;
  *)
    die "Internal error: unknown RUN_MODE=$RUN_MODE"
    ;;
esac
