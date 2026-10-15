#!/usr/bin/env bash
#
# apply-config.sh - merge tigerlake.config into a Gentoo kernel tree and
# resolve the result against the tree's Kconfig.
#
# Usage:
#   ./apply-config.sh [KERNEL_DIR]
#
# KERNEL_DIR defaults to /usr/src/linux. The fragment is read from the same
# directory as this script. Run as your normal user; only `make` is invoked.
#
set -euo pipefail

KERNEL_DIR="${1:-/usr/src/linux}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="${SCRIPT_DIR}/tigerlake.config"

if [[ ! -d "${KERNEL_DIR}" ]]; then
    echo "error: kernel directory not found: ${KERNEL_DIR}" >&2
    echo "       pass it as the first argument, e.g. ./apply-config.sh /usr/src/linux-6.12" >&2
    exit 1
fi

if [[ ! -f "${FRAGMENT}" ]]; then
    echo "error: fragment not found: ${FRAGMENT}" >&2
    exit 1
fi

cd "${KERNEL_DIR}"

if [[ ! -f Makefile ]]; then
    echo "error: ${KERNEL_DIR} does not look like a kernel source tree" >&2
    exit 1
fi

echo ">> kernel tree: ${KERNEL_DIR}"

# Start from a known baseline so the fragment is not merged onto a random
# config. Remove this block (and the cp below) to layer onto your own .config.
if [[ ! -f .config ]]; then
    echo ">> no .config present, generating a baseline defconfig"
    make defconfig
else
    echo ">> existing .config found, backing it up to .config.bak"
    cp -f .config .config.bak
fi

echo ">> merging fragment"
./scripts/kconfig/merge_config.sh -m .config "${FRAGMENT}"

echo ">> resolving dependencies (olddefconfig)"
make olddefconfig

echo
echo ">> done. Review with:  make menuconfig"
echo ">> verify hardware:    grep -E 'I915|NOUVEAU|IWLWIFI|NVME|SOF' .config"
