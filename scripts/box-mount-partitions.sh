#!/bin/sh
# === ЗАПУСКАТЬ НА КОРОБКЕ, под init=/bin/bash ===
# Под init=/bin/bash udev не работает (/dev почти пуст) и /proc не смонтирован.
# Скрипт создаёт нод-файлы разделов и монтирует /proc, /var, /config.
# Нужно, если хочешь править passwd/shadow (симлинки в /var/opt/tms/output) и т.п.
#
# Разметка (major 179): p1 BOOTMGR, p2/p3 BOOT(FAT), p5 ROOT_1, p6 ROOT_2,
#                        p7 CONFIG, p8 VAR. root уже смонтирован как / (p5).

export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/opt/tms/bin

mount -o remount,rw /
mount -t proc proc /proc 2>/dev/null

# создать нод-файлы (если udev не создал)
[ -e /dev/mmcblk0p7 ] || mknod /dev/mmcblk0p7 b 179 7
[ -e /dev/mmcblk0p8 ] || mknod /dev/mmcblk0p8 b 179 8

mount -t ext3 /dev/mmcblk0p8 /var
mount -t ext3 /dev/mmcblk0p7 /config

echo "Смонтировано: /proc, /var (p8), /config (p7)."
echo "passwd/shadow: /var/opt/tms/output/{passwd,shadow}"
ls -l /etc/passwd /etc/shadow
