#!/bin/sh
# ============================================================================
# box-start.sh  — ОРКЕСТРАТОР АВТОЗАПУСКА нашего L2-свитча на Gigamon TA100.
# Запускается из /etc/inittab ОДИН раз на runlevel 3 ПОСЛЕ штатной загрузки
# GigaVUE-OS (строка:  bx:3:once:/var/bcm/box-start.sh ).
#
# Что делает:
#   1) ждёт штатную загрузку (BDE-модули + /dev/linux-user-bde, netdevd поднял чип);
#   2) замораживает pm (чтобы НЕ ребутил из-за смерти netdevd) и убивает netdevd
#      (освобождает чип);  sshd/mgmtd — дети pm, но STOP их не трогает → SSH живёт;
#   3) поднимает наш bcm.user как ДЕМОН под PTY (script -f): stdin из FIFO (держим
#      открытым → не падает по EOF; туда же шлём диаг-команды); rc.soc прогоняет
#      init soc; init misc; init bcm; echo BOX_INIT_DONE;
#   4) ждёт ПОЗИТИВНЫЙ маркер BOX_INIT_DONE (init bcm флейкует ~1/2-1/3 и может
#      ВИСНУТЬ в ioctl, а не только таймаутить — grep ошибок ненадёжен). Нет маркера
#      за INIT_TIMEOUT → убить bcm.user и оставить pm ЗАМОРОЖЕННЫМ (НЕ размораживать!).
#
# FAIL-SAFE:
#   - Kill-switch: файл /var/bcm/DISABLE → автозапуск пропускается, грузимся штатно.
#     (Держать СОЗДАННЫМ, пока флейк init bcm не побеждён — иначе риск неработающего
#      свитча после ребута; сеть при этом всё равно поднимется отдельным boot.sh.)
#   - Сеть (DHCP) поднимает ОТДЕЛЬНЫЙ boot.sh из inittab (eth0 на CPU P2020, от чипа
#     независим) → SSH доступен при ЛЮБОМ исходе этого скрипта.
#   - pm НИКОГДА не размораживаем kill -CONT: при мёртвом netdevd pm РЕБУТИТ коробку
#     (проверено 2026-10-03). Заморожённый pm = нет ребут-петли, sshd (его ребёнок)
#     продолжает жить → SSH остаётся.
# ============================================================================
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/opt/tms/bin
BCM=/var/bcm
LOG=/tmp/box-start.log
BCMLOG=/tmp/bcmrun.log
FIFO=/tmp/bcm.fifo
HOLDER_SLEEP=2147483647
INIT_TIMEOUT=90          # ждать BOX_INIT_DONE; init soc+misc+bcm на 52 портах ~40-70s

exec >>"$LOG" 2>&1
echo "================ box-start $(date) ================"

# 0) Kill-switch -------------------------------------------------------------
if [ -f "$BCM/DISABLE" ]; then
  echo "[skip] /var/bcm/DISABLE присутствует -> остаёмся на штатном netdevd"
  exit 0
fi

# 1) Дождаться штатной загрузки чипа ----------------------------------------
i=0
while [ ! -e /dev/linux-user-bde ] && [ $i -lt 60 ]; do sleep 2; i=$((i+1)); done
if [ ! -e /dev/linux-user-bde ]; then
  echo "[abort] нет /dev/linux-user-bde (BDE не загрузился) -> штатный режим"
  exit 0
fi
echo "[ok] /dev/linux-user-bde есть; жду стабилизации сервисов (sshd/mgmtd/netdevd) 15s"
sleep 15

# 2) Заморозить pm и освободить чип -----------------------------------------
# КРИТИЧНО (урок 2026-10-04): дождаться, пока pm ПОДНИМЕТ sshd (слушает :22), иначе
# заморозка pm оставит коробку БЕЗ SSH (sshd — ребёнок pm, замороженный pm его не стартует;
# однажды так потеряли доступ, спасал только serial). Порт 22 = 0x0016, LISTEN = 0A в /proc/net/tcp.
j=0
while ! awk '$2 ~ /:0016$/ && $4=="0A"{f=1} END{exit !f}' /proc/net/tcp 2>/dev/null && [ $j -lt 90 ]; do sleep 2; j=$((j+1)); done
if awk '$2 ~ /:0016$/ && $4=="0A"{f=1} END{exit !f}' /proc/net/tcp 2>/dev/null; then
  echo "[sshd] слушает :22 (ждал ${j}×2s) — замораживать pm безопасно"
else
  echo "[abort] sshd не поднялся за 180s — НЕ морожу pm (иначе потеряем SSH); остаёмся на штатном"
  exit 0
fi
PM=$(pidof pm)
echo "[freeze] kill -STOP pm ($PM)  — sshd уже слушает, переживёт заморозку"
kill -STOP $PM 2>/dev/null
echo "[chip] kill netdevd ($(pidof netdevd))"
kill $(pidof netdevd) 2>/dev/null
sleep 3

# 2b) ПЕРЕЗАГРУЗКА BDE-модулей -> РЕАЛЬНЫЙ MSI-IRQ для bcm.user --------------
#    Ключ к стабильному init (2026-10-04): без этого bcm.user работал в polled_irq_mode
#    (ipoll опрашивает CMIC), завершения DMA ловились с гонкой -> init ~1/2-1/3 ТИХО ВИСНЕТ.
#    Перезагрузка BDE (как load_bcm.sh) освобождает IRQ 23; config БЕЗ polled_irq_mode ->
#    soc_cm_interrupt_connect берёт реальный IRQ -> завершения DMA мгновенно -> init ~16с,
#    детерминированно. (config.bcm канонический УЖЕ без polled_irq_mode.)
echo "[bde] перезагрузка BDE-модулей (реальный IRQ)"
for s in linux-bcm-knet linux-uk-proxy linux-user-bde linux-kernel-bde; do /etc/rc.d/init.d/$s stop >/dev/null 2>&1; done
sleep 2
for s in linux-kernel-bde linux-user-bde linux-uk-proxy linux-bcm-knet; do /etc/rc.d/init.d/$s start >/dev/null 2>&1; done
sleep 3
echo "[bde] IRQ23: $(awk '/^ *23:/{print $2\" ints\"}' /proc/interrupts)  user-bde: $([ -e /dev/linux-user-bde ] && echo ok || echo НЕТ)"
if [ ! -e /dev/linux-user-bde ]; then echo "[abort] нет /dev/linux-user-bde после reload (pm заморож., reboot -f)"; exit 1; fi

# 3) Поднять bcm.user демоном под PTY (script -f) со stdin из FIFO ----------
#    PTY обязателен: со stdout в файл glibc буферизует лог блоками -> вывод не виден,
#    позитивный маркер BOX_INIT_DONE не прочитать вовремя. script -f даёт построчно.
#    rc.soc (init soc; init misc; init bcm; echo BOX_INIT_DONE) грузится авто при attach.
cd "$BCM" || { echo "[abort] нет $BCM — остаюсь на штатном (pm НЕ размораживаю)"; exit 0; }
rm -f "$FIFO"; mkfifo "$FIFO" || { echo "[abort] mkfifo — остаюсь на штатном"; exit 0; }
: > "$BCMLOG"
# держатель write-end: живёт вечно, переживает завершение этого скрипта (reparent к init)
sleep "$HOLDER_SLEEP" > "$FIFO" &
HOLDER=$!
setsid script -f -c "$BCM/bcm.user" "$BCMLOG" < "$FIFO" > /dev/null 2>&1 &
echo "[run] bcm.user под script/pty, holder pid=$HOLDER, FIFO=$FIFO; жду BOX_INIT_DONE до ${INIT_TIMEOUT}s"

# 4) ПОЗИТИВНЫЙ критерий: ждём маркер BOX_INIT_DONE. -------------------------
#    init bcm может ВИСНУТЬ в ioctl к BDE (не только таймаутить) -> grep ошибок ненадёжен.
ok=0
i=0
while [ $i -lt "$INIT_TIMEOUT" ]; do
  if grep -q BOX_INIT_DONE "$BCMLOG"; then ok=1; break; fi
  sleep 2; i=$((i+2))
done

if [ "$ok" != 1 ]; then
  echo "[fail] нет BOX_INIT_DONE за ${INIT_TIMEOUT}s -> init bcm завис/флейкнул."
  kill -9 $(pidof bcm.user) $(pidof script) $HOLDER 2>/dev/null
  rm -f "$FIFO"
  # ВАЖНО: pm НЕ размораживаем! kill -CONT pm при мёртвом netdevd => pm РЕБУТИТ коробку
  #        (проверено 2026-10-03). Оставляем pm замороженным: ребут-петли нет, SSH жив
  #        (sshd — ребёнок pm, уже запущен; сеть держит отдельный boot.sh). Свитч не
  #        форвардит до ручного вмешательства, но коробка ДОСТУПНА. Повтор — ручной reboot.
  echo "[fail] pm оставлен замороженным (без ребута). SSH жив. Для повтора — 'reboot -f'."
  echo "[fail] ВНИМАНИЕ: обычный 'reboot' при замороженном pm НЕ срабатывает (идёт через pm) — нужен 'reboot -f'."
  exit 1
fi

# Успех: bcm.user жив и держит чип, FIFO открыт держателем. ------------------
echo "[DONE] BOX_INIT_DONE получен -> наш L2-свитч активен. bcm.user pid=$(pidof bcm.user)."
echo "       диаг-команды:   echo 'ps' > $FIFO   (вывод в $BCMLOG)"

# Панельные LED: грузим board-программу netdevd (devmem) + включаем auto-обновление от linkscan.
# (Микро заводится, порты 1-16 ложатся верно; 17-48 — перемешка из-за portmap-перенумерации,
#  REMAP ещё не зашит — косметика, см. [[gigamon-ta100-config-db]].)
if [ -x "$BCM/box-leds.sh" ]; then
  echo "[led] инициализация панельных LED (box-leds.sh + led auto)"
  sh "$BCM/box-leds.sh" >/dev/null 2>&1
  echo "led 0 auto on" > "$FIFO"; echo "led 1 auto on" > "$FIFO"
fi
exit 0
