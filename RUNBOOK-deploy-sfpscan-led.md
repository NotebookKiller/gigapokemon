# RUNBOOK — деплой bcm.user (SFPScan + LED-fix + fast-presence) + box-start (ретрай+хотплаг)

Дата готовности: 2026-10-05. Выполнять РУКАМИ по SSH, когда вернётся доступ к коробке.
Все команды — **с хоста, где лежит репозиторий и который достаёт коробку** (та же сеть 10.156/22),
из каталога `/home/alexander_getman/claude-gigamon`. Коробка: `op@10.156.0.133` (RSA-ключ).

```sh
B=op@10.156.0.133                 # цель SSH
cd /home/alexander_getman/claude-gigamon
```

Что деплоим:
- `bins/bcm.user.sfpscan-ledfix.gz` → `/var/bcm/bcm.user` (новый бинарь, 3 фикса)
- `scripts/rc.soc.sfpscan` → `/var/bcm/rc.soc` (SFPScan вместо хардкод-форса)
- `scripts/box-start.sh` → `/var/bcm/box-start.sh` (авто-ретрай флейка + хот-плаг-поллер)

---

## 0. Пре-флайт — коробка жива и на чём сейчас
```sh
ssh -o ConnectTimeout=8 $B 'echo OK; uptime; echo "--- prod bcm.user:"; ls -la /var/bcm/bcm.user; \
  echo "--- DISABLE есть?:"; ls -la /var/bcm/DISABLE 2>/dev/null || echo "нет (автозапуск активен)"; \
  echo "--- switch:"; pidof bcm.user && grep -c BOX_INIT_DONE /tmp/bcmrun.log 2>/dev/null'
```

## 1. Бэкап текущего прода (на коробке)
```sh
ssh $B 'cd /var/bcm; D=$(date +%F); \
  cp -a bcm.user   bcm.user.bak-$D 2>/dev/null; \
  cp -a rc.soc     rc.soc.bak-$D   2>/dev/null; \
  cp -a box-start.sh box-start.sh.bak-$D 2>/dev/null; \
  echo "бэкап:"; ls -la bcm.user.bak-* rc.soc.bak-* box-start.sh.bak-* 2>/dev/null | tail'
# (старый рабочий bcm.user.orig на коробке уже есть — это доп. запас)
```

## 2. Залить новые файлы (во временные имена .new)
```sh
# бинарь (40МБ, scp ок):
gunzip -c bins/bcm.user.sfpscan-ledfix.gz > /tmp/bcm.user.new
ls -la /tmp/bcm.user.new                         # ждём ~39929298 байт
scp -o ConnectTimeout=15 /tmp/bcm.user.new $B:/var/bcm/bcm.user.new

# мелкие текстовые — через ssh 'cat>' (scp мелочи раньше капризничал):
ssh $B 'cat > /var/bcm/rc.soc.new'        < scripts/rc.soc.sfpscan
ssh $B 'cat > /var/bcm/box-start.sh.new'  < scripts/box-start.sh

# сверка на коробке:
ssh $B 'cd /var/bcm; ls -la bcm.user.new rc.soc.new box-start.sh.new; \
  echo "SFPScan в бинаре:"; strings bcm.user.new | grep -c SFPScan; \
  echo "rc.soc:"; cat rc.soc.new; sh -n box-start.sh.new && echo "box-start синтаксис OK"'
```

## 3. Установка (глушим bcm.user → подменяем файлы → снимаем kill-switch)
Замена `/var/bcm/bcm.user` на ходу даёт «text file busy», поэтому сперва убить его.
Свитч на пару минут ляжет — всё равно сразу ребутаем.
```sh
ssh $B 'cd /var/bcm; \
  kill -9 $(pidof bcm.user) $(pidof script) 2>/dev/null; sleep 1; \
  mv bcm.user.new bcm.user && chmod +x bcm.user; \
  mv rc.soc.new rc.soc; \
  mv box-start.sh.new box-start.sh && chmod +x box-start.sh; \
  rm -f DISABLE .boxstart_retries; \
  sync; echo "установлено:"; ls -la bcm.user rc.soc box-start.sh; \
  echo "DISABLE (должно НЕ быть):"; ls DISABLE 2>/dev/null || echo "нет -> автозапуск нашего свитча ВКЛ"'
```

## 4. Чистый ребут (надёжный рецепт)
```sh
ssh $B 'kill -9 $(pidof bcm.user) 2>/dev/null; sync; reboot -f'
```
⚠️ Самовосстановление GigaVUE+DHCP занимает **~3–5 мин** (boot.sh-watchdog заново заводит `op` и DHCP .133).
Первые пару минут нормально видеть `Permission denied`/ping без ssh — НЕ паниковать.
Если через ~6 мин доступа нет → serial (bash `co:…/bin/bash`) и смотреть `/tmp/box-start.log`.

## 5. Дождаться возврата и проверить автозапуск
```sh
until ssh -o ConnectTimeout=5 -o BatchMode=yes $B 'echo OK' 2>/dev/null; do echo "жду..."; sleep 15; done
ssh $B 'echo "=== box-start.log ==="; cat /tmp/box-start.log; \
  echo "=== BOX_INIT_DONE:"; grep -c BOX_INIT_DONE /tmp/bcmrun.log; \
  echo "=== bcm.user pid:"; pidof bcm.user; \
  echo "=== хотплаг-поллер:"; grep hotplug /tmp/box-start.log; \
  echo "=== ретраи (0=инит прошёл с первого):"; cat /var/bcm/.boxstart_retries 2>/dev/null || echo 0'
```
Ожидаем: `BOX_INIT_DONE=1`, живой `bcm.user`, в логе `[DONE]` и `[hotplug] ... запущен`.
Если был флейк — увидишь в логе `[retry] попытка N/3` и коробка сама ребутнулась (жди повторно шаг 5).

## 6. Валидация фич
```sh
# 6a. SFPScan: авто-детект модулей и скорость (должен быть БЫСТРЫМ — без +45с)
ssh $B "echo 'SFPScan dump' > /tmp/bcm.fifo; sleep 4; grep -i 'SFPScan' /tmp/bcmrun.log | tail -60"
#   ждём: только реально воткнутые модули; 'SFP -> 10G/1G'; пустые порты пропущены; отработал за ~секунду

# 6b. Линки: 10G поднялись САМИ (без ручного force)
ssh $B "echo 'ps' > /tmp/bcm.fifo; sleep 2; grep -iE '  xe[0-9]+ ' /tmp/bcmrun.log | grep -i ' up ' | tail"

# 6c. LED (ГЛАЗАМИ на панели): воткнуть трансивер в cage 17 и 21 ->
#     диод ДОЛЖЕН совпасть с номером разъёма (раньше был -4). 
#     (опц. devmem-проверка статуса по физ.порту, BAR 0xc0000000:
#      phys P 1-36: 0xc0001600+4*P ; 37-72: 0xc0002600+4*(P-36) )

# 6d. Хот-плаг: воткнуть модуль В УЖЕ РАБОТАЮЩУЮ коробку, подождать ~25с ->
ssh $B "sleep 25; echo 'ps' > /tmp/bcm.fifo; sleep 2; grep -iE '  xe[0-9]+ ' /tmp/bcmrun.log | grep -i ' up ' | tail"
#   новый модуль должен подняться без ручных действий (поллер раз в 20с сам сделал SFPScan)
```

## 7. ОТКАТ (если что-то сломалось)
Быстрый безопасный откат на СТОК (netdevd), без разбора:
```sh
ssh $B 'touch /var/bcm/DISABLE; kill -9 $(pidof bcm.user) 2>/dev/null; sync; reboot -f'
#   DISABLE -> box-start пропустит наш свитч, коробка загрузится штатным netdevd (known-good).
```
Откат на ПРЕДЫДУЩИЙ наш бинарь:
```sh
ssh $B 'cd /var/bcm; kill -9 $(pidof bcm.user) 2>/dev/null; sleep 1; \
  cp -a bcm.user.bak-* bcm.user 2>/dev/null; cp -a rc.soc.bak-* rc.soc 2>/dev/null; \
  cp -a box-start.sh.bak-* box-start.sh 2>/dev/null; sync; reboot -f'
```

## 8. (Опц.) Проба стоковых дельт — ПО ОДНОЙ
Кандидаты: `scripts/config.bcm.stock-deltas` (джамбо, module_64ports, miim_intr_enable=1 и др.).
Добавлять ПО ОДНОЙ строке в `/var/bcm/config.bcm`, ребут, смотреть init (BOX_INIT_DONE) и линки.
Низкий риск первыми: `bcm_stat_jumbo=16348`, `buf.mqueue.pool_scale=0.5`.
Высокий риск (может ломать init/флейк): `miim_intr_enable=1`, `module_64ports=1` — только со свежим бэкапом.
Снять live-состояние для сверки инференса: искать `config show`/snapdb (см. memory config-db).

---
### Памятка по опасностям (из опыта)
- Ребут при замороженном pm: `reboot` НЕ проходит → только `kill -9 bcm.user; sync; reboot -f`.
- Никогда не `kill -CONT pm` при мёртвом netdevd — ребутит/вешает коробку.
- `cp` поверх запущенного bcm.user = «text file busy» (молча) — сперва `kill -9`.
- Самолечение сети ~3-5 мин после ребута — это норма.
