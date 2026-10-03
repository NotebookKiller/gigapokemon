#!/bin/bash
# === ЗАПУСКАТЬ НА ХОСТЕ (ПК с gigamon.bin) ===
# Записать образ SD на карту и проверить. КАРТА: настоящий SanDisk/Kingston
# ~4 ГБ SDHC (НЕ UHS/SDXC; 8 ГБ и некоторые карты eSDHC P2020 не переваривает;
# 2 ГБ малы под образ 2.05 ГБ).
#
# Usage: ./host-write-card.sh /dev/sdX   (всё устройство, НЕ раздел sdX1!)
set -e

DEV="$1"
IMG="$(dirname "$0")/../gigamon.bin"

if [ -z "$DEV" ] || [ ! -b "$DEV" ]; then
    echo "Usage: $0 /dev/sdX   (блочное устройство карты целиком)"
    echo "Подсказка: lsblk  — найди карту по размеру, НЕ перепутай с системным диском!"
    exit 1
fi
[ -f "$IMG" ] || { echo "Не найден образ: $IMG"; exit 1; }

echo "Записываю $IMG -> $DEV. ВСЁ на карте будет стёрто."
read -p "Точно $DEV? (yes/no) " ok
[ "$ok" = "yes" ] || { echo "Отмена."; exit 1; }

sudo dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
sync

echo "=== проверка: разделы ==="
sudo fdisk -l "$DEV" | tail -n +1

echo "=== проверка: первый мегабайт совпал с образом? ==="
if sudo cmp -n 1048576 "$DEV" "$IMG"; then
    echo "OK: начало образа записано корректно."
else
    echo "ВНИМАНИЕ: расхождение — перезапиши/проверь карту."
fi
echo "Готово. Вставляй в железку."
