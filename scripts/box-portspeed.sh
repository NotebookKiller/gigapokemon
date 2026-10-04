#!/bin/sh
# === ЗАПУСКАЕТСЯ НА КОРОБКЕ (после init bcm, рядом с bcm.user) ===
# АВТО-СКОРОСТЬ SFP+ портов (xe0..xe47): 1G и 10G поднимаются сами.
# Механика (2026-10-04): 1G-модули линкуются autoneg'ом (an=on); 10G DAC/SFP autoneg
# НЕ ловит — нужен форс sp=10000 an=off. Тип модуля по EEPROM не читаем (SFP-I2C — как в
# netdevd, отдельная задача), поэтому ПРОБУЕМ: для DOWN-порта чередуем an(1G)<->f10(10G).
# Порт, не слинковавшийся за MAX_TRIES проб, считаем ПУСТЫМ -> успокаиваем (an) и
# перепроверяем редко (раз в REPROBE циклов), чтобы не дёргать пустые порты вечно.
# UP-порт не трогаем; если UP-порт упал (выдернули) -> снова активная проба.
# Управление bcm.user через FIFO; статус из лога под pty; лог ограничиваем (tmpfs).
FIFO=/tmp/bcm.fifo
L=/tmp/bcmrun.log
ST=/tmp/portspeed.state          # строки: "xeN mode tries" ; mode=an|f10|rest
INTERVAL=12
MAX_TRIES=4                      # 4 пробы (2 полных an<->f10) без линка -> rest
REPROBE=20                       # пустой порт перепроверять раз в 20 циклов
LOG_MAX=800                      # строк в bcmrun.log; выше -> подрезаем
PORTS=$(i=0; while [ $i -le 47 ]; do echo xe$i; i=$((i+1)); done)

[ -p "$FIFO" ] || { echo "нет FIFO $FIFO — bcm.user не запущен?"; exit 1; }

if [ ! -f "$ST" ]; then : > "$ST"; for p in $PORTS; do echo "$p an 0" >> "$ST"; done; fi
field() { grep "^$1 " "$ST" | awk -v n="$2" '{print $n}'; }   # $2: 2=mode 3=tries
setst() { grep -v "^$1 " "$ST" > "$ST.t"; echo "$1 $2 $3" >> "$ST.t"; mv "$ST.t" "$ST"; }

query_ps() {
  pos=$(wc -l < "$L")
  echo "ps" > "$FIFO"
  sleep 3
  sed -n "$((pos+1)),\$p" "$L"
}
cap_log() {   # держим bcmrun.log ограниченным (tmpfs не резиновый)
  n=$(wc -l < "$L" 2>/dev/null || echo 0)
  if [ "$n" -gt "$LOG_MAX" ]; then tail -200 "$L" > "$L.t" && mv "$L.t" "$L"; fi
}

echo "=== portspeed watchdog старт $(date) ==="
cyc=0
while true; do
  cyc=$((cyc+1))
  PS=$(query_ps)
  for p in $PORTS; do
    st=$(echo "$PS" | awk -v p="$p" '{name=$1; sub(/^\*/,"",name)} name==p{print $2; exit}')
    [ -z "$st" ] && continue
    mode=$(field "$p" 2); tries=$(field "$p" 3)
    if [ "$st" = "up" ]; then
      [ "$tries" != "0" ] && setst "$p" "$mode" 0      # слинковался — сбросить счётчик
      continue
    fi
    # DOWN
    if [ "$mode" = "rest" ]; then
      # пустой порт: перепроверять редко
      if [ $((cyc % REPROBE)) -eq 0 ]; then
        echo "port $p sp=10000 an=off" > "$FIFO"; setst "$p" f10 1
      fi
      continue
    fi
    if [ "$tries" -ge "$MAX_TRIES" ]; then
      echo "port $p en=1 an=on sp=1000" > "$FIFO"; setst "$p" rest 0   # успокоить на 1G
      continue
    fi
    # активная проба: чередуем скорость
    if [ "$mode" = "an" ]; then
      echo "port $p sp=10000 an=off" > "$FIFO"; setst "$p" f10 $((tries+1))
    else
      echo "port $p en=1 an=on sp=1000" > "$FIFO"; setst "$p" an $((tries+1))
    fi
  done
  cap_log
  sleep "$INTERVAL"
done
