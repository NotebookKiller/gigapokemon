# Патчи SDK для нашего bcm.user

SDK: **sdk-xgs-robo-6.3.2**, таргет `systems/linux/user/gto-2_6` (BCM56840/56846, PPC e500).
Само дерево SDK не в гите (`work/` в .gitignore, ~4.5ГБ) — здесь только наши правки патчами.

## sfpscan.patch
Две фичи в одном патче:
1. **SFPScan** — своя diag-команда `SFPScan [pbmp] [dump]`: читает SFP EEPROM (SFF-8472, I2C 0x50)
   через I2C-мастер PHY 84740/84754 (`phy_84740_i2cdev_read`) и авто-ставит скорость порта
   (10G для 10GbE/DAC, 1G для 1000BASE). Файлы: `src/appl/diag/port.c` (хендлер+usage),
   `include/appl/diag/cmdlist.h` (DCL_CMD), `src/appl/diag/cmdlist.c` (строка в bcm_esw_cmd_list).
2. **LED-fix** — `src/appl/diag/ledproc.c`: перенос skip_count-компенсации дырки phys 17-20 с
   Trident2 на наш Trident(56840). Без него панельные диоды едут на −4 начиная с cage 17.
3. **Fast-presence** — `src/soc/phy/phy84740.c` (`_phy_84740_bsc_rw`): опрос I2C-статуса теперь
   выходит и на `FAIL` (не только `COMPLETE`) + таймаут 1с→100мс. Пустой SFP-порт NAK'ает сразу,
   так что SFPScan на пустых кейджах ~мс вместо ~1с (≈45с→<1с на 48 портов). Успешное чтение не изменено.

## Сопутствующие правки (вне SDK, в scripts/)
- `scripts/box-start.sh`: (а) **авто-ретрай** флейка real-IRQ — при отсутствии BOX_INIT_DONE
  `reboot -f` с капом 3 (счётчик в /var/bcm/.boxstart_retries, сброс при успехе); (б) **хот-плаг** —
  фоновый поллер каждые 20с шлёт `SFPScan` в FIFO (быстрый+идемпотентный → ловит горячую вставку).
- `scripts/rc.soc.sfpscan`: rc.soc с `SFPScan dump` вместо хардкод-форса 10G.

## Применить
Из корня SDK (`work/bcm/sdk-xgs-robo-6.3.2`):
```
patch -p1 < <репо>/patches/sfpscan.patch        # или: git apply <...>/patches/sfpscan.patch
```

## Собрать
```
. work/eldk/env.sh
cd systems/linux/user/gto-2_6
make bcm user BUILD_PLATFORM=ELDK ELDK_VERSION=4.2 CROSS_COMPILE=ppc_85xxDP-
```
Готовый бинарь (оба фикса): `bins/bcm.user.sfpscan-ledfix.gz`.

## Деплой (нужен SSH, 40МБ)
`scp` на коробку → `/var/bcm/bcm.user`; rc.soc со `SFPScan` — `scripts/rc.soc.sfpscan`.
Проверка LED после деплоя: воткнуть трансивер в cage 17/21 → диод совпадает с номером разъёма.
Блокеры SFPScan до прод-промоута — см. memory/[[gigamon-ta100-sfpscan]] (скорость скана, флейк real-IRQ).
