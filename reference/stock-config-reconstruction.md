# Реконструкция стокового config.bcm/rc.soc из netdevd (TA100, 2026-10-05)

Источник: `work/x/netdevd` (стоковый бинарь, PPC ELF, stripped, 37МБ). Анализ строк + формат-строк.

## Как сток устроен (кратко)
config.bcm/rc.soc — **не файлы**, а скомпилены в netdevd:
- soc-свойства ставятся программно через формат-строки (`port_phy_addr_%d`, `serdes_firmware_mode_%d`,
  имя `pbmp_xport_xe`, `serdes_fiber_pref_`) + вычисление `gmon_hw_portmap_get`/`ndd_gmon_hw_eportmap_get`;
- портмап частично лежит ЛИТЕРАЛАМИ (таблицы ниже);
- init = прямые вызовы SDK (`soc/bcm init`, `Init port %d MAC/PHY`, linkscan, LED), не текстовый rc.soc;
- вход. данные — JSON из /etc (`card.json`=TA1_LCQ4X48, `npu.json`=bcm56840+фильтры, `sw.json`=52 порта,
  дефолт 40G); netdevd читает их по `nddmanifest.json`.
- LCPLL: есть `bradley_lcpll_lock_check` (сток сам проверяет лок LCPLL — это то, что мы чиним вручную).

ЧТО извлекается литералом: **портмап**. ЧТО нет (вычисляется): port_phy_addr_N, pbmp_xport_xe,
xgxs_lcpll_xtal_refclk, таймауты — значения в бинаре не лежат.

## Стоковый портмап — РЕЖИМ 48×10G (блок B, литералы)
Логический порт : физический : скорость. ВАЖНО: физические 17-20 ПРОПУЩЕНЫ (зарезервированы чипом).
```
portmap_1=1:10   ... portmap_16=16:10      (logical 1-16  -> phys 1-16)
portmap_17=21:10 ... portmap_20=24:10      (logical 17-20 -> phys 21-24  <-- скачок, phys 17-20 нет)
portmap_21=25:10 ... portmap_48=52:10      (logical 21-48 -> phys 25-52)
```
Подтверждённый в бинаре скачок значений: `...15:10, 16:10, 21:10, 22:10...` (16->21).

## Стоковый портмап — QSFP (4×40G нативно / 4×10G breakout, блок A)
```
# нативный 40G (физические порты QSFP):
57:40  61:40  65:40  69:40
# breakout 4x10G тех же QSFP (phys 57-72):
57:10 58:10 59:10 60:10   61:10 62:10 63:10 64:10
65:10 66:10 67:10 68:10   69:10 70:10 71:10 72:10
```
Также в бинаре есть блок `portmap_5=5:40 … portmap_16=49:40` (12×40G, шаг 4 лэйна) и `125:100` —
это, похоже, данные ДРУГИХ платформ (netdevd мультиплатформенный), не нашей карты.

## Сравнение: НАШ config.bcm vs СТОК
| Параметр | Наш | Сток (вшитый) | Вердикт |
|---|---|---|---|
| portmap 1-16 | 1:10..16:10 | 1:10..16:10 | ✅ идентично |
| portmap 17-20 | 21:10..24:10 | 21:10..24:10 | ✅ идентично (пропуск phys 17-20 подтверждён стоком!) |
| portmap 21-48 | 25:10..52:10 | 25:10..52:10 | ✅ идентично |
| QSFP 40G phys | 69/57/65/61:40 | 57/61/65/69:40 | ✅ тот же набор физических |
| QSFP логич. слоты | 49/53/57/61 | (4-лэйновые слоты) | ✅ корректно |
| port_phy_addr_N | заданы явно | вычисляются (format %d) | ⚠️ наши — своя деривация; у стока в бинаре значений нет |
| pbmp_xport_xe | 0x2223fffffffffffe | вычисляется | ⚠️ наш статик |
| xgxs_lcpll_xtal_refclk=1 | статик | ставит в коде + lcpll_lock_check | ⚠️ сток делает то же в коде |
| miim/schan timeout, mdio_delay, intr=0 | наши | нет в литералах | ⚠️ наш тюнинг |

## Вывод
Наш реверс-инженеренный портмап **совпал со стоком один-в-один** (вкл. пропуск physical 17-20 и
мэппинг QSFP) — это подтверждает корректность всей нашей разметки портов. Отличия — только там, где
сток работает программно (phy_addr/pbmp/lcpll/таймауты): мы это задаём статикой в config.bcm, что и есть
штатный SDK-способ воспроизвести то же самое. Файл-реконструкция портмапа: `scripts/config.bcm.stock-ref`.

## pbmp_xport_xe — детальный разбор (из netdevd .rodata)
Литералы лежат в .rodata около 0x10881a0. Сток держит таблицу режимов и выбирает один
по типу карты, затем `soc_property_set(unit,"pbmp_xport_xe",<value>)`.

| Имя | Значение | Декод (порты) |
|---|---|---|
| `pbmp_xport_xe` (generic SDK-дефолт) | `0x1fffffffffffffffe` | 1-64 (CPU=0 искл.) |
| `ghal_port_params_mode_1` | `0x023fffffffffffffe` | 1-57, 61 (breakout-режим QSFP) |
| `ghal_port_params_mode_2` | `0x02223fffffffffffe` | **1-49, 53, 57, 61** — НАШ режим |
| `ghal_port_params_mode_3` | только имя | значения-литерала нет (вычисляется/не исп.) |

mode_2 = 52 порта TA1_LCQ4X48: logical 1-48 (SFP+) + 49/53/57/61 (базовый слот каждого
4-лэйнового QSFP-40G). Numerically == наш `pbmp_xport_xe=0x2223fffffffffffe` (сток пишет 0x022...).
`pbmp_xport_ge` битмап-литерала не имеет (spn_PBMP_GPORT_STACK). Других pbmp_xport_* нет.
Рядом в таблице — QSFP phy_addr↔portmap: 0x50→69:10, 0x51→70:10 … 0x4c→65:10 … 0x48→61:10
(phy_addr hex для лэйнов QSFP, phys 57-72).

## LED: почему сдвиг на 4 с порта 17 (разбор по SDK-исходникам + netdevd)
ВАЖНО (поправка): у нашего чипа **56840 (Trident+) НЕТ регистра PORT_ORDER_REMAP** — он есть
только у hurricane2/Triumph3/CMICm-чипов (src/soc/esw/hurricane2.c:2805, include/soc/mcm/cmicm.h).
Ранняя версия этого раздела ошибочно предлагала `setreg CMIC_LEDUP*_PORT_ORDER_REMAP` — для 56840
это НЕПРИМЕНИМО. Реальный механизм Trident:

- Микрокод LED-процессора в netdevd (offset 0x1088700) **байт-в-байт = наш** box-leds.sh.
- Статус порта кладётся в DATA_RAM по ФИЗИЧЕСКОМУ порту (src/soc/common/counter.c:5656, SOC_IS_TD_TT):
  `phy_port = port_l2p_mapping[port]`; LEDUP0 для phys 1-36, LEDUP1 для phys 37-72 (phys-=36);
  `byte = LS_LED_DATA_OFFSET(0x80) + phy_port`; запись `dram_base + 4*byte`.
  Базы (include/soc/cmic.h): CMICE_LEDUP0_DATA_RAM_BASE=0x1400, LEDUP1=0x2400; REG_SIZE=4.
- Микрокод читает DATA_RAM (с offset 0x80) и сдвигает в панельную цепочку (фиксированный порядок).
- МЕХАНИЗМ −4: DATA_RAM индексируется физ.портом, а физ.порты 17-20 зарезервированы (дырка) →
  в сочетании с панельной разводкой цепочки (48 диодов подряд) даёт −4 для cage≥21, позиции 17-20 тёмные.

ФИКС (правильный для Trident, без REMAP): либо (а) писать статус в DATA_RAM по «панельному» слоту,
а не по физ.порту (т.е. свой маппинг phys→slot, компенсирующий дырку 17-20) — через пересборку
(правка LED-коллбэка counter.c) ИЛИ периодическим devmem-ремапом из Linux; либо (б) принять −4.
Devmem-адреса per-port статуса (BAR 0xc0000000): LEDUP0 phys P(1-36)=0xc0000000+0x1400+4*(0x80+P);
LEDUP1 phys P(37-72)=0xc0000000+0x2400+4*(0x80+(P-36)). Эти ячейки можно ЧИТАТЬ devmem'ом при живом
стоке (без diag-шелла) — характеризовать раскладку эмпирически. СНАЧАЛА проверить: показывает ли СТОК
панель ровно или тот же −4 (если тот же — это разводка панели, «фикс» = просто сместить запись на 4).

## LED −4: РЕШЕНО — корневая причина найдена в исходнике (2026-10-05)
Шаг 1 (serial, глазами): под СТОКОМ диоды РОВНЫЕ → это не разводка панели, а наш путь записи.
Шаг 2 (serial devmem, наш bcm.user): горит только slot (idx 0xA3) = `LS_LED_DATA_OFFSET_A0(0xa0)+phy_port 3`
→ линканулся форс `xe3`; подтверждает «пишем по phys без компенсации».

КОРЕНЬ (однозначно): `src/appl/diag/ledproc.c`, callback `ledproc_linkscan_cb` (его ставит `led auto on`):
схлопывание дырки через `skip_count` есть ТОЛЬКО в ветке `if (SOC_IS_TRIDENT2(unit))`. Наш BCM56840 =
Trident (SOC_IS_TD_TT=1, SOC_IS_TRIDENT2=0) → уходит в `else { byte = LS_LED_DATA_OFFSET_A0 + phy_port; }`
БЕЗ skip_count. Физ.порты 17-20 (p2l=-1) не выбрасываются из индекса → панель едет на −4 с cage 17.
Сток (netdevd) компенсирует → у него ровно. 56840 использует A0-offset (0xa0), подтверждено эмпирически.

ФИКС (сделан, собран): в том `else` добавлена та же skip_count-логика, что у Trident2, но с ledup0_pmax(36):
```
int i, skip_count = 0;
for (i=1; i<phy_port; i++)
    skip_count += (si->port_p2l_mapping[i+(led_ix*ledup0_pmax)] == -1) ? 1 : 0;
byte = LS_LED_DATA_OFFSET_A0 + phy_port - skip_count;
```
Проверка математики: phys 21 (cage17): skip=4 (phys17-20 unmapped) → byte=0xa0+21-4=0xa0+17 → панель 17 ✓.
skip_count=0 для чипов без дырок → поведение не меняется (безопасно). Патч: patches/sfpscan.patch,
бинарь: bins/bcm.user.sfpscan-ledfix.gz. Деплой — когда вернётся SSH (40МБ по serial не зальёшь);
проверка после деплоя: воткнуть в cage 17/21 → диод должен совпасть с номером разъёма.

## Стоковый soc-property set + init (реверс netdevd, 2026-10-05, субагент)
Config-apply @vaddr 0x103f7f90 → djb2-setter set_cfg(name,value) @0x105ad43c. netdevd = sdk-xgs-robo-6.3.2,
собран 2020-05-20. ВАЖНАЯ ПОПРАВКА: 56840 = **Trident+** → MMU-путь `ndd_bcm_mmu_config_trident_plus`
(0x1090f60), НЕ _trident2.

### Дельты стока vs дефолтов SDK (литерал-подтверждённые)
```
bcm_stat_interval=3000000     # SDK default 1000000; у нас 0 (выкл)
bcm_stat_jumbo=16348          # SDK default 1518 — ДЖАМБО-кадры
bcm_stat_flags=1
buf.mqueue.pool_scale=0.5     # MMU
xgxs_lcpll_xtal_refclk=1      # SDK default 0 — у нас ЕСТЬ ✓ (LCPLL-фикс)
table_dma_enable=1            # у нас ЕСТЬ ✓
tslam_dma_enable=1            # у нас ЕСТЬ ✓
miim_intr_enable=1            # у нас 0 (!) — меняли под real-IRQ
bcm56822_8x16=1
higig2_hdr_mode=1
module_64ports=1              # 64-портовый режим — у нас НЕТ
```
Инференс (в stripped-бинаре значение не добивается чисто — сверить live `config show`/snapdb):
`polled_irq_mode=0` (у нас убран ✓), `schan_intr_enable=0` (у нас ✓), `port_init_autoneg_xe=0`,
`parity_enable=0`, `bcm_num_cos=4`.
generic `pbmp_xport_xe=0x1fffffffffffffffe` (ставится, ПОТОМ ghal_port_params_mode_2=0x02223fffffffffffe
под карту). port_phy_addr_1..52, phy_84754_1..48, phy_84740_49..64, portmap_1..20 — литералы (см. выше).
Per-port runtime (sprintf): serdes_firmware_mode_%d, phy_pcs_repeater_%d, serdes_fiber_pref_<port>,
phy_sgmii_autoneg_<port>. Полный spn_-каталог вкомпилен (phy_an_c73, dport_map_*, buf.<class>.<field>).

### Init-последовательность стока (реконструкция)
1. PCI attach + system_init + launch diag shell; 2. probe (unit/port); 3. применить soc-props (выше);
4. l2switch_init_unit part1/part2, init_bcm_ports; 5. per-xe PHY: `bcm phy xe%d 9 1 0` + `bcm phy ... srl=1`;
6. цикл `bcm modreg RDBGC1..7_SELECT BITMAP=0x%x` (debug-счётчики); 7. `ndd_bcm_mmu_config_trident_plus`;
8. linkscan (pbmp+interval); 9. xe_leds_set/ge_leds_set; 10. QoS/rate-limit. Каждая: лог «BCM command # N».
netdevd также ссылается на литерал `rc.soc` (0x10d87b8) — может и файл подхватить.

### MMU / вентиляторы
MMU: кроме `buf.mqueue.pool_scale=0.5` всё вычисляется в рантайме через buf.<class>.<field> внутри
mmu_config; буфер-пороги ещё и рулятся action'ом `/gv/internal/actions/netdevd/buffer_threshold`.
Хард-кодов cell/threshold из функции не достали (stripped). Вентиляторы: netdevd их НЕ контролирует —
только читает температуру и инвентарь fantray; PWM MAX6650 — отдельный демон (совпадает с нашим воркэраундом).

ПРИМЕНЕНИЕ: НЕ менять рабочий config.bcm вслепую (наш init тонко настроен под real-IRQ: miim_intr_enable=0,
bcm_stat_interval=0 — осознанно). Кандидаты на пробу (на железе, по одной) — scripts/config.bcm.stock-deltas.
