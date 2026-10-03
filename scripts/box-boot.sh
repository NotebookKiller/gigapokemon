#!/bin/sh
# === ЗАПУСКАЕТСЯ НА КОРОБКЕ ИЗ inittab: ac:3:once:/var/bcm/boot.sh ===
# WATCHDOG доступа (НЕ одноразовый — вечный цикл). Причина: при загрузке GigaVUE
# ПОЗЖЕ нас переприменяет штатный статик 10.101.120.35/28 и пересобирает passwd из
# своей конфиг-базы, затирая наши op + DHCP (проверено 2026-10-03: одноразовый boot.sh
# добавлял op в 22:28, но GigaVUE потом его стёр). Поэтому держим доступ в цикле:
# каждые CHECK_SEC секунд — (1) гарантируем юзера op+ключ, (2) если eth0 не в нашей
# сети 10.156/22 — переполучаем DHCP. mgmtd переприменяет статик лишь раз на старте,
# так что после первого восстановления состояние стабильно (флапа нет).
# eth0 — mgmt на CPU P2020, от свитч-чипа/bcm.user независим.
exec >>/tmp/boot-setup.log 2>&1
echo "=== boot.sh (watchdog) старт $(date) pid=$$ ==="

OP_HOME=/var/home/op
PUBKEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCvEr3LvvhZmslQcTLcG/5h592snkxgjpMl7DfFx0s8QhIHCsJO6s7Xp87BCqEoPCcrSeB5lXpKdgdduYGm0VmHXfftV/bBNMamR5Ud2MVCazYzhq8kKUt3G+BAocg+gfbZgYBcchuhSuMJMFLfk+rqPw+UWeOqe2mKXeZYfnZi3TTePWt5JvBd9UspTrMef57NW7c72IUAYpHGkUqP5Zwe+q7Twdmi+4myCSshK4UmEzqW4KRodlj6P3JiZyrzOERiSbeT7YOwSWJabUxOck5nasDXyBTWyxFyNWrkK8Fuh+nHpok9rXfTmQMuytL5D33fiM413qjXHs0ZbtAwouWccIe8R5+24WfD9uDGI8Q6RvXCeUUnAUNb48+kP1rNI2+UZpZBi54J1lqEI1/PW3yzzUvyKtNmtQ98J0YjAWPjUlR3Tx0JdAJVv8f0aeeVBON/rY0Wv/iEWlVoOKyR/geX8y3+0HimPKjhEgT43nh6iK68HHwjojiuCsjPczSE5vM= alexander_getman@wb-Latitude-5520'
CHECK_SEC=30

ensure_op() {
  PW="$(readlink -f /etc/passwd)"; SH="$(readlink -f /etc/shadow)"
  if ! grep -q '^op:' "$PW"; then echo "op:x:0:0:Shell:$OP_HOME:/bin/bash" >> "$PW"; echo "[$(date +%T)] op восстановлен в passwd"; fi
  grep -q '^op:' "$SH" || echo 'op:*:18500:0:99999:7:::' >> "$SH"
  mkdir -p "$OP_HOME/.ssh"
  grep -qF "$PUBKEY" "$OP_HOME/.ssh/authorized_keys" 2>/dev/null || echo "$PUBKEY" >> "$OP_HOME/.ssh/authorized_keys"
  chmod 755 "$OP_HOME" 2>/dev/null; chmod 700 "$OP_HOME/.ssh" 2>/dev/null; chmod 600 "$OP_HOME/.ssh/authorized_keys" 2>/dev/null
  chown -R op "$OP_HOME" 2>/dev/null
}

ensure_net() {
  # уже в нашей сети? ничего не делаем.
  ip -o addr show eth0 2>/dev/null | grep -q "inet 10\.156\." && return 0
  # ждём линк (carrier), до ~20с
  j=0; while [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" != 1 ] && [ $j -lt 10 ]; do sleep 2; j=$((j+1)); done
  echo "[$(date +%T)] eth0 без 10.156-адреса -> беру DHCP"
  pkill dhclient 2>/dev/null; sleep 1
  ip addr flush dev eth0
  dhclient -1 eth0 && echo "[$(date +%T)] DHCP OK: $(ip -o addr show eth0 | awk '/inet /{print $4}')" \
                   || echo "[$(date +%T)] DHCP не дался, повтор через ${CHECK_SEC}s"
}

while true; do
  ensure_op
  ensure_net
  sleep "$CHECK_SEC"
done
