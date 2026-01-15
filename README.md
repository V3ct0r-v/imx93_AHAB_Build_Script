# i.MX93 Secure Boot Automation (AHAB + SPSDK)

**Version:** 6.7

This repository provides a **menu-driven and CLI-friendly Bash script** to build, sign, and package a **secure-bootable image for NXP i.MX93 platforms** using **AHAB** and **SPSDK**.

The script supports both **EVK** and **FRDM** boards and can generate **SD-card or eMMC** boot images. It is intended for **development, validation, and manufacturing workflows**, with explicit control over key generation, signing, and image export.

---

## Features

- End-to-end **i.MX93 secure boot** automation (AHAB)
- **Interactive menu** or **CLI step execution**
- **Board selection**: EVK or FRDM
- **Boot media selection**: SD or eMMC
- Optional **pause between steps**
- Optional **skip key generation** (reuse existing keys)
- **Colored console output**
- Optional **logging to file**
- Deterministic **dependency checks** (mirrors apt-get packages)
- Script versioning (**v6.7**)

---

## Secure Boot Flow

This script implements the recommended NXP secure boot architecture:

1. **ROM + ELE**
   - Verifies AHAB container signatures using SRK fuses
   - Optionally decrypts payloads
2. **SPL → TF-A → U-Boot**
   - Authenticated via AHAB
3. **U-Boot**
   - Ready for FIT-based Linux / RTOS verified boot

Key handling is intentionally split:
- **AHAB** secures early boot stages
- **U-Boot FIT signatures** secure OS-level payloads

---

## Supported Targets

| Component | Support |
|---------|--------|
| SoC | i.MX93 (`mimx9352`) |
| Boards | EVK, FRDM |
| Boot Media | SD, eMMC |
| Secure Boot | AHAB |
| Signing | ECC-384 (secp384r1) |
| Tools | SPSDK (`nxpimage`, `nxpcrypto`) |

---

## Dependencies

The script checks for the following host packages:

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
