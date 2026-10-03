#!/bin/sh
# === ЗАПУСКАТЬ НА КОРОБКЕ (Gigamon TA100, обычный Linux/GigaVUE-OS) ===
# Приглушает штатный вой корпусных вентиляторов.
#
# Железо (всё на i2c-1, ffe03100.i2c): 4× MAX6650 fan-контроллера
#   1-0048 1-004b 1-001b 1-001f  (у каждого канал fan1 = один вентилятор; fan2-4 пусты).
#   4× LM75 термодатчика: 1-0049 1-004a 1-004c 1-004d (temp1_input, порог 80C).
# Управление — ТОЛЬКО через kernel-драйвер max6650 (sysfs), НЕ i2cset (шину держит драйвер).
#   pwm1_enable: 0=full-on(макс, вой), 1=open-loop(регулировка напряжением), 2=closed-loop(не работает тут).
#   pwm1: 0..255 (линейного нет — кривая с ОБРЫВОМ: ниже ~pwm80 вентилятор СРЫВАЕТСЯ в стоп;
#         сорвавшийся low-pwm'ом НЕ перезапустить — нужен "пинок" 255, потом снизить).
# Вентиляторы РАЗНОРОДНЫЕ (разброс/износ): 1-004b слабее на ~15 pwm, ему нужно больше.
# Температуры при +10C окружения ~25-37C => огромный запас, ограничитель = СРЫВ вентилятора, не нагрев.
# Замеренные per-fan setpoint'ы (~5000-6000 RPM, тихо и с запасом от стопа):
SETPOINTS="1-0048:85 1-001b:88 1-001f:85 1-004b:98"
STALL_RPM=1500   # ниже этого считаем сорвавшимся -> пинок 255 -> восстановить setpoint
DEV=/sys/bus/i2c/devices

apply_one() {   # $1=dev  $2=pwm
  p="$DEV/$1"
  [ -e "$p/pwm1" ] || return 1
  echo 1 > "$p/pwm1_enable" 2>/dev/null
  echo "$2" > "$p/pwm1"     2>/dev/null
}

apply_all() {
  for pair in $SETPOINTS; do apply_one "${pair%:*}" "${pair#*:}"; done
}

# Ждём готовности драйвера max6650 (на случай раннего старта при загрузке)
i=0
while [ ! -e "$DEV/1-0048/pwm1" ] && [ $i -lt 60 ]; do sleep 2; i=$((i+1)); done

apply_all

# Сторож: раз в 30с переустановить setpoint и спасти сорвавшийся вентилятор.
# (Штатного термо-демона в этом режиме нет, но сторож защищает от срыва и чужих записей.)
while true; do
  sleep 30
  for pair in $SETPOINTS; do
    d=${pair%:*}; v=${pair#*:}; p="$DEV/$d"
    [ -e "$p/pwm1" ] || continue
    rpm=$(cat "$p/fan1_input" 2>/dev/null)
    if [ -n "$rpm" ] && [ "$rpm" -lt "$STALL_RPM" ]; then
      echo 1   > "$p/pwm1_enable" 2>/dev/null
      echo 255 > "$p/pwm1"        2>/dev/null   # пинок, чтобы раскрутить
      sleep 3
      echo "$v" > "$p/pwm1"       2>/dev/null   # вернуть тихий setpoint
    else
      cur=$(cat "$p/pwm1" 2>/dev/null)
      [ "$cur" = "$v" ] || apply_one "$d" "$v"
    fi
  done
done
