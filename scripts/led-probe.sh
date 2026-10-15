#!/bin/sh
# === ЗАПУСКАЕТСЯ НА КОРОБКЕ === Проба раскладки LED-панели.
# Грузит в LED-процессоры крошечный микрокод: 36 бит, «горит» ровно один бит на позиции N
# в цепочке выбранного LEDUP (кодировка бита — как у стокового микрокода: on=push 0x0e, off=push 0x0f).
# Второй LEDUP получает пустую программу (все off). Статус портов/линков не используется.
#   led-probe.sh 0 21   — LEDUP0, позиция 21 (1..36)
#   led-probe.sh 1 12   — LEDUP1, позиция 12
#   led-probe.sh restore — вернуть стоковый микрокод (box-leds.sh)
# Дизассемблер:  00 ld a,1 / 02 cmp a,N / 04 jnz 0B / 06 push 0e; pack / 09 jmp 0E /
#                0B push 0f; pack / 0E inc a / 0F cmp a,0x25 / 11 jnz 02 / 13 send 0x24 / 15 ret
BAR=0xc0000000
DM="busybox devmem"

if [ "$1" = restore ]; then exec sh "$(dirname "$0")/box-leds.sh"; fi
U=$1; N=$2
case "$U" in 0|1) ;; *) echo "usage: $0 <0|1> <1..36> | restore"; exit 1;; esac
[ "$N" -ge 1 ] 2>/dev/null && [ "$N" -le 36 ] || { echo "N = 1..36"; exit 1; }

prog() {  # $1 = PROGRAM base, $2 = позиция (0 = ничего не зажигать)
  i=0
  for b in 02 01 D2 $(printf %02X $2) 74 0B 22 0E 87 77 0E 22 0F 87 80 D2 25 74 02 3A 24; do
    $DM $(($BAR+$1+i*4)) 32 0x$b; i=$((i+1))
  done
  while [ $i -lt 256 ]; do $DM $(($BAR+$1+i*4)) 32 0x57; i=$((i+1)); done
}

$DM $(($BAR+0x1000)) 32 0; $DM $(($BAR+0x2000)) 32 0
if [ $U = 0 ]; then prog 0x1800 $N; prog 0x2800 0; else prog 0x1800 0; prog 0x2800 $N; fi
$DM $(($BAR+0x1000)) 32 0xB3; $DM $(($BAR+0x2000)) 32 0xF3
echo "LEDUP$U позиция $N — какой диод горит?"
