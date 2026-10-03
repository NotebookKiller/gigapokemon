#!/bin/sh
# === ЗАПУСКАЕТСЯ НА КОРОБКЕ ИЗ inittab (gw:3:once:/var/bcm/boot.sh) ===
# Сеть при загрузке: GigaVUE при ребуте ставит старый статик 10.101.120.35/28 (ЧУЖАЯ сеть) ->
# переполучаем DHCP на eth0 (mgmt-порт), с ретраями. Fallback: если DHCP не дался — вернуть статик
# (доступ останется только по serial, но не хуже исходного; eth0 не остаётся совсем без IP для диагностики).
exec >>/tmp/boot-setup.log 2>&1
echo "=== boot.sh $(date) ==="
pkill dhclient 2>/dev/null
sleep 1
ip addr flush dev eth0
ok=0
for i in 1 2 3 4 5; do
  dhclient -1 eth0 && { ok=1; break; }
  echo "dhclient try $i failed, retry..."; sleep 5
done
if [ "$ok" != 1 ]; then
  echo "DHCP FAILED -> fallback static 10.101.120.35/28 (доступ только по serial)"
  ip addr add 10.101.120.35/28 dev eth0 2>/dev/null
fi
ip -o addr show eth0
ip route
echo "=== boot.sh done ==="
