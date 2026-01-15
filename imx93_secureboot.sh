#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# i.MX93 Secure Boot Helper Script
# Version: 6.7
# -----------------------------------------------------------------------------
SCRIPT_VERSION="6.7"

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
#  - Run all without generating keys (skips Step 5)
#  - Step 2: choose board target (EVK vs FRDM)
#  - Step 6/7: choose boot media (sd vs emmc)
#
# Output:
#   work/outputs/signed-sd-flash.bin   (name kept for compatibility)
# -----------------------------------------------------------------------------

# ----------------------------- Defaults --------------------------------------
WORKDIR="${WORKDIR:-work}"
DDR_EULA_URL="${DDR_EULA_URL:-https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/firmware-imx-8.21.bin}"
ELE_EULA_URL="${ELE_EULA_URL:-https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/firmware-sentinel-0.11.bin}"

# pick the v202201 DDR files like typical examples
DDR_IMEM_1D="lpddr4_imem_1d_v202201.bin"
DDR_IMEM_2D="lpddr4_imem_2d_v202201.bin"
DDR_DMEM_1D="lpddr4_dmem_1d_v202201.bin"
DDR_DMEM_2D="lpddr4_dmem_2d_v202201.bin"

# Behavior toggles
NO_COLOR=0
PAUSE_BETWEEN_STEPS=0
SKIP_KEYGEN=0

# Target selectors
BOARD_TARGET="${BOARD_TARGET:-evk}"   # evk | frdm
BOOT_MEDIA="${BOOT_MEDIA:-sd}"        # sd | emmc

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
    emmc|eMMC|sd_emmc) BOOT_MEDIA="emmc" ;;
    *) die "Invalid BOOT_MEDIA='$BOOT_MEDIA' (use: sd or emmc)" ;;
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
  --all                  Run all steps sequentially (1..7)
  --step N               Run a single step (1..7). Can be repeated.

Convenience step flags (same as --step):
  --atf                  Step 1: Build ARM Trusted Firmware (imx-atf)
  --uboot                Step 2: Build U-Boot (uboot-imx)
  --download             Step 3: Download DDR + ELE and stage inputs
  --spsdk                Step 4: Create/activate venv + install SPSDK
  --keys                 Step 5: Generate & verify keys + Compute SRK Table
  --yaml                 Step 6: Write YAML configs
  --export               Step 7: Export signed images + verify

Target selection:
  --board evk|frdm        Select U-Boot defconfig (default: evk)
  --media sd|emmc         Select bootable-image memory_type (default: sd)

All-step options:
  --all-no-keys          Run all steps but skip key generation (skips Step 5)
  --pause                Pause between each step (works with --all/--all-no-keys)

Other options:
  --workdir DIR          Working directory (default: work)
  --log FILE             Save all stdout+stderr to FILE (also prints to console)
  --no-color             Disable colored output
  -h, --help             Show this help

Examples:
  ./imx93_secureboot.sh --all --board frdm --media emmc --pause --log run.log
  ./imx93_secureboot.sh --step 2 --board frdm
  ./imx93_secureboot.sh --step 6 --media emmc
TXT
}

add_step() {
  local n="$1"
  case "$n" in
    1|2|3|4|5|6|7) STEPS_TO_RUN+=("$n") ;;
    *) die "Invalid step: $n (valid: 1..7)" ;;
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
      --download) RUN_MODE="steps"; add_step 3; shift ;;
      --spsdk) RUN_MODE="steps"; add_step 4; shift ;;
      --keys) RUN_MODE="steps"; add_step 5; shift ;;
      --yaml) RUN_MODE="steps"; add_step 6; shift ;;
      --export) RUN_MODE="steps"; add_step 7; shift ;;

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

step3_download_stage() {
  step "Step 3: Download DDR firmware + ELE container, stage inputs/"
  check_host_deps
  ensure_workspace

  if [[ ! -f firmware-imx-8.21.bin ]]; then
    step "Download DDR firmware (EULA)"
    wget -O firmware-imx-8.21.bin "${DDR_EULA_URL}"
    chmod +x firmware-imx-8.21.bin
    ./firmware-imx-8.21.bin --auto-accept
  else
    log_i "DDR EULA package already present: firmware-imx-8.21.bin"
  fi

  if [[ ! -f firmware-sentinel-0.11.bin ]]; then
    step "Download ELE firmware container (EULA)"
    wget -O firmware-sentinel-0.11.bin "${ELE_EULA_URL}"
    chmod +x firmware-sentinel-0.11.bin
    ./firmware-sentinel-0.11.bin --auto-accept
  else
    log_i "ELE EULA package already present: firmware-sentinel-0.11.bin"
  fi

  step "Copy required binaries into inputs/"
  [[ -f imx-atf/build/imx93/release/bl31.bin ]] || die "Missing bl31.bin (run Step 1 first)"
  [[ -f uboot-imx/u-boot.bin ]] || die "Missing u-boot.bin (run Step 2 first)"
  [[ -f uboot-imx/spl/u-boot-spl.bin ]] || die "Missing u-boot-spl.bin (run Step 2 first)"

  cp -f imx-atf/build/imx93/release/bl31.bin inputs/bl31.bin
  cp -f uboot-imx/u-boot.bin inputs/u-boot.bin
  cp -f uboot-imx/spl/u-boot-spl.bin inputs/u-boot-spl.bin

  DDR_DIR="firmware-imx-8.21/firmware/ddr/synopsys"
  [[ -f "${DDR_DIR}/${DDR_IMEM_1D}" ]] || die "DDR file missing: ${DDR_DIR}/${DDR_IMEM_1D}"
  cp -f "${DDR_DIR}/${DDR_IMEM_1D}" inputs/
  cp -f "${DDR_DIR}/${DDR_IMEM_2D}" inputs/
  cp -f "${DDR_DIR}/${DDR_DMEM_1D}" inputs/
  cp -f "${DDR_DIR}/${DDR_DMEM_2D}" inputs/

  [[ -f firmware-sentinel-0.11/mx93a1-ahab-container.img ]] || die "Missing ELE container after EULA extraction"
  cp -f firmware-sentinel-0.11/mx93a1-ahab-container.img inputs/

  log_ok "Step 3 complete"
  pause_if_enabled
}

step4_setup_spsdk() {
  step "Step 4: Create/activate venv + install SPSDK"
  check_host_deps
  ensure_workspace
  spsdk_prereqs
  log_ok "Step 4 complete"
  pause_if_enabled
}

step5_keys() {
  step "Step 5: Generate & verify keys (ECC-384 secp384r1) + compute SRKH"
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

  log_ok "Step 5 complete (keys + SRKH ready)"
  pause_if_enabled
}

step6_yaml() {
  normalize_boot_media
  step "Step 6: Write YAML configs (container sets + bootable-image) [media=${BOOT_MEDIA}]"
  check_host_deps
  ensure_workspace

  mkdir -p outputs/spl_img outputs/atf_img

  cat > inputs/u-boot-spl-container-img_config.yaml <<'YAML'
family: mimx9352
revision: a1
target_memory: sd_emmc
output: ../outputs/spl_img/u-boot-spl-container.img

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

  cat > inputs/u-boot-atf-container-img_config.yaml <<'YAML'
family: mimx9352
revision: a1
target_memory: sd_emmc
output: ../outputs/atf_img/u-boot-atf-container.img

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

  cat > inputs/u-boot-bootable.yaml <<YAML
family: mimx9352
revision: a1
memory_type: ${BOOT_MEDIA}
init_offset: 0
primary_image_container_set: outputs/spl_img/u-boot-spl-container.img
secondary_image_container_set: outputs/atf_img/u-boot-atf-container.img
YAML

  log_ok "Step 6 complete (wrote inputs/u-boot-bootable.yaml with memory_type=${BOOT_MEDIA})"
  pause_if_enabled
}

step7_export_verify() {
  normalize_boot_media
  step "Step 7: Export signed images + verify bootable-image [media=${BOOT_MEDIA}]"
  check_host_deps
  ensure_workspace
  spsdk_prereqs

  [[ -f inputs/u-boot-spl-container-img_config.yaml ]] || die "Missing YAML (run Step 6)"
  [[ -f inputs/u-boot-atf-container-img_config.yaml ]] || die "Missing YAML (run Step 6)"
  [[ -f inputs/u-boot-bootable.yaml ]] || die "Missing YAML (run Step 6)"

  if [[ "$SKIP_KEYGEN" -eq 1 ]]; then
    [[ -f keys/srk0.pem && -f keys/srk0.pub && -f keys/srk1.pub && -f keys/srk2.pub && -f keys/srk3.pub ]] || \
      die "SKIP_KEYGEN enabled but keys are missing. Provide existing keys in ${WORKDIR_ABS}/keys/ (srk0.pem + srk*.pub)."
  fi

  step "nxpimage ahab export -> outputs/spl_img/u-boot-spl-container.img"
  nxpimage -v ahab export -c inputs/u-boot-spl-container-img_config.yaml

  step "nxpimage ahab export -> outputs/atf_img/u-boot-atf-container.img"
  nxpimage -v ahab export -c inputs/u-boot-atf-container-img_config.yaml

  step "nxpimage bootable-image export -> outputs/signed-sd-flash.bin"
  nxpimage bootable-image export --config inputs/u-boot-bootable.yaml --output outputs/signed-sd-flash.bin

  ls -alR outputs

  step "nxpimage bootable-image verify"
  nxpimage -vv bootable-image verify --family mimx9352 --revision a1 --mem-type "${BOOT_MEDIA}" --binary outputs/signed-sd-flash.bin

  deactivate || true
  log_ok "Step 7 complete"
  pause_if_enabled
}

run_all() {
  step1_build_atf
  step2_build_uboot
  step3_download_stage
  step4_setup_spsdk
  if [[ "$SKIP_KEYGEN" -eq 0 ]]; then
    step5_keys
  else
    log_w "Skipping Step 5 (key generation) due to --all-no-keys"
    pause_if_enabled
  fi
  step6_yaml
  step7_export_verify
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
      3) step3_download_stage ;;
      4) step4_setup_spsdk ;;
      5)
        if [[ "$SKIP_KEYGEN" -eq 1 ]]; then
          log_w "Skipping Step 5 (key generation) due to --all-no-keys"
          pause_if_enabled
        else
          step5_keys
        fi
        ;;
      6) step6_yaml ;;
      7) step7_export_verify ;;
    esac
  done
}

menu() {
  apply_no_color
  setup_logging
  normalize_board_target
  normalize_boot_media

  log_i "Script version: ${SCRIPT_VERSION}"
  log_i "WORKDIR=${WORKDIR_ABS}"
  log_i "Board target: ${BOARD_TARGET} (U-Boot defconfig: $(uboot_defconfig_for_target))"
  log_i "Boot media: ${BOOT_MEDIA} (bootable-image memory_type)"

  echo
  echo -e "${C_BOLD}Select an action:${C_RESET}"
  PS3="$(echo -e "${C_BOLD}Choice> ${C_RESET}")"
  select opt in \
    "Run ALL steps (1..7) [board=${BOARD_TARGET}, media=${BOOT_MEDIA}]" \
    "Run ALL steps (skip key generation) [board=${BOARD_TARGET}, media=${BOOT_MEDIA}]" \
    "Toggle pause between steps" \
    "Set board target (EVK/FRDM)" \
    "Set boot media (SD/eMMC)" \
    "Step 1: Build ARM Trusted Firmware (imx-atf)" \
    "Step 2: Build U-Boot (uboot-imx) [EVK/FRDM]" \
    "Step 3: Download DDR+ELE, stage inputs/" \
    "Step 4: Setup SPSDK venv/tools" \
    "Step 5: Generate & verify keys + Compute SRK Table" \
    "Step 6: Write YAML configs [SD/eMMC]" \
    "Step 7: Export signed images + verify" \
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
            1) BOARD_TARGET="evk"; normalize_board_target; log_i "Board target set -> ${BOARD_TARGET}"; break ;;
            2) BOARD_TARGET="frdm"; normalize_board_target; log_i "Board target set -> ${BOARD_TARGET}"; break ;;
            3) break ;;
            *) log_w "Invalid selection."; continue ;;
          esac
        done
        continue
        ;;
      5)
        echo
        echo "Select boot media:"
        select m in "SD (memory_type: sd)" "eMMC (memory_type: emmc)" "Cancel"; do
          case "$REPLY" in
            1) BOOT_MEDIA="sd"; normalize_boot_media; log_i "Boot media set -> ${BOOT_MEDIA}"; break ;;
            2) BOOT_MEDIA="emmc"; normalize_boot_media; log_i "Boot media set -> ${BOOT_MEDIA}"; break ;;
            3) break ;;
            *) log_w "Invalid selection."; continue ;;
          esac
        done
        continue
        ;;
      6) step1_build_atf; break ;;
      7) step2_build_uboot; break ;;
      8) step3_download_stage; break ;;
      9) step4_setup_spsdk; break ;;
      10) step5_keys; break ;;
      11) step6_yaml; break ;;
      12) step7_export_verify; break ;;
      13) log_i "Bye."; break ;;
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

case "$RUN_MODE" in
  menu)
    menu
    ;;
  all)
    log_i "Script version: ${SCRIPT_VERSION}"
    log_i "Running all steps (board=${BOARD_TARGET}, media=${BOOT_MEDIA}, skip keygen: $SKIP_KEYGEN, pause: $PAUSE_BETWEEN_STEPS)"
    run_all
    ;;
  steps)
    if [[ ${#STEPS_TO_RUN[@]} -eq 0 ]]; then
      die "No steps provided. Use --step N or --all or --menu."
    fi
    log_i "Script version: ${SCRIPT_VERSION}"
    log_i "Running steps: ${STEPS_TO_RUN[*]} (board=${BOARD_TARGET}, media=${BOOT_MEDIA}, pause: $PAUSE_BETWEEN_STEPS)"
    run_steps
    ;;
  *)
    die "Internal error: unknown RUN_MODE=$RUN_MODE"
    ;;
esac
