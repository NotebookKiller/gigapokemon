#!/bin/sh
# === ЗАПУСКАЕТСЯ НА ХОСТЕ (в фоне) перед серией ребутов коробки ===
# Ловит каждую новую загрузку по смене boot_id (не по аптайму: SSH возвращается через 3-5 мин,
# когда boot.sh восстановит учётку op) и запускает на ней flake-watch-remote.sh.
# Работает до первого пойманного зависания или до часа; удачные загрузки только отмечает.
S=$(cd "$(dirname "$0")" && pwd); B=op@10.156.0.133; end=$(( $(date +%s) + 3600 ))
q() { ssh -o ConnectTimeout=5 -o BatchMode=yes $B "$1" 2>/dev/null | grep -v '^GiGTA'; }

last=$(q 'cat /proc/sys/kernel/random/boot_id')
echo "текущая загрузка: ${last:-нет связи}; жду новых загрузок..."
while [ $(date +%s) -lt $end ]; do
  id=$(q 'cat /proc/sys/kernel/random/boot_id')
  if [ -n "$id" ] && [ "$id" != "$last" ]; then
    last=$id
    echo "=== новая загрузка $(date +%T), аптайм $(q 'cut -d. -f1 /proc/uptime')с"
    out=$(ssh -o ServerAliveInterval=5 -o ServerAliveCountMax=3 $B 'sh -s' < "$S/flake-watch-remote.sh" 2>&1 | grep -v '^GiGTA')
    echo "$out"
    case "$out" in *ЗАВИСАНИЕ*) echo "=== зависание поймано, выхожу"; exit 0 ;; esac
  fi
  sleep 5
done
echo "за час зависания не поймал"
