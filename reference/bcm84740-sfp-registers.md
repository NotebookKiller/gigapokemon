# BCM84740/84754 — регистры SFP (presence/I2C/decode) для TA100

Один драйвер `phy84740.c` рулит и 84740, и 84754 (`PHY84740_ID_84754=0x84754`). Datasheet NDA;
авторитет — исходник драйвера (у нас sdk-xgs-robo-6.3.2; публичный зеркало: OpenBCM на GitHub
`Broadcom-Network-Switching-Software/OpenBCM`, phy84740.c/.h). Все адреса ниже подтверждены в НАШЕМ
дереве 6.3.2 (ссылки на строки).

## Быстрый presence (одно MDIO-чтение, мкс — без I2C)
Clause-45 PMA/PMD (dev 1):
- `PHY84740_PMAD_OPTICAL_CFG_REG = 0xc8e4` (phy84740.h:198), бит3 `MOD_PRESENCE (1<<3)` (phy84740.c:134).
  Set = модуль вставлен. Сам драйвер так и проверяет (phy84740.c:1996-1997).
- `PHY84740_MOD_AUTO_DETECT_STS_REG = 0xc82b` (phy84740.c:127): bit15 NOT_DONE, bit10 SFP_EN,
  bit9 I2C_FAIL (I2C к EEPROM не прошёл/нет модуля), bit0 NOT_RES (тип не определён → дефолт SR4).
- `PHY84740_PMAD_OPTICAL_SIG_LVL_REG = 0xc800`: полярность пинов MOD_ABS (bit8) / RX_LOS (bit9).
  OVERRIDE-маски в 0xc8e4: RXLOS=0xc0c0, MOD_ABS=0x0808.
⚠️ КАВЕАТ: presence-бит 0xc8e4 завязан на АППАРАТНЫЙ пин mod_abs. По умолчанию, если soc-property
`phy_mod_abs` не задан, драйвер ОВЕРРАЙДИТ mod_abs (phy84740.c:1272) → бит может быть недостоверен.
Разводка mod_abs на TA100 НЕ проверена. Поэтому для надёжного детекта мы используем I2C-NAK (ниже),
а 0xc8e4 — оптимизация «проверить на железе» (devmem/phy прочитать 0xc8e4 с модулем и без).

## I2C-мастер PHY → SFP EEPROM (как читаем в SFPScan)
`phy_84740_i2cdev_read(unit,port,0x50,off,n,buf)` → `_phy_84740_bsc_rw` (phy84740.c:5131).
Последовательность Clause-45 PMA/PMD: 0x8004←ram_start(0x8007), 0x8003←addr, 0x8002←count,
0x8005←(dev_addr<<9)|1, 0x8000←0x8000|op (READ=0x2/WRITE=0x22, bit12=16-бит). Single-port — через
indirect 0xcd0c/0xcd0d/0xcd13 (только lane0). Данные в окне с 0x8007.
СТАТУС 0x8000 биты[3:2] = `PHY84740_2W_STAT` (0x000C): 0x0=IDLE, 0x4=COMPLETE, 0x8=IN_PROGRESS,
0xC=FAIL. **FAIL = NAK/нет модуля** (физический признак, не зависит от разводки mod_abs).
НАШ ФИКС (patches/sfpscan.patch): опрос выходит и на FAIL + таймаут 1с→100мс → пустой порт ~мс.

## SFF-8472 (EEPROM I2C 0x50) — декод 10G vs 1G (подтверждён)
- byte0 Identifier: 0x03=SFP/SFP+, 0x0c/0x0d=QSFP/QSFP+ (skip), 0x00=нет.
- byte3 10GbE compliance: bit4 SR, bit5 LR, bit6 LRM, bit7 ER → биты4-7 ≠0 ⇒ 10G оптика.
- byte6 1GbE: bit0 SX, bit1 LX, bit2 CX, bit3 1000BASE-T → ≠0 ⇒ 1G.
- byte8 SFP+ cable (SFF-8431): bit2=passive DAC (0x04), bit3=active DAC (0x08) ⇒ 10G медь.
- byte12 nominal bitrate ×100Mbit: 10G≈0x67 (10.3G), 1G≈0x0d (1.3G); 0xFF → см. byte66.
- byte63 checksum = младший байт суммы byte0..62.
Дискриминатор (как в нашем SFPScan): id==0x03 → если (b3&0xf0)|(b8&0x0c) ⇒ 10G, иначе b6 ⇒ 1G.

## MMU / конфиг (Trident+ 56840)
Буфер фиксированный 9МБ = 46080 ячеек × 208Б, делится софтом (dedicated/shared). Публичного
board config.bcm для 56840 нет (OpenBCM имеет chip-support + generic/TD2+/TD3/TD4 примеры).
Наш config.bcm/portmap/pbmp уже сверены со стоком (см. stock-config-reconstruction.md).

## Ссылки
- OpenBCM phy84740.c/.h: github.com/Broadcom-Network-Switching-Software/OpenBCM (sdk-6.5.20)
- Linux SFP: include/linux/sfp.h; SFF-8472 (SNIA). BCM56840 brief: docs.broadcom.com/doc/12358267
