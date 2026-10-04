#!/bin/sh
# === ЗАПУСКАЕТСЯ НА КОРОБКЕ (Linux-side, можно при живом bcm.user) ===
# Инициализирует LED-процессоры чипа (панельные индикаторы) — ВОСПРОИЗВОДИТ netdevd.
# Наш init (bcm.user) LED-процессор не заводит под TA100 (REMAP/программа bradley.c — для
# референс-платы), поэтому панель «вся горит». netdevd грузит СВОЮ board-программу в LEDUP0/1
# и ставит CTRL. Мы сняли её devmem'ом из-под стока (2026-10-04) и теперь пишем тем же devmem'ом.
# Регистры CMIC LED (Trident), BAR чипа = 0xc0000000 (PCI 0x14e4:0xb846):
#   LEDUP0 CTRL=0x1000 PROGRAM=0x1800 ;  LEDUP1 CTRL=0x2000 PROGRAM=0x2800  (байт = low-байт 32-бит слова)
BAR=0xc0000000
DM="busybox devmem"
# board-программа TA100 (идентична для LEDUP0 и LEDUP1), снята с netdevd, 256 байт:
PROG="02 01 10 F9 81 67 56 80 D2 25 74 02 12 F0 85 05 D2 05 71 16 52 00 3A 24 06 F3 67 63 75 25 12 A4 FE F3 02 0A 50 06 F3 67 5C 75 32 12 C9 FE F3 02 0A 50 12 C9 FE F3 95 75 44 85 12 A4 FE F3 95 75 78 85 77 6A 12 A4 FE F3 95 75 4E 85 77 71 16 F0 DA 02 71 71 77 78 5A 00 75 7F 77 83 12 80 F8 15 1A 04 57 12 80 F8 15 1A 05 57 32 0E 87 32 0E 87 57 32 0F 87 32 0E 87 57 32 0E 87 32 0F 87 57 22 0F 87 57 22 0E 87 57"

load_prog() {   # $1 = program RAM base offset (0x1800 или 0x2800)
  base=$1; i=0
  for b in $PROG; do
    $DM $((BAR+base+i*4)) 32 0x$b >/dev/null 2>&1
    i=$((i+1))
  done
  # добить нулями до 256 слов (очистить хвост RAM)
  while [ $i -lt 256 ]; do $DM $((BAR+base+i*4)) 32 0 >/dev/null 2>&1; i=$((i+1)); done
}

echo "LED: stop (CTRL=0)"
$DM $((BAR+0x1000)) 32 0 >/dev/null 2>&1   # LEDUP0 stop
$DM $((BAR+0x2000)) 32 0 >/dev/null 2>&1   # LEDUP1 stop
echo "LED: грузим программу в LEDUP0 (0x1800) и LEDUP1 (0x2800)"
load_prog 0x1800
load_prog 0x2800
echo "LED: CTRL LEDUP0=0xB3, LEDUP1=0xF3 (как у netdevd — enable+chain)"
$DM $((BAR+0x1000)) 32 0xB3 >/dev/null 2>&1
$DM $((BAR+0x2000)) 32 0xF3 >/dev/null 2>&1
echo "LED: готово. CTRL0=$($DM $((BAR+0x1000)) 32) CTRL1=$($DM $((BAR+0x2000)) 32)"
