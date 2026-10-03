# Вечерний деплой bcm.user на коробку

Цель: запустить наш собранный `bcm.user` на TA100 и получить живой `BCM.0>`,
приаттаченный к реальному BCM56846. Пакет: `work/bcm-deploy.tgz` (bcm.user +
run-bcm.sh + config.bcm.ref + rc.soc.ref).

## 1. Залить файлы на коробку (сети нет → через SD)

Вставь рабочую ~4 ГБ SD (ту, с которой грузится коробка) в ПК. Разделы появятся
как `/dev/sdX1..8`. Нужен раздел **8 (VAR → /var на коробке)**:

```
lsblk                                  # найди карту, определи букву sdX
sudo mount /dev/sdX8 /mnt              # VAR
sudo mkdir -p /mnt/bcm
sudo tar xzf /home/alexander_getman/claude-gigamon/work/bcm-deploy.tgz -C /mnt/bcm
sudo sync && sudo umount /mnt
```
На коробке файлы окажутся в **`/var/bcm/`**.
(Если VAR-скелет при загрузке затрёт — альтернатива: раздел 5, rootfs, в /opt/bcm.)

## 2. Загрузить коробку и запустить

Вставь SD в железку, serial 115200. Грузись штатно (inittab-трюк → сразу
root-bash на консоли, сервисы и BDE-модули поднимутся). В `bash-3.2#`:

```
chmod +x /var/bcm/bcm.user /var/bcm/run-bcm.sh
/var/bcm/run-bcm.sh
```

`run-bcm.sh` сам: заморозит `pm` (чтобы не ребутил), убьёт `netdevd` (освободит
чип), проверит `/dev/linux-user-bde` и запустит `bcm.user`.

## 3. Что ожидаем (момент истины)

Должен подняться наш шелл и **приаттачиться к чипу**:
```
Broadcom Command Monitor ... Release: sdk-6.3.2 ...
...
BCM.0>
```
В отличие от qemu — здесь НЕ должно быть «No attached units» (чип реальный).
Проверь доступ к кремнию:
```
BCM.0> show unit         # должен показать unit 0 = BCM56846
BCM.0> ps                # статус портов xe0..xe47, ce0..ce3
BCM.0> version
```
Если `show unit` показывает BCM56846 — **мы впервые управляем чипом своим софтом.**

## 4. Если приаттачилось — пробуем L2 (первый свитч)

Вернуть референс-конфиги и дать базовую L2-инициализацию:
```
BCM.0> exit
cp /var/bcm/config.bcm.ref /var/bcm/config.bcm   # пока референс GTO (порты докрутим)
/var/bcm/run-bcm.sh
```
В шелле вручную (минимальный L2 на паре портов — синтаксис уточним по `help`):
```
BCM.0> vlan create 1 pbm=xe0,xe1
BCM.0> port xe0,xe1 en=1
BCM.0> l2 show
```
Воткнуть два линка в эти порты → проверить ping и обучение MAC (`l2 show`).

## Заметки / грабли
- `pm` оставлен замороженным после запуска. Вернуть: `kill -CONT $(pidof pm)`.
  Выйти из эксперимента чисто: `reboot` (или питание).
- Первый запуск — БЕЗ config.bcm/rc.soc (лежат как `.ref`), чтобы bcm.user
  стартовал чисто и просто приаттачился. Конфиги вводим на шаге 4.
- Порты в референс-config.bcm — от платы GTO_MPC8548, НЕ от TA100. Если порты не
  линкуются — это ожидаемо; реальный port/serdes-маппинг снимем с живого дампа
  (box-chip-state.sh) и допишем config.bcm. Это Фаза 3.
- Если `/dev/linux-user-bde` нет — значит BDE-модули не загрузились; проверь
  `lsmod | grep bde` и `load_bcm.sh`.
