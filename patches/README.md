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
