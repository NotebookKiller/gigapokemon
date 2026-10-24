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

## xfifix.patch (поверх sfpscan.patch)
`src/appl/diag/port.c`, SFPScan: после перевода порта в 10G включает IEEE-autoneg бит (бит 12)
во внутреннем MII_CTRL линии Warpcore. Без этого после 1G принудительный 10G_XFI на клетках с длинной
XFI-трассой (19, 25-48) не ловится → MAC Fault(Local), хотплаг 1G→10G только через ребут.
Запись идёт через `BCM_PORT_PHY_REG_INDIRECT_ADDR` — прямой адрес уходит в MDIO без AER (на lane 0).

## repeater.patch (поверх xfifix.patch, 24.10)
`src/appl/diag/port.c`, SFPScan, для `phy_pcs_repeater=1` в config: 10G-данные через PHY 84754/84740
идут только в режиме PCS-репитера (PMA/PMD 1.0xC806 |= 6), а 1G-модули работают только в обычном
режиме -> SFPScan переключает режим PHY по типу модуля (и при хотплаге) и не делает xfifix на таких
портах (бит AN уводит линию Warpcore в 1G). До этого 10G давал «линк up» без единого кадра.

## Сопутствующие правки (вне SDK, в scripts/)
- `scripts/box-start.sh`: (а) **авто-ретрай** флейка real-IRQ — при отсутствии BOX_INIT_DONE
  `reboot -f` с капом 3 (счётчик в /var/bcm/.boxstart_retries, сброс при успехе); (б) **хот-плаг** —
  фоновый поллер каждые 20с шлёт `SFPScan` в FIFO (быстрый+идемпотентный → ловит горячую вставку).
- `scripts/rc.soc`: rc.soc с `SFPScan xe0-xe47 dump`, без `an=on` (порты стартуют в 10G).

## Применить
Из корня SDK (`work/bcm/sdk-xgs-robo-6.3.2`):
```
patch -p1 < <репо>/patches/sfpscan.patch
patch -p1 < <репо>/patches/xfifix.patch
patch -p1 < <репо>/patches/repeater.patch
```

## Собрать
```
. work/eldk/env.sh
cd systems/linux/user/gto-2_6
make bcm user BUILD_PLATFORM=ELDK ELDK_VERSION=4.2 CROSS_COMPILE=ppc_85xxDP-
```
Готовый бинарь (все патчи): `bins/bcm.user.current.gz` (md5 в `bins/bcm.user.current.md5`).

## Деплой (нужен SSH, 40МБ)
См. `RUNBOOK-deploy.md` в корне репо.
Блокеры SFPScan до прод-промоута — см. memory/[[gigamon-ta100-sfpscan]] (скорость скана, флейк real-IRQ).
