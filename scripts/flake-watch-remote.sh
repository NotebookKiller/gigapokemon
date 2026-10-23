# === ВЫПОЛНЯЕТСЯ НА КОРОБКЕ через ssh (запускает scripts/flake-watch.sh) ===
# Ловит флейк init: ждёт bcm.user; если bcmrun.log не меняется >=25с без BOX_INIT_DONE —
# снимок: этап rc.soc (метки RC:), потоки (state/wchan), стеки gdb, CPU, IRQ23.
# Простой считаем по mtime лога (ловушка может подключиться посреди зависания), а box-start
# убивает bcm.user через 90с после старта — поэтому стеки снимаем первыми.
# Находка 18.10: висит в `init misc`, главный поток спит на futex (не крутится), IRQ приходят.
LOG=/tmp/bcmrun.log; t0=$(date +%s)
while :; do
  P=$(pidof bcm.user); [ -n "$P" ] && break
  [ $(( $(date +%s) - t0 )) -gt 600 ] && { echo "WATCH: bcm.user так и не стартовал за 10 мин"; exit; }
  sleep 1
done
echo "WATCH: bcm.user pid=$P, подключился $(date +%T)"
while :; do
  grep -q BOX_INIT_DONE $LOG 2>/dev/null && { echo "WATCH: BOX_INIT_DONE — init прошёл"; exit; }
  pidof bcm.user >/dev/null || { echo "WATCH: bcm.user исчез (ретрай?) $(date +%T)"; exit; }
  idle=$(( $(date +%s) - $(stat -c %Y $LOG) ))
  if [ $idle -ge 25 ]; then
    echo "WATCH: ЗАВИСАНИЕ $(date +%T), лог не меняется ${idle}с ($(wc -l < $LOG) строк)"
    echo "--- метки rc.soc:"; tr -d '\r' < $LOG | grep '^RC:' | tail -2
    echo "--- потоки bcm.user (tid state wchan):"
    for t in /proc/$P/task/*; do printf "%s %s %s\n" "${t##*/}" "$(awk '{print $3}' $t/stat)" "$(cat $t/wchan 2>/dev/null)"; done
    echo "--- стеки потоков (gdb):"
    bt=$(gdb -p "$P" -batch -ex 'thread apply all bt 30' 2>&1 | grep -E '^Thread|^#')
    if [ "$(echo "$bt" | grep -c '^#')" -ge 2 ]; then echo "$bt" | head -150
    else
      # gdb 6.7 и статический bcm.user: потоки может не увидеть — тогда цепляемся к каждому TID
      for t in /proc/$P/task/*; do
        echo "Thread tid=${t##*/}:"; gdb -p "${t##*/}" -batch -ex 'bt 30' 2>&1 | grep '^#' | head -30
      done
    fi
    echo "--- главный поток, utime/stime (тики):"; awk '{print $14, $15}' /proc/$P/stat
    echo "--- IRQ23:"; grep ' 23:' /proc/interrupts; sleep 2; grep ' 23:' /proc/interrupts
    exit
  fi
  sleep 1
done
