#!/bin/sh
# === ЗАПУСКАТЬ НА КОРОБКЕ (root) ===
# Вернуть штатный логин GigaVUE-OS CLI на консоли (отменить box-persistent-root.sh).
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/opt/tms/bin
mount -o remount,rw /
if [ -f /etc/inittab.bak ]; then
    cp /etc/inittab.bak /etc/inittab
    echo "inittab восстановлен из бэкапа."
else
    # если бэкапа нет — вернуть штатную строку agetty вручную
    sed -i 's#^co:345:respawn:.*#co:345:respawn:/sbin/agetty ttyS0 115200,9600 vt102#' /etc/inittab
    echo "Бэкапа не было — строка agetty восстановлена вручную."
fi
grep '^co:' /etc/inittab
sync
echo "Готово. После ребута — штатный login: на консоли."
