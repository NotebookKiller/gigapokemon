#!/bin/sh
# ============================================================================
# box-irq-exp.sh — ЭКСПЕРИМЕНТ: завести bcm.user на РЕАЛЬНОМ MSI-IRQ (как netdevd),
# вместо polled_irq_mode. Гипотеза: флейк/зависание init — из-за ненадёжной
# сигнализации завершения DMA через ipoll (polled). netdevd работает через
# kernel-bde + реальный IRQ 23 → завершения мгновенно. Даём то же нашему bcm.user:
#   1) freeze pm, kill netdevd (освобождаем чип и его BDE/IRQ);
#   2) ПЕРЕЗАГРУЖАЕМ BDE-модули (как load_bcm.sh) → чистый IRQ 23, никто не владеет;
#   3) config БЕЗ polled_irq_mode → soc_cm_interrupt_connect берёт реальный IRQ;
#   4) ждём BOX_INIT_DONE. Fail-safe: pm НЕ размораживаем (reboot -f для восстановления).
# Запуск руками (НЕ из inittab): setsid /var/bcm/box-irq-exp.sh
# ============================================================================
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/opt/tms/bin
BCM=/var/bcm
LOG=/tmp/irq-exp.log
BCMLOG=/tmp/bcmrun.log
FIFO=/tmp/bcm.fifo
INIT_TIMEOUT=90
exec >>"$LOG" 2>&1
echo "================ irq-exp $(date) ================"

# 0) подготовить config БЕЗ polled_irq_mode (бэкап оригинала) --------------
cd "$BCM" || { echo "[abort] нет $BCM"; exit 1; }
[ -f config.bcm.polled ] || cp config.bcm config.bcm.polled
grep -v '^polled_irq_mode=' config.bcm.polled > config.bcm
echo "[cfg] polled_irq_mode убран из config.bcm (бэкап config.bcm.polled). Строк: $(wc -l <config.bcm)"

# 1) freeze pm + kill netdevd ----------------------------------------------
PM=$(pidof pm)
echo "[freeze] kill -STOP pm ($PM)"
kill -STOP $PM 2>/dev/null
echo "[chip] kill netdevd ($(pidof netdevd))"
kill $(pidof netdevd) 2>/dev/null
sleep 3

# 2) перезагрузка BDE-модулей ----------------------------------------------
echo "[bde] stop (knet, proxy, user_bde, kernel_bde)"
for s in linux-bcm-knet linux-uk-proxy linux-user-bde linux-kernel-bde; do
  /etc/rc.d/init.d/$s stop >/dev/null 2>&1
done
sleep 2
echo "[bde] после stop осталось: $(lsmod | grep -iE 'bde|knet|proxy' | awk '{print $1}' | tr '\n' ' ')"
echo "[bde] start (kernel_bde, user_bde, proxy, knet)"
for s in linux-kernel-bde linux-user-bde linux-uk-proxy linux-bcm-knet; do
  /etc/rc.d/init.d/$s start >/dev/null 2>&1
done
sleep 3
echo "[bde] модули: $(lsmod | grep -iE 'bde|knet|proxy' | awk '{print $1\"(\"$3\")\"}' | tr '\n' ' ')"
echo "[bde] IRQ 23: $(grep -E '^ *23:' /proc/interrupts)"
IRQ_BEFORE=$(awk '/^ *23:/{print $2}' /proc/interrupts)
ls -l /dev/linux-user-bde /dev/linux-kernel-bde 2>&1 | sed 's/^/[bde] /'
if [ ! -e /dev/linux-user-bde ]; then echo "[abort] нет /dev/linux-user-bde после reload — pm оставлен замороженным, нужен reboot -f"; exit 1; fi

# 3) запуск bcm.user под pty с реальным IRQ --------------------------------
rm -f "$FIFO"; mkfifo "$FIFO"; : > "$BCMLOG"
sleep 2147483647 > "$FIFO" &
HOLDER=$!
setsid script -f -c "$BCM/bcm.user" "$BCMLOG" < "$FIFO" > /dev/null 2>&1 &
echo "[run] bcm.user под pty (holder $HOLDER); жду BOX_INIT_DONE до ${INIT_TIMEOUT}s"

ok=0; i=0
while [ $i -lt "$INIT_TIMEOUT" ]; do
  grep -q BOX_INIT_DONE "$BCMLOG" && { ok=1; break; }
  sleep 2; i=$((i+2))
done
IRQ_AFTER=$(awk '/^ *23:/{print $2}' /proc/interrupts)
echo "[irq] IRQ23 было=$IRQ_BEFORE стало=$IRQ_AFTER (рост = прерывания идут нашему bcm.user)"

if [ "$ok" = 1 ]; then
  echo "[DONE] BOX_INIT_DONE за ~${i}s! РЕАЛЬНЫЙ IRQ РАБОТАЕТ. bcm.user pid=$(pidof bcm.user)"
  echo "       диаг: echo 'ps' > $FIFO (вывод $BCMLOG)"
  exit 0
else
  echo "[fail] нет BOX_INIT_DONE за ${INIT_TIMEOUT}s. bcm.user=$(pidof bcm.user)"
  echo "       хвост bcmrun:"; tail -8 "$BCMLOG" | sed 's/^/[fail] /'
  echo "[fail] pm оставлен замороженным. Восстановление: reboot -f (config.bcm вернётся из .polled при желании)"
  exit 1
fi
