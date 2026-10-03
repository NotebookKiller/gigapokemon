#!/bin/sh
# === ЗАПУСКАТЬ НА КОРОБКЕ (root, после НОРМАЛЬНОЙ загрузки GigaVUE-OS) ===
# БЕЗОПАСНЫЙ прогон bcm.user: НИКОГДА не виснет на консоли и САМ восстанавливает чип.
#   1) морозит pm, останавливает netdevd (освобождает чип);
#   2) запускает bcm.user со сценарием /var/bcm/exp.soc (через rc.soc-автозагрузку),
#      под сторожем, который жёстко убьёт процесс через $DEADLINE секунд;
#   3) по завершении РАЗМОРАЖИВАЕТ pm -> pm перезапускает netdevd -> чип снова
#      инициализирован Gigamon'ом (заведомо рабочее состояние), БЕЗ ребута.
# Весь вывод bcm.user -> /tmp/bcmrun.log (его и cat'ай / неси мне).
#
# ВАЖНО: наш сценарий кладём в /var/bcm/rc.soc (bcm.user грузит его сам при attach),
#        а наш "настоящий" эксперимент — это и есть содержимое rc.soc. Заканчивается exit.

export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/opt/tms/bin
cd /var/bcm || { echo "нет /var/bcm"; exit 1; }
LOG=/tmp/bcmrun.log
DEADLINE=90

echo ">> морожу pm (чтобы не ребутил при смерти netdevd)"
kill -STOP $(pidof pm) 2>/dev/null
echo ">> останавливаю netdevd (освобождаю чип)"
kill $(pidof netdevd) 2>/dev/null
sleep 2
ls -l /dev/linux-user-bde 2>/dev/null || echo "   (!) нет /dev/linux-user-bde"

echo ">> сторож: через ${DEADLINE}s жёстко убью bcm.user"
( sleep $DEADLINE; kill -9 $(pidof bcm.user) 2>/dev/null; echo "   [watchdog] bcm.user убит по таймауту" >> "$LOG" ) &
WD=$!

echo ">> запуск bcm.user (лог -> $LOG) ..."
# bcm.user сам подхватит /var/bcm/rc.soc и /var/bcm/config.bcm из CWD.
./bcm.user > "$LOG" 2>&1

kill $WD 2>/dev/null
echo ">> bcm.user завершён. РАЗМОРАЖИВАЮ pm -> он поднимет netdevd заново"
kill -CONT $(pidof pm) 2>/dev/null
sleep 5
echo ">> netdevd pid сейчас: $(pidof netdevd)  (должен появиться — чип восстановлен)"
echo ">> ================= tail -120 $LOG ================="
tail -120 "$LOG"
echo ">> ===== полный лог: $LOG ($(wc -l < "$LOG") строк) ====="
