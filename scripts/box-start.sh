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

# Ротация (2026-10-18): /tmp -> /var/root/tmp, это раздел VAR (771M, был заполнен на 91%).
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 262144 ] && mv -f "$LOG" "$LOG.1"
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
echo "[bde] IRQ23: $(awk '/^ *23:/{print $2 " ints"}' /proc/interrupts)  user-bde: $([ -e /dev/linux-user-bde ] && echo ok || echo НЕТ)"
if [ ! -e /dev/linux-user-bde ]; then echo "[abort] нет /dev/linux-user-bde после reload (pm заморож., reboot -f)"; exit 1; fi

# 3) Поднять bcm.user демоном под PTY (script -f) со stdin из FIFO ----------
#    PTY обязателен: со stdout в файл glibc буферизует лог блоками -> вывод не виден,
#    позитивный маркер BOX_INIT_DONE не прочитать вовремя. script -f даёт построчно.
#    rc.soc (init soc; init misc; init bcm; echo BOX_INIT_DONE) грузится авто при attach.
cd "$BCM" || { echo "[abort] нет $BCM — остаюсь на штатном (pm НЕ размораживаю)"; exit 0; }
rm -f "$FIFO"; mkfifo "$FIFO" || { echo "[abort] mkfifo — остаюсь на штатном"; exit 0; }
: > "$BCMLOG"
# VLAN (2026-10-18): vlan.conf (клетки панели) -> vlan.soc, его подгружает rc.soc (rcload).
# Нет vlan.conf или в нём ошибка -> пустой vlan.soc = все порты в VLAN 1 (свитч работает плоско).
rm -f /tmp/vlan-gen.err
if [ -r "$BCM/vlan.conf" ] && VLAN_GEN_BOOT=1 sh "$BCM/vlan-gen.sh" "$BCM/vlan.conf" > "$BCM/vlan.soc.new" 2> /tmp/vlan-gen.err; then
  mv "$BCM/vlan.soc.new" "$BCM/vlan.soc"
  echo "[vlan] vlan.soc из vlan.conf: $(grep -c '^vlan create' "$BCM/vlan.soc") VLAN кроме 1"
else
  echo "# vlan.conf нет или ошибка -> только VLAN 1" > "$BCM/vlan.soc"; rm -f "$BCM/vlan.soc.new"
  echo "[vlan] ОШИБКА/нет vlan.conf -> все порты в VLAN 1: $(cat /tmp/vlan-gen.err 2>/dev/null)"
fi
# держатель write-end: живёт вечно, переживает завершение этого скрипта (reparent к init)
sleep "$HOLDER_SLEEP" > "$FIFO" &
HOLDER=$!
# ulimit -c 0: core-дамп bcm.user (~40МБ) лёг бы в /var/bcm и забил VAR.
# script -a: лог открыт с O_APPEND -> поллер ниже может безопасно обрезать его на ходу.
ulimit -c 0
setsid script -a -f -c "$BCM/bcm.user" "$BCMLOG" < "$FIFO" > /dev/null 2>&1 &
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
  echo "[fail] нет BOX_INIT_DONE за ${INIT_TIMEOUT}s -> init завис/флейкнул (real-IRQ flake)."
  # Лог провала сохраняем (2026-10-18): иначе следующая загрузка его затрёт и не видно, где висло.
  mkdir -p "$BCM/faillogs"
  cp "$BCMLOG" "$BCM/faillogs/bcmrun-$(date +%m%d-%H%M%S).log" 2>/dev/null
  ls -t "$BCM"/faillogs/bcmrun-*.log 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null
  echo "[fail] последние строки bcmrun.log (копия в $BCM/faillogs/):"
  tr -d '\r' < "$BCMLOG" | grep -v '^$' | tail -n 6 | sed 's/^/[fail]   | /'
  kill -9 $(pidof bcm.user) $(pidof script) $HOLDER 2>/dev/null
  rm -f "$FIFO"
  # АВТО-РЕТРАЙ флейка real-IRQ (2026-10-05): init флейкует ~1/2-1/3 (виснет после init soc,
  # BDE-reload не всегда заводит реальный IRQ). Чистый ребут = новая попытка с новым BDE-reload,
  # обычно лечит. Счётчик в VAR (переживает ребут), кап MAXRETRY — чтобы НЕ уйти в вечную
  # ребут-петлю, если сломано не флейком (напр. бит конфиг). Сбрасывается при успехе.
  RF="$BCM/.boxstart_retries"; MAXRETRY=3
  n=$(cat "$RF" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$RF"; sync
  if [ "$n" -le "$MAXRETRY" ]; then
    echo "[retry] попытка $n/$MAXRETRY -> kill bcm.user; sync; reboot -f (чистый BDE-reload на след. старте)."
    kill -9 $(pidof bcm.user) 2>/dev/null; sync; reboot -f; exit 1
  fi
  # Исчерпан лимит: НЕ размораживаем pm (kill -CONT pm при мёртвом netdevd => ребут, 2026-10-03)
  # и НЕ ребутим больше. Коробка доступна (SSH жив, sshd — ребёнок замороженного pm; сеть — boot.sh).
  echo "[fail] исчерпан лимит ретраев ($MAXRETRY) -> похоже НЕ флейк. pm оставлен замороженным, SSH жив."
  echo "[fail] Сброс: rm $RF, затем 'reboot -f'. (Обычный 'reboot' при замороженном pm не проходит.)"
  exit 1
fi

# Успех: bcm.user жив и держит чип, FIFO открыт держателем. ------------------
rm -f "$BCM/.boxstart_retries" 2>/dev/null   # сброс счётчика авто-ретраев
echo "[DONE] BOX_INIT_DONE получен -> наш L2-свитч активен. bcm.user pid=$(pidof bcm.user)."
echo "       диаг-команды:   echo 'ps' > $FIFO   (вывод в $BCMLOG)"

# Панельные LED: грузим board-программу netdevd (devmem) + включаем auto-обновление от linkscan.
# (Свой микрокод с таблицей «позиция цепочки → ячейка статуса» под разводку панели TA100,
#  см. шапку box-leds.sh.)
if [ -x "$BCM/box-leds.sh" ]; then
  echo "[led] инициализация панельных LED (box-leds.sh + led auto)"
  sh "$BCM/box-leds.sh" >/dev/null 2>&1
  echo "led 0 auto on" > "$FIFO"; echo "led 1 auto on" > "$FIFO"
  # диоды клеток 33-36 висят на LEDUP1, их порты — на LEDUP0: зеркалим линк раз в секунду
  ( while sleep 1; do
      pidof bcm.user >/dev/null 2>&1 || exit 0
      sh "$BCM/box-leds.sh" mirror >/dev/null 2>&1
    done ) &
fi

# ХОТ-ПЛАГ (2026-10-05): SFP втыкают на горячую, а SFPScan отрабатывает лишь раз в rc.soc.
# SFPScan теперь быстрый (fail-fast presence в phy84740: пустой порт ~мс вместо 1с) и
# ИДЕМПОТЕНТНЫЙ (порт с нужной скоростью не трогает -> линк не дёргается) -> можно периодически
# пере-сканировать и ловить вставленные/вынутые модули. Демон-ребёнок живёт, пока жив FIFO/bcm.user.
( while sleep 20; do
    pidof bcm.user >/dev/null 2>&1 && [ -p "$FIFO" ] || exit 0
    echo "SFPScan xe0-xe47" > "$FIFO" 2>/dev/null || exit 0
    # ротация bcmrun.log (~400КБ/сутки от этого поллера): >1МБ -> копия в .1, основной обнулить
    if [ "$(wc -c < "$BCMLOG")" -gt 1048576 ]; then cp -f "$BCMLOG" "$BCMLOG.1"; : > "$BCMLOG"; fi
  done ) &
echo "[hotplug] периодический SFPScan (каждые 20с) запущен (pid $!)."

# L3 (2026-10-24): l3d — шлюзы VLAN через KNET + перенос соседей ядра в таблицы чипа (см. l3.conf).
if [ -r "$BCM/l3.conf" ] && [ -r "$BCM/l3d" ]; then
  [ -f /tmp/l3d.log ] && [ "$(wc -c < /tmp/l3d.log)" -gt 262144 ] && mv -f /tmp/l3d.log /tmp/l3d.log.1
  ( sh "$BCM/l3d" >> /tmp/l3d.log 2>&1 ) &
  echo "[l3] l3d запущен (pid $!), лог /tmp/l3d.log"
fi
exit 0
