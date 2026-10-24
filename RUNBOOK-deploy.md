# RUNBOOK — деплой нашего свитча на TA100

Актуально на 2026-10-17. Команды выполняются **с хоста**, где лежит репозиторий и который видит
коробку (сеть 10.156/22), из корня репо. Коробка: `op@10.156.0.133` (RSA-ключ).

```sh
B=op@10.156.0.133
cd /home/alexander_getman/claude-gigamon
```

## Что сейчас стоит на коробке (канон = репо)

| Репо | Коробка | Что это |
|---|---|---|
| `bins/bcm.user.current.gz` (md5 `b051ec6c…`) | `/var/bcm/bcm.user` | SDK-апп: SFPScan + LED-fix + fast-presence + xfifix + KNET |
| `scripts/config.bcm` | `/var/bcm/config.bcm` | soc-свойства: портмап, PHY-адреса, phy_long_xfi |
| `scripts/rc.soc` | `/var/bcm/rc.soc` | init: БЕЗ `an=on`, SFPScan `xe0-xe47` |
| `scripts/box-start.sh` | `/var/bcm/box-start.sh` | автозапуск: заморозка pm, BDE, bcm.user, LED, хотплаг-поллер |
| `scripts/box-leds.sh` | `/var/bcm/box-leds.sh` | LED-микрокод + карта панели + зеркала (17-20, 33-36) |
| `scripts/box-boot.sh` | `/var/bcm/boot.sh` | сетевой watchdog (DHCP .133, учётка op) |
| `scripts/box-fans.sh` | `/var/bcm/fans.sh` | тихие вентиляторы MAX6650 (на коробке та же логика без комментариев) |
| `scripts/vlan.conf` | `/var/bcm/vlan.conf` | раскладка VLAN в номерах клеток (пустой = всё в VLAN 1) |
| `scripts/vlan-gen.sh` | `/var/bcm/vlan-gen.sh` | vlan.conf → vlan.soc (diag-команды); box-start зовёт через `sh` |
| `scripts/l3.conf` | `/var/bcm/l3.conf` | L3: `l3 <vid> <ip/pfx>` (шлюзы), `route <pfx> via <gw>`; пустой = L3 выкл. |
| `scripts/l3d` | `/var/bcm/l3d` | L3-демон: KNET-шлюзы + соседи ядра → таблицы чипа; box-start зовёт через `sh` |
| `scripts/sw` | `/var/bcm/sw` | CLI: `sw ports / counters <клетка> / vlan [apply] / sfp [клетка] / raw <cmd>` |

Откат бинаря: `bins/bcm.user.pre-xfifix.gz` (md5 `4040c9a7…`, без хотплаг-фикса); без KNET — git-история current (27ec25cf), на коробке `bcm.user.bak-pre-knet`.

## Карта портов (24.10, как у стока)

- **Клетка N = логический порт N = xe(N-1)** для всех 48 SFP-клеток; Q1-Q4 = xe48-51 (40G).
- phys: клетки 1-16 = phys 1-16, клетки 17-48 = phys N+4 (phys 17-20 — резерв чипа).
- PHY 84754: клетки 1-24 = адрес N+3, клетки 25-48 = N+11 (как в стоковом `config show`).
- До 24.10 PHY-адреса 17-48 были сдвинуты на квад: PHY клетки N висел на чужой линии
  Warpcore — линк показывался, а данные не ходили. Всё, что «чинилось» поверх этого
  (LED-зеркала, cage1720, long_xfi), убрано; xfifix в SFPScan пока оставлен.

## Залить текстовый файл (скрипт/конфиг)

⚠️ `cat > файл` создаёт файл **без +x**. box-start запускает LED-блок только при `[ -x box-leds.sh ]` и
молча пропускает его — после ребута горят ВСЕ диоды. Поэтому всегда `chmod +x` для скриптов.

```sh
# скрипт (пример: box-leds.sh)
ssh $B 'cat > /var/bcm/box-leds.sh.new' < scripts/box-leds.sh
ssh $B 'cd /var/bcm; sh -n box-leds.sh.new && mv box-leds.sh.new box-leds.sh && chmod +x box-leds.sh && echo OK'

# конфиг (+x не нужен)
ssh $B 'cd /var/bcm; cp -a config.bcm config.bcm.bak-$(date +%F); cat > config.bcm' < scripts/config.bcm
ssh $B 'cat > /var/bcm/rc.soc' < scripts/rc.soc
```

## Залить бинарь (40 МБ)

```sh
gunzip -c bins/bcm.user.current.gz > /tmp/bcm.user.new
scp -o ConnectTimeout=15 /tmp/bcm.user.new $B:/var/bcm/bcm.user.new
ssh $B 'cd /var/bcm; md5sum bcm.user.new; cp -a bcm.user bcm.user.bak-$(date +%F); \
  kill -9 $(pidof bcm.user) 2>/dev/null; sleep 1; \
  mv bcm.user.new bcm.user && chmod +x bcm.user && sync && reboot -f'
```
Замена запущенного bcm.user без `kill -9` даёт «text file busy» (молча).

## Ребут

```sh
ssh $B 'kill -9 $(pidof bcm.user); sync; reboot -f'
```
Самовосстановление GigaVUE + DHCP занимает 3-5 мин (watchdog в boot.sh заново заводит op и .133).
SSH-команда с ребутом всегда «зависает»/падает с 255 — это нормально.

## Проверка после ребута

```sh
ssh $B 'md5sum /var/bcm/bcm.user | cut -c1-8; pidof bcm.user; grep -c BOX_INIT_DONE /tmp/bcmrun.log; \
  tail -4 /tmp/box-start.log; \
  printf "LED CTRL0=%s CTRL1=%s\n" $(busybox devmem 0xc0001000 32) $(busybox devmem 0xc0002000 32); \
  echo ps > /tmp/bcm.fifo; sleep 2; tail -60 /tmp/bcmrun.log | tr -d "\r" | grep -E "^ +xe[0-9]+ +up"'
```
Ожидаем: md5 `b051ec6c`, `BOX_INIT_DONE`=1, в логе `[led]` и `[hotplug]`, LED CTRL = `0xB3`/`0xF3`
(бит0=1 — процессор запущен), up только порты с модулями. Глазами: диоды = клетки с линком.

## VLAN

Раскладка — `/var/bcm/vlan.conf`, номера клеток как на панели (формат и пример — в самом файле).
При загрузке box-start делает `vlan-gen.sh vlan.conf > vlan.soc`, rc.soc подгружает его `rcload`.
Ошибка в vlan.conf → в box-start.log строка `[vlan] ОШИБКА…`, свитч остаётся плоским (VLAN 1).

```sh
# залить раскладку и применить НА ХОДУ (без ребута; vlan.soc идемпотентен)
ssh $B 'cat > /var/bcm/vlan.conf' < scripts/vlan.conf
ssh $B 'cd /var/bcm; sh vlan-gen.sh vlan.conf > vlan.soc && cat vlan.soc && echo "rcload /var/bcm/vlan.soc" > /tmp/bcm.fifo'
# проверить
ssh $B 'echo "vlan show" > /tmp/bcm.fifo; echo "pvlan show xe" > /tmp/bcm.fifo; sleep 2; tail -40 /tmp/bcmrun.log'
```
Проверить генератор на хосте до заливки: `sh scripts/vlan-gen.sh scripts/vlan.conf`.

## L3

`l3d` стартует из box-start после init (лог `/tmp/l3d.log`). На каждый `l3 <vid> <ip/pfx>`:
CPU в членах VLAN, KNET-интерфейс `vlan<vid>` + фильтр по VLAN, IP шлюза, `l3 intf add`
(INtf = vid), MAC роутера в L2 с флагом L3; глобально `UnknownL3DestToCpu=1`, `ip_forward=1`.
Цикл раз в 2 с: соседи ядра → порт по L2-таблице → `l3 l3table add`; раз в 30 с повтор
инициализации (переживает `sw vlan apply`).

```sh
ssh $B 'sh /var/bcm/l3d status'          # что стоит в чипе
ssh $B 'tail /tmp/l3d.log'
# проверка, что маршрутизирует чип: при ip_forward=0 ping между VLAN идёт, HIT=y,
# а счётчики /sys/class/net/vlan*/statistics/rx_packets не растут
```

## CLI sw

```sh
ssh $B 'cat > /var/bcm/sw' < scripts/sw && ssh $B 'chmod +x /var/bcm/sw'
ssh $B /var/bcm/sw ports          # клетки, линк, скорость
ssh $B /var/bcm/sw counters 48    # счётчики клетки 48
ssh $B /var/bcm/sw vlan apply     # применить vlan.conf без ребута
```

## Диагностика на ходу

- Diag-команды: `echo '<cmd>' > /tmp/bcm.fifo`, вывод в `/tmp/bcmrun.log` (строки с `\r`).
- Хотплаг-тест на клетке N: `port xeK an=on` → через ≤20с поллер SFPScan вернёт 10G и линк.
- Регистры Warpcore конкретной линии: `phy int` / прямой адрес НЕ выбирают линию (идут на lane 0).
  Вручную: `phy raw <int_addr> 0x1f 0xffd0; phy raw <int_addr> 0x1e <lane>; phy raw <int_addr> 0x1f <block>;
  phy raw <int_addr> 0x1<off>` (int_addr — из `phy info`, lane = (phys-1)%4). В конце вернуть AER в 0.

## Откат на сток (netdevd)

```sh
ssh $B 'touch /var/bcm/DISABLE; kill -9 $(pidof bcm.user) 2>/dev/null; sync; reboot -f'
```
Обратно на наш свитч: `rm /var/bcm/DISABLE` и ребут.

## Опасности (из опыта)

- Никогда не `kill -CONT pm` при мёртвом netdevd — ребутит/вешает коробку.
- При замороженном pm обычный `reboot` не проходит — только `kill -9 bcm.user; sync; reboot -f`.
- Крайнее средство — serial (`co:` bash в inittab) или питание.
