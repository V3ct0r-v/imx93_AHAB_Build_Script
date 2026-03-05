# i.MX93 Secure Boot Automation (AHAB + SPSDK)

**Current Version:** 7.0

This repository provides a menu-driven and CLI-friendly Bash script (`imx93_secureboot.sh`) to build, sign, package, export, and verify secure boot artifacts for NXP i.MX93 using AHAB and SPSDK.

The script supports EVK and FRDM targets and can generate bootloader images for `sd`, `emmc`, and `serial_downloader` workflows, plus a signed OS container flow.

## Release Notes

| Version | Status | Summary |
|---|---|---|
| 6.7 | Initial release | Initial menu/CLI workflow for building TF-A + U-Boot, downloading firmware blobs, generating keys, writing YAML, and exporting signed images. |
| 6.8 | Stable | Split download/staging into separate steps (DDR, ELE, stage inputs), split export/verify, added `--verify`, added menu option to delete work folder, and improved output handling. |
| 6.9 | Stable | Added Yocto metadata-driven DDR/ELE package selection and firmware catalog environment knobs (`FW_ENUM_BRANCH`, `FW_CATALOG_LIMIT`, `FW_MIRROR_BASE_URL`). |
| 7.0 | Current release | Added OS container flow (steps 11..13), OS image/load/entry customization, individual-steps submenu, bootloader output rename to `bootloader_cntr_signed_*`, and timestamped OS container output naming. |

## Features

- End-to-end i.MX93 secure boot automation (AHAB + SPSDK)
- Interactive menu and CLI step execution
- Board target selection: `evk` or `frdm`
- Boot media selection: `sd`, `emmc`, or `serial_downloader`
- 13-step workflow (bootloader + OS container)
- Optional pause between steps
- Optional key generation skip (`--all-no-keys`) for key reuse
- Interactive Yocto metadata-driven DDR/ELE firmware package selection
- Firmware catalog environment knobs: `FW_ENUM_BRANCH`, `FW_CATALOG_LIMIT`, `FW_MIRROR_BASE_URL`
- Auto-created convenience symlinks in `work/outputs/`:
- `latest` -> most recent run output directory
- `latest-bootloader_cntr_signed.bin` -> latest signed bootloader image
- `latest-os-container.bin` -> latest signed OS container image
- Menu option to delete the work folder with typed confirmation

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
| 9 | Export signed bootloader image |
| 10 | Verify signed bootloader image |
| 11 | Write OS container YAML |
| 12 | Export signed OS container image |
| 13 | Verify signed OS container image |

## CLI Usage

```bash
./imx93_secureboot.sh --help
```

### Run Modes

- `--menu` (default): interactive menu
- `--all`: run steps `1..13`
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
- `--os-yaml` -> Step 11
- `--os-export` -> Step 12
- `--os-verify` -> Step 13

### Target Selection

- `--board evk|frdm` (default: `frdm`)
- `--media sd|emmc|serial_downloader` (default: `serial_downloader`)

### OS Container Options

- `--os-image PATH` (default: `inputs/Input_OS.bin`)
- `--os-load-address HEX` (format `0x00000000`, default: `0x80800000`)
- `--os-entry-point HEX` (format `0x00000000`, default: `0x80800000`)

### Firmware Catalog Selection

The interactive menu includes a DDR/ELE selector that derives available package versions from Yocto metadata.

Environment knobs:

- `FW_ENUM_BRANCH` (default: `imx-linux-walnascar`)
- `FW_CATALOG_LIMIT` (default: `0`, meaning all releases)
- `FW_MIRROR_BASE_URL` (default: `https://www.nxp.com/lgfiles/NMG/MAD/YOCTO`)

## Output Naming

Per run, outputs are created under:

- `work/outputs/<run_id>_<board>_<media>/`

Bootloader signed image name:

- `bootloader_cntr_signed_<run_id>_<board>_<media>.bin`

OS container signed image name:

- `os_cntr_signed_<run_id>_<board>_<media>.bin`

Convenience symlinks in `work/outputs/`:

- `latest` -> latest run directory
- `latest-bootloader_cntr_signed.bin` -> latest bootloader image
- `latest-os-container.bin` -> latest OS container image

## Interactive Menu Notes

Main menu includes actions to:

- run full workflow (with or without key generation)
- run bootloader-only steps (1..10)
- run OS-container-only steps (11..13)
- configure board/media, firmware package selection, and OS parameters
- open an `Individual steps` sub-menu for Step 1..13
- delete the work folder (`WORKDIR`) with typed `DELETE` confirmation
