#!/bin/sh
# Запись образа Trinity OS на физический диск/флешку. НЕОБРАТИМО ДЛЯ ДАННЫХ НА ДИСКЕ.
set -e

IMG="${1:?usage: flash-to-disk.sh <disk.img> </dev/sdX>}"
DEV="${2:?usage: flash-to-disk.sh <disk.img> </dev/sdX>}"

[ -r "$IMG" ] || { echo "нет образа: $IMG"; exit 1; }
[ -b "$DEV" ] || { echo "$DEV — не блочное устройство"; exit 1; }

case "$DEV" in
  */loop*|*mmcblk*|*nvme*|*sd*) ;;
  *) echo "подозрительное устройство: $DEV"; exit 1 ;;
esac

echo "Целевой диск:"
lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS "$DEV"
echo
echo "ВСЕ ДАННЫЕ НА $DEV БУДУТ УНИЧТОЖЕНЫ."
printf "Впишите путь устройства ещё раз для подтверждения: "
read -r CONFIRM
[ "$CONFIRM" = "$DEV" ] || { echo "отменено"; exit 1; }

# Отмонтировать всё, что примонтировано с этого диска
mount | awk -v d="$DEV" '$1 ~ d {print $1}' | while read -r p; do umount "$p" || true; done

dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
sync
echo "Готово. Диск можно извлекать."
