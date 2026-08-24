#!/bin/sh

set -e

BOARD_DIR=$(dirname "$0")

# EFI-only: кладём grub.cfg в EFI-раздел (PARTUUID подставит post-image)
mkdir -p "$BINARIES_DIR/efi-part/EFI/BOOT"
cp -f "$BOARD_DIR/grub-efi.cfg" "$BINARIES_DIR/efi-part/EFI/BOOT/grub.cfg"
