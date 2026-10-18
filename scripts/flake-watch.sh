#!/bin/sh
# === ЗАПУСКАЕТСЯ НА ХОСТЕ (в фоне) перед ребутом коробки ===
# Ждёт, пока коробка вернётся с аптаймом <300с, и запускает на ней flake-watch-remote.sh.
S=$(cd "$(dirname "$0")" && pwd); B=op@10.156.0.133; end=$(( $(date +%s) + 3600 ))
echo "ждём ребута (свежий аптайм < 300с)..."
while [ $(date +%s) -lt $end ]; do
  up=$(ssh -o ConnectTimeout=5 -o BatchMode=yes $B 'cut -d. -f1 /proc/uptime' 2>/dev/null | grep -E '^[0-9]+$')
  if [ -n "$up" ] && [ "$up" -lt 300 ]; then
    echo "коробка поднялась, аптайм ${up}с — запускаю наблюдатель"
    ssh -o ServerAliveInterval=5 -o ServerAliveCountMax=3 $B 'sh -s' < $S/flake-watch-remote.sh 2>&1 | grep -v '^GiGTA'
    exit 0
  fi
  sleep 10
done
echo "за час ребута не дождался"
