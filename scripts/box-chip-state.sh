#!/bin/sh
# === ЗАПУСКАТЬ НА КОРОБКЕ (root, ПОСЛЕ НОРМАЛЬНОЙ загрузки — не под init=/bin/bash) ===
# БЕЗОПАСНЫЙ дамп состояния чипа: через ШТАТНЫЙ action netdevd (не gdb!).
# netdevd сам, в своём контексте, прогоняет фикс. список BCM diag-команд и пишет
# вывод в /tmp/bcm.log. Ребута НЕ вызывает.
#
# Чип виден так:  cat /proc/linux-kernel-bde   (0 (swi) PCI 0x14e4:0xb846 = BCM56846)
# Процессы:       ps -ef | grep -E 'netdevd|mgmtd|pm'

export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/opt/tms/bin

echo "=== чип на PCI ==="
cat /proc/linux-kernel-bde

echo "=== запуск штатного dump netdevd -> /tmp/bcm.log ==="
mdreq action /gv/internal/actions/dump/netdevd mode string full > /dev/null 2>&1

echo "=== /tmp/bcm.log (первые 200 строк; всё — в файле) ==="
head -200 /tmp/bcm.log
echo "... полный дамп: /tmp/bcm.log ($(wc -l < /tmp/bcm.log) строк)"
