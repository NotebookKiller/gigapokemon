#!/bin/sh
# === ЗАПУСКАТЬ НА КОРОБКЕ, под init=/bin/bash (см. uboot-root.txt) ===
# Делает так, что ШТАТНАЯ загрузка сразу даёт passwordless root-bash на serial-
# консоли (вместо логина в GigaVUE-OS CLI). Правка живёт в rootfs (p5), переживает
# ребут. Запускать ОДИН раз. Бэкап исходного inittab -> /etc/inittab.bak.
#
# Почему так, а не пароль admin: GigaVUE-OS перегенерирует /etc/shadow из своей БД
# при старте (шаг "Applying initial configuration"), а у admin шелл = CLI, не bash.
# Правка inittab не зависит ни от пароля, ни от CLI.

export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/opt/tms/bin

mount -o remount,rw /

[ -f /etc/inittab.bak ] || cp /etc/inittab /etc/inittab.bak

# заменить строку консольного getty на прямой root-bash
sed -i 's#^co:345:respawn:.*#co:345:respawn:/bin/bash -l </dev/ttyS0 >/dev/ttyS0 2>\&1#' /etc/inittab

echo "--- строка консоли теперь: ---"
grep '^co:' /etc/inittab
sync
echo "Готово. Передёрни питание, в меню bootmgr нажми Enter -> root-bash на консоли."
