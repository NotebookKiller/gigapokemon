# Gigamon TA100 → обычный свитч: разбор образа и план

Лог работы по превращению Gigamon TA100 (сетевой видимости / трафик-агрегатор)
в нормальный L2/L3-свитч. Исходник — `gigamon.bin`, посекторный образ SD-карты,
снятый с самой железки.

---

## Железо

- **Модель:** Gigamon TA100 (внутренний код платформы `gvag`, карта `TA1_LCQ4X48`).
- **Порты:** 48×SFP+ 10G (`x1–x48`) + 4×QSFP 40G (`q1–q4`).
- **ASIC:** Broadcom **BCM56846A1KFRBG** — Trident+ (семейство XGS, в SDK
  фигурирует как `bcm56840`/`56846`).
- **CPU:** Freescale/NXP **P2020E** (PowerPC e500v2, 32-bit, big-endian).

## Что за прошивка

- **GigaVUE-OS 5.4.04**, сборка 185888 от 2020-05-20 (образ 1).
  Второй образ (A/B-схема) — 5.4.01, сборка 107030 от 2018-09-30.
- Ядро Linux **2.6.34** (`2.6.34-GIGAMONsmp-gvag`), PPC 85xx, SMP.
- Userspace очень старый: **glibc 2.6 (2008 г.), gcc 4.2.2**.
  → Порт современного NOS/своего кода под это окружение крайне трудоёмок;
  реалистичнее переиспользовать их бинарники.

## Разметка SD-карты (`gigamon.bin`)

| Part | Метка    | ФС    | Что внутри |
|------|----------|-------|------------|
| p1   | BOOTMGR  | ext3  | grub-fallback + `u-boot/uic-a.conf` (NVS-env) |
| p2   | BOOT_1   | FAT16 | ядро/dtb образа 1 (`vmlinuz`, `fdt`, System.map) |
| p3   | BOOT_2   | FAT16 | ядро/dtb образа 2 |
| p5   | ROOT_1   | ext3  | rootfs образа 1 (5.4.04) |
| p6   | ROOT_2   | ext3  | rootfs образа 2 (5.4.01) |
| p7   | CONFIG   | ext3  | БД конфигурации (`db/initial*`), mfg, ключи, лицензии |
| p8   | VAR      | ext3  | логи, `opt/tms/output/{passwd,shadow}`, runtime |

Извлечение: `dd` по offset'ам из `fdisk -l`, ext3 — через `debugfs -R rdump`,
FAT — через `7z x`.

---

## Архитектура управления ASIC (главное для задачи)

1. `rc.sysinit` распаковывает `/opt-binaries.tar.bz2` в tmpfs → симлинк
   `/opt/tms/bin/netdevd` (37 МБ). Запуск/рестарт — процесс-менеджер **`pm`**,
   управляемый из **`mgmtd`** (узлы `/pm/actions/...`; пусковая таблица — в БД
   `mgmtd`, файлы `p7/db/initial*`, не plain-скрипт).
2. `load_bcm.sh` грузит **BDE-модули ядра** (собраны ровно под их 2.6.34/PPC):
   `linux-kernel-bde.ko dmasize=64M` (ветка `gmon,ag`) → `linux-user-bde` →
   `linux-uk-proxy` → `linux-bcm-knet` (CPU inject/capture).
3. **`netdevd`** статически слинкован с **Broadcom SDK 6.3.2**, инициализирует
   чип и накатывает режим **«Aggregator»** (`card.json`:
   `"platform_class": "Aggregator"`). Конфиг чипа генерится из JSON в
   `etc/gvag/netdevd/*.json` + вкомпиленных `soc_property`; файлов
   `config.bcm`/`rc.soc` на диске НЕТ.
4. Управление после старта — через **ndd-сокет**, узлами
   `/gv/internal/actions/netdevd/*`. Среди них есть примитивы нормального
   свитчинга: `vlan`, `port_bridge`, `port_pair`, `vport`, `ip_interface`,
   `mcast`, `ipmc` — т.е. физически чип это умеет, «агрегатор» лишь способ
   конфигурации.

### Вывод по стратегии

- **SONiC/Cumulus — отпадают.** Замок не в цене NOS (SONiC бесплатен), а в
  **SAI/libsai** под старый Trident+ (BCM56846) — публично его, скорее всего,
  нет. Плюс древнее окружение. Cumulus вдобавок платный (NVIDIA).
- **Родной путь — лучший.** В образе уже есть рабочий **Broadcom SDK 6.3.2** +
  **BDE-модули** под это ядро. Внутри `netdevd` — полный **Broadcom diag-шелл**
  (`BCM.0>`, `vlan/port/l2/stg/trunk`, вывод в `/tmp/bcm.log`). Значит чип можно
  гонять в L2/L3 без написания кода — командами.

---

## Доступ / загрузчик

- **`BOOTMGR_PASSWORD` ПУСТОЙ** (`uic-a.conf`/NVS) → меню bootmgr на serial НЕ
  защищено, kernel args правятся свободно.
- Kernel args в NVS: `IMAGE_1_KERNEL_ARGS = "img_id=1 quiet loglevel=4 panic=1"`.
  Single-user mode в inittab отключён, но **`init=/bin/bash`** его обходит →
  голый root без пароля.
- Консоль: `agetty ttyS0` на **115200** (u-boot/bootmgr), ОС-консоль в grub —
  **9600** (`console=ttyS0,9600n8`). Держать оба под рукой.
- Учётки (реальные — `p8:/opt/tms/output/passwd`):
  - `admin` — **uid 0**, шелл `/opt/tms/bin/cli` (штатный вход админа);
  - `root` — uid 0, но `/sbin/nologin`; пароль задан (`$1$…`, MD5, неизвестен);
  - `monitor` — uid 1001, шелл CLI.

## Путь к diag-шеллу

- Два входа в шелл: `bcm_shell_thread` (интерактив, **stdin**/`fgets`) и
  `bcm_shell_svc_thread` (сервисный, ndd-сокет). Под `pm` netdevd
  демонизирован → штатный путь **сервисный, через `mdreq action`**.
- Их `customer.sh` так и делает:
  `mdreq action /gv/internal/actions/dump/netdevd mode string full`, рядом
  забирает `/tmp/bcm.log`.
- **Осталось подтвердить вживую:** точный узел/параметр для инъекции
  произвольной diag-команды (явного «run raw command» в списке action-узлов
  нет, но dump-механика доказывает, что netdevd команды на запрос выполняет).

---

## Открытые вопросы (подтверждать на живой коробке)

1. Точный `mdreq`-узел для произвольной diag-команды.
2. Коммутирует ли чип с **MAC-learning** — в TAP/aggregator-режиме learning
   часто выключен; надо проверить в PoC.
3. Реальная скорость serial ОС-консоли (9600 vs 115200).

## Инструменты на хосте разбора

`binwalk`, `7z`, `unsquashfs`, `debugfs` (ext3 rdump), `dd`, `strings`, `file`.

## Файлы

- `gigamon.bin` — образ SD (не трогать, золотой бэкап).
- `runbook.md` — пошаговый план для работы на верстаке.
