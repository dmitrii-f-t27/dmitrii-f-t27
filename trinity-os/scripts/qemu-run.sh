#!/bin/sh
# Запуск образа Trinity OS в QEMU с GPU-ускорением (virtio-gpu + virgl).
set -e

IMG="${1:?usage: qemu-run.sh <disk.img>}"
[ -r "$IMG" ] || { echo "нет образа: $IMG (сначала make build)"; exit 1; }

KVM=""
[ -w /dev/kvm ] && KVM="-enable-kvm -cpu host"

exec qemu-system-x86_64 \
    $KVM \
    -m 4G -smp 4 \
    -bios "${OVMF:-/usr/share/ovmf/OVMF.fd}" \
    -drive file="$IMG",format=raw,if=virtio \
    -device virtio-vga-gl -display gtk,gl=on \
    -nic user,model=virtio-net-pci \
    -serial mon:stdio
