# План: L3 и управление (2026-10-18)

Состояние на старт: L2-свитч работает полностью (48 SFP + 4 QSFP, хотплаг, LED, счётчики),
VLAN — раскладка из `vlan.conf` (код готов, на железе не проверен). Дальше по порядку: L3, управление.

## L3: маршрутизация между VLAN

### Главная проблема — кто отвечает на ARP
Чип маршрутизирует аппаратно только по таблицам (L3-интерфейсы, egress-объекты, host/route).
Отвечать на ARP за IP шлюза, резолвить MAC следующих хопов, отвечать на ping — должен CPU.
У нас bcm.user работает в user-mode без Linux-интерфейсов — сейчас пакеты до CPU никто не обрабатывает.

### Решение: KNET + Linux как control-plane
- **KNET** (Broadcom kernel-net): CPU-порт чипа превращается в Linux-интерфейсы. Сток делал ровно
  так (`linux-uk-proxy` + `linux-bcm-knet`, интерфейсы `bcm0`/`cmif0`), модули уже грузятся
  box-start'ом. Нужно пересобрать `bcm.user` с `BUILD_KNET=1` (diag-команда `knet netif/filter`).
- На каждый L3-VLAN — Linux-интерфейс `vlanN` с IP шлюза. ARP, ICMP, (позже OSPF/BGP) делает ядро.
- **sync-демон**: читает соседей и маршруты ядра и программирует чип:
  сосед (IP, MAC) → порт по L2-таблице чипа → `l3 egress add` + `l3 l3table add` (host);
  маршрут → `l3 defip add` (LPM) на egress шлюза; удалённые — убирает.
  MVP — sh-скрипт с опросом раз в 1-2с через FIFO (как SFPScan-поллер); потом — C с netlink.
- Чип: `l3 init`, L3-интерфейс на VLAN (`l3 intf add Vlan=N Mac=<router-mac>`), router-MAC в L2
  с флагом L3, CPU-порт в членах L3-VLAN (vlan-gen надо научить добавлять `cpu`).

### Альтернатива без KNET (не рекомендую)
Только статика: IP шлюза, MAC соседей и маршруты руками в конфиге. Не работает без статического
ARP на всех хостах (на ARP к шлюзу никто не ответит) — непригодно для обычной сети.

### Этапы
1. **Проверка на железе (первым делом):** на коробке есть `linux-bcm-knet.ko` и `/etc/rc.d/init.d/linux-bcm-knet`
   (box-start их зовёт); есть ли `ip` (iproute2/busybox) и `vconfig`; ABI стокового knet с нашим SDK
   (тот же вендорный 6.3.2 — ожидаемо совместим). Если стоковый модуль не подойдёт — собрать свой
   (`systems/linux/kernel/modules/bcm-knet`, заголовки ядра 2.6.34 — `work/khdr`).
2. ✅ Собран `bins/bcm.user.knet.gz` (md5 `b051ec6c…`, 2026-10-18): все наши патчи + `knetctrl`.
   Сборка — отдельный каталог: `make bcm … BLDCONFIG=knet FEATURE_LIST="L3 I2C BCMX BCMX_DIAG MEM_SCAN
   EDITLINE RCPU OOB_RCPU CUSTOMER TEST CHASSIS CINT PTP BFD BHH CES KNET"` (перед линковкой
   `mkdir -p build/knet/linux/user/gto-2_6`). На железе НЕ проверен: с KNET приём пакетов CPU идёт
   через модуль ядра — проверить, что init и L2 не меняются, и откатываться на current при сбое.
   ✅ 24.10 на железе: init/L2 без изменений (загрузка с первой попытки), стал боевым (bcm.user.current).
   ✅ KNET в обе стороны: `knetctrl netif create Vlan=1 IFName=vlan1`, `knetctrl filter create DestType=NetIF
   DestID=1 PRIOrity=0` → TX: ARP из Linux ушёл широковещательно в xe43/xe46; RX: петля `port xe0 lb=mac`
   вернула наши ARP в vlan1 (3 пакета). Внешнего трафика на DAC нет — та сторона молчит.
   Дальше: `knet netif create` один интерфейс, `knet filter` —
   ARP и кадры на router-MAC → в Linux; поднять IP, проверить ping шлюза из VLAN.
3. Включить L3 на чипе для двух VLAN, вручную `l3 egress/l3table` для пары хостов — ping между VLAN
   аппаратно (CPU не грузится — проверить счётчиками и `top`).
4. sync-демон MVP (sh, опрос), `l3.conf`: какие VLAN маршрутизируются, IP шлюзов, статические маршруты.
5. Нагрузка: ARP-шторм не должен положить P2020 (CPU-очереди, rate-limit на `knet filter`/COS).

### Риски
- Ядро 2.6.34 и старый userland: iproute2 может не быть — тогда busybox/ifconfig/route + vconfig.
- FIFO-синхронизация медленная (сотни соседей — ок, тысячи — нужен C-демон и прямые вызовы API).
- ECMP, IPv6, multicast-роутинг — вне MVP.

## Управление

Цель — не гонять руками `echo '...' > /tmp/bcm.fifo` и не помнить карту клетка→xe.

1. **CLI `sw`** (sh на коробке, первым): `sw ports` (клетки, линк, скорость, модуль),
   `sw counters <клетка>`, `sw vlan` (из vlan.conf + `vlan show`), `sw apply vlan`,
   `sw sfp <клетка>` (EEPROM через SFPScan dump). Обмен с bcm.user через FIFO с маркером
   (`echo === SW <id>` до и после, вырезать ответ из bcmrun.log) — уже отработано в этой сессии.
2. **Веб-страница** (вторым): статус портов картой панели + счётчики + VLAN; CGI на busybox httpd
   (проверить наличие) поверх того же `sw` в режиме `--json`.
3. Конфиг-база GigaVUE (`mdreq`) — не используем для своего, только для mgmt-IP (замена DHCP-хака
   в boot.sh — см. память config-db).

Безопасность: учётка `op` — только ключ (пароль `*`, проверено). Штатный `admin` (CLI GigaVUE)
остаётся со своим паролем — проверить, если коробка будет в общей сети.
