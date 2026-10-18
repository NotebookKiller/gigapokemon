# === ВЫПОЛНЯЕТСЯ НА КОРОБКЕ через ssh (запускает scripts/flake-watch.sh) ===
# Ловит флейк init: ждёт старта bcm.user, и если bcmrun.log стоит 40с без BOX_INIT_DONE —
# снимок: этап rc.soc (метки RC:), хвост лога, потоки (state/wchan), CPU, IRQ23, стеки gdb.
# Находка 18.10: висит в `init misc`, главный поток спит на futex (не крутится), IRQ приходят.
LOG=/tmp/bcmrun.log; t0=$(date +%s)
while :; do
  P=$(pidof bcm.user); [ -n "$P" ] && break
  [ $(( $(date +%s) - t0 )) -gt 600 ] && { echo "WATCH: bcm.user так и не стартовал за 10 мин"; exit; }
  sleep 2
done
echo "WATCH: bcm.user pid=$P стартовал $(date +%T)"
last=0; same=0
while :; do
  grep -q BOX_INIT_DONE $LOG 2>/dev/null && { echo "WATCH: BOX_INIT_DONE $(date +%T) — init прошёл"; exit; }
  n=$(wc -l < $LOG 2>/dev/null); [ "$n" = "$last" ] && same=$((same+2)) || { same=0; last=$n; }
  if [ $same -ge 40 ]; then
    echo "WATCH: ЗАВИСАНИЕ $(date +%T), лог стоит ${same}с на $n строках"
    echo "--- метки rc.soc:"; tr -d '\r' < $LOG | grep '^RC:' | tail -3
    echo "--- хвост лога:"; tr -d '\r' < $LOG | grep -v '^$' | tail -3
    echo "--- потоки bcm.user (tid state wchan):"
    for t in /proc/$P/task/*; do printf "%s %s %s\n" "${t##*/}" "$(awk '{print $3}' $t/stat)" "$(cat $t/wchan 2>/dev/null)"; done
    echo "--- главный поток, utime/stime (тики):"; awk '{print $14, $15}' /proc/$P/stat
    sleep 3; awk '{print $14, $15}' /proc/$P/stat
    echo "--- IRQ23:"; grep ' 23:' /proc/interrupts; sleep 3; grep ' 23:' /proc/interrupts
    if command -v gdb >/dev/null 2>&1; then
      echo "--- стеки потоков (gdb):"
      gdb -p "$P" -batch -ex 'thread apply all bt 25' 2>&1 | grep -E '^Thread|^#' | head -120
    else
      echo "--- gdb на коробке нет: стеков не будет"
    fi
    exit
  fi
  sleep 2
done
