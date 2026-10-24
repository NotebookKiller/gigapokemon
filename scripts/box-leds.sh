#!/bin/sh
# === ЗАПУСКАЕТСЯ НА КОРОБКЕ (Linux-side, можно при живом bcm.user) ===
# Инициализирует LED-процессоры чипа (панельные индикаторы) своим микрокодом с таблицей
# «позиция в LED-цепочке → ячейка data RAM со статусом линка».
#
# Разводка панели TA100 (проба scripts/led-probe.sh, 2026-10-15):
#   LEDUP0 поз 1-16 → диоды клеток 1-16; поз 17-20 не выведены; поз p (21-36) → диод клетки p-4.
#   LEDUP1 поз p (1-16) → диод клетки 32+p; поз 21/25/29/33 → QSFP Q2/Q4/Q3/Q1.
# Порты (24.10, как у стока): клетка N = логический порт N = xe(N-1); phys N (1-16), N+4 (17-48).
# Железо (scan chain) кладёт статус phys P своего LEDUP в ячейку 2*P+1 (бит0 = линк),
# P локальный: LEDUP0 phys 1-36, LEDUP1 phys 37-72 → 1-36.
# Зеркал больше нет: с правильной картой портов диод клетки N читает свою phys-ячейку
# на своём же LEDUP (до 24.10 PHY-адреса были сдвинуты на квад и карту подгоняли вручную).
#
# Микрокод (36 бит, по биту на позицию; 0 в таблице = диод погашен, ячейка 0 всегда 0):
#   00 ld a,1 / 02 ld b,0xC7 / 04 add b,a / 05 ld b,(b) / 06 tst (b),0 / 08 jnc 0F /
#   0A push 0e; pack / 0D jmp 12 / 0F push 0f; pack / 12 inc a / 13 cmp a,0x25 / 15 jnz 02 /
#   17 send 0x24
# Таблица — ячейки 0xC8..0xEB (SDK ledproc пишет 0xA0+phys ≤ 0xC4, стоковый микрокод — 0xF0+).
# Стоковая программа netdevd (для отката) — reference/led-microcode.hex.
BAR=0xc0000000
DM="busybox devmem"
PROG="02 01 12 C7 F8 15 5A 00 75 0F 22 0E 87 77 12 22 0F 87 80 D2 25 74 02 3A 24"
MAP=0xC8      # map[p] в ячейке MAP+p-1

if [ "$1" = mirror ]; then   # зеркала больше не нужны (24.10: карта портов как у стока);
  exit 0                     # оставлено пустым, т.к. box-start вызывает это раз в секунду
fi

load_prog() {   # $1 = program RAM base offset (0x1800 или 0x2800)
  base=$1; i=0
  for b in $PROG; do $DM $((BAR+base+i*4)) 32 0x$b; i=$((i+1)); done
  while [ $i -lt 256 ]; do $DM $((BAR+base+i*4)) 32 0x57; i=$((i+1)); done
}

map0() { # LEDUP0: поз p → ячейка. Клетка N = логич. N (phys N, а с 17-й phys N+4) —
  p=$1    # цепочка LED идёт по phys, поэтому карта тождественная; поз 17-20 не выведены.
  if [ $p -ge 17 ] && [ $p -le 20 ]; then echo 0; else echo $((2*p+1)); fi
}
map1() { # LEDUP1: то же (клетки 33-48 = phys 37-52, QSFP = phys 57-72)
  p=$1
  if [ $p -ge 17 ] && [ $p -le 20 ]; then echo 0; else echo $((2*p+1)); fi
}
load_map() {    # $1 = data RAM base, $2 = map-функция
  p=1
  while [ $p -le 36 ]; do $DM $((BAR+$1+(MAP+p-1)*4)) 32 $($2 $p); p=$((p+1)); done
}

echo "LED: stop (CTRL=0)"
$DM $((BAR+0x1000)) 32 0
$DM $((BAR+0x2000)) 32 0
load_prog 0x1800
load_prog 0x2800
load_map 0x1400 map0
load_map 0x2400 map1
$DM $((BAR+0x1400)) 32 0; $DM $((BAR+0x2400)) 32 0   # ячейка 0 = «погашено»
sh "$0" mirror
echo "LED: CTRL LEDUP0=0xB3, LEDUP1=0xF3 (как у netdevd)"
$DM $((BAR+0x1000)) 32 0xB3
$DM $((BAR+0x2000)) 32 0xF3
echo "LED: готово. CTRL0=$($DM $((BAR+0x1000)) 32) CTRL1=$($DM $((BAR+0x2000)) 32)"
