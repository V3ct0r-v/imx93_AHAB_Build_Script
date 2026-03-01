# i.MX93 Secure Boot Automation (AHAB + SPSDK)

**Current Version:** 6.9

This repository provides a menu-driven and CLI-friendly Bash script (`imx93_secureboot.sh`) to build, sign, package, export, and verify secure boot images for NXP i.MX93 using AHAB and SPSDK.

The script supports EVK and FRDM targets and can generate bootable images for `sd`, `emmc`, and `serial_downloader` workflows.

## Release Notes

| Version | Status | Summary |
|---|---|---|
| 6.7 | Initial release | Initial menu/CLI workflow for building TF-A + U-Boot, downloading firmware blobs, generating keys, writing YAML, and exporting signed images. |
| 6.8 | Previous release | Split download/staging into separate steps (DDR, ELE, stage inputs), split export/verify into separate steps, added `--verify`, added menu option to delete work folder, fixed `outputs/latest*` symlink targets, and improved output handling. |
| 6.9 | Current release | Added Yocto metadata-driven DDR/ELE package selection in the interactive menu, replaced hardcoded firmware package filenames with the selected values, and added firmware catalog environment knobs (`FW_ENUM_BRANCH`, `FW_CATALOG_LIMIT`, `FW_MIRROR_BASE_URL`). |

## Features

- End-to-end i.MX93 secure boot automation (AHAB + SPSDK)
- Interactive menu and CLI step execution
- Board target selection: `evk` or `frdm`
- Boot media selection: `sd`, `emmc`, or `serial_downloader`
- 10-step workflow with separable download, export, and verify phases
- Optional pause between steps
- Optional key generation skip (`--all-no-keys`) for key reuse
- Interactive Yocto metadata-driven DDR/ELE firmware package selection
- Firmware catalog environment knobs: `FW_ENUM_BRANCH`, `FW_CATALOG_LIMIT`, `FW_MIRROR_BASE_URL`
- Auto-created convenience symlinks in `work/outputs/`:
- `latest` -> most recent run output directory
- `latest-signed-container.bin` -> most recent exported signed image
- Menu option to delete the work folder with typed confirmation
- Optional logging to file and colored output

## Secure Boot Flow (High Level)

1. ROM + ELE verify AHAB containers using SRK fuses.
2. SPL, TF-A, and U-Boot are authenticated via AHAB.
3. SPSDK exports a bootable signed image (`nxpimage bootable-image export`).
4. SPSDK can verify the exported image (`nxpimage bootable-image verify`).

## Supported Targets

| Component | Support |
|---|---|
| SoC | i.MX93 (`mimx9352`) |
| Boards | EVK, FRDM |
| Boot media (`memory_type`) | `sd`, `emmc`, `serial_downloader` |
| Secure boot | AHAB |
| Signing keys | ECC-384 (`secp384r1`) |
| Tools | SPSDK (`nxpimage`, `nxpcrypto`) |

## Workflow Steps (Current)

| Step | Action |
|---|---|
| 1 | Build ARM Trusted Firmware (`imx-atf`) |
| 2 | Build U-Boot (`uboot-imx`) |
| 3 | Download DDR firmware package (EULA) |
| 4 | Download ELE firmware container package (EULA) |
| 5 | Stage required binaries into `inputs/` |
| 6 | Create/activate Python venv and install SPSDK |
| 7 | Generate and verify SRK keys, compute SRKH |
| 8 | Write AHAB + bootable-image YAML configs |
| 9 | Export signed image |
| 10 | Verify signed image |

## CLI Usage

```bash
./imx93_secureboot.sh --help
```

### Run Modes

- `--menu` (default): interactive menu
- `--all`: run steps `1..10`
- `--all-no-keys`: run all but skip Step 7 (reuse existing keys)
- `--step N`: run one or more explicit steps (repeatable)

### Convenience Flags (Step Aliases)

- `--atf` -> Step 1
- `--uboot` -> Step 2
- `--download-ddr` -> Step 3
- `--download-ele` -> Step 4
- `--stage-inputs` -> Step 5
- `--download` -> Steps 3, 4, and 5 (compatibility alias)
- `--spsdk` -> Step 6
- `--keys` -> Step 7
- `--yaml` -> Step 8
- `--export` -> Step 9
- `--verify` -> Step 10

### Target Selection

- `--board evk|frdm` (default: `frdm`)
- `--media sd|emmc|serial_downloader` (default: `serial_downloader`)

### Firmware Catalog Selection

The interactive menu includes a DDR/ELE package selector that derives available package versions from Yocto metadata.

Environment knobs:

- `FW_ENUM_BRANCH` (default: `imx-linux-walnascar`)
- `FW_CATALOG_LIMIT` (default: `0`, meaning all releases)
- `FW_MIRROR_BASE_URL` (default: `https://www.nxp.com/lgfiles/NMG/MAD/YOCTO`)

### Other Options

- `--workdir DIR` (default: `work`)
- `--log FILE`
- `--pause`
- `--no-color`
- `-h`, `--help`

## Examples

```bash
# Interactive menu
./imx93_secureboot.sh

# Interactive menu with the firmware selector limited to the latest 3 releases
FW_CATALOG_LIMIT=3 ./imx93_secureboot.sh

# Full flow, pause between steps, save log
./imx93_secureboot.sh --all --pause --log run.log

# Full flow without generating new keys (keys must already exist in work/keys)
./imx93_secureboot.sh --all-no-keys --board frdm --media emmc

# Build + download/stage only
./imx93_secureboot.sh --atf --uboot --download

# Export only (after YAML + keys are ready)
./imx93_secureboot.sh --export --board frdm --media serial_downloader

# Verify the latest exported image
./imx93_secureboot.sh --verify --board frdm --media serial_downloader
```

## Working Directory Layout

The script uses a work directory (default `work/`) and creates:

- `work/inputs/` for staged binaries and generated YAML configs
- `work/keys/` for SRK keys and public keys
- `work/outputs/<run_id>_<board>_<media>/` for per-run exported artifacts

Convenience symlinks in `work/outputs/`:

- `latest` -> latest run directory
- `latest-signed-container.bin` -> latest exported signed image

## Interactive Menu Notes

The menu includes actions to:

- run the full workflow (with or without key generation)
- run any individual step
- switch board target and boot media
- select DDR and ELE package versions from Yocto metadata
- toggle pause between steps
- delete the work folder (`WORKDIR`) with typed `DELETE` confirmation

## Dependencies

The script checks for common build and tooling dependencies, including:

```bash
git
make
wget
python3
python3-pip
python3-venv
gcc
gcc-aarch64-linux-gnu
binutils-aarch64-linux-gnu
libssl-dev
libncurses-dev
bc
bison
flex
util-linux
```
