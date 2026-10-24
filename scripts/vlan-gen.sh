#!/bin/sh
# === ЗАПУСКАЕТСЯ НА КОРОБКЕ (busybox sh/awk) или на хосте для проверки ===
# vlan.conf (раскладка VLAN в номерах клеток панели) -> diag-команды BCM для rcload / FIFO.
#
#   sh vlan-gen.sh [vlan.conf] > vlan.soc
#
# Формат vlan.conf (# — комментарий):
#   vlan <vid> [имя] [untagged=<клетки>] [tagged=<клетки>]
# Клетки: 1-48 и Q1-Q4, через запятую, диапазоны 1-12. Пример:
#   vlan 10 office untagged=1-12        tagged=48
#   vlan 20 cams   untagged=13-16,21-24 tagged=48,Q1
#   shutdown <клетки>   — выключить порты (например, лишние линки к тому же свитчу: STP у нас нет)
# Порт, не упомянутый как untagged ни в одном VLAN, остаётся access-портом VLAN 1.
# Tagged-порт (транк) остаётся и в VLAN 1 без тега (native VLAN 1).
#
# Выход идемпотентен: сначала всё возвращается в VLAN 1, потом раскладка применяется заново,
# так что тот же vlan.soc можно повторно загрузить на живом свитче.
#
# Карта клетка -> порт (24.10, как у стока): клетка N = xe(N-1) для 1-48, Q1-Q4 = xe48-51.
# Режим гидры (config.bcm с portmap_50, QSFP breakout 4x10G): головы Q1.1-Q4.4 = xe48-xe63
# (Qk.l = xe(48 + 4(k-1) + l-1)), голое Qk тогда не принимается.
# VLAN_GEN_BOOT=1 (так зовёт box-start): в режиме гидры ещё и 10G на головах — в режиме
# PCS-репитера они стартуют в 1G. При `sw vlan apply` не повторяем, чтобы не дёргать линки.

CONF=${1:-/var/bcm/vlan.conf}
[ -r "$CONF" ] || { echo "vlan-gen: нет файла $CONF" >&2; exit 1; }
BO=0; grep -q '^portmap_50=' "${BCMCFG:-/var/bcm/config.bcm}" 2>/dev/null && BO=1

awk -v bo="$BO" -v boot="${VLAN_GEN_BOOT:-0}" '
function cage2xe(c,   n) {
    if (bo && c ~ /^[Qq][1-4]\.[1-4]$/) return 48 + 4 * (substr(c, 2, 1) - 1) + substr(c, 4, 1) - 1
    if (!bo && c ~ /^[Qq][1-4]$/) return 47 + substr(c, 2)
    if (c !~ /^[0-9]+$/) return -1
    n = c + 0
    if (n >= 1 && n <= 48) return n - 1
    return -1
}
function xe2cage(x) {
    x += 0
    if (x <= 47) return x + 1
    if (bo) return "Q" int((x - 48) / 4) + 1 "." (x - 48) % 4 + 1
    return "Q" (x - 47)
}
# "1-12,48,Q1" -> через запятую номера xe; ошибка -> die
function expand(list,   parts, i, k, a, b, x, out) {
    out = ""
    k = split(list, parts, ",")
    for (i = 1; i <= k; i++) {
        if (parts[i] == "") continue
        if (parts[i] ~ /^[0-9]+-[0-9]+$/) {
            split(parts[i], ab, "-"); a = ab[1] + 0; b = ab[2] + 0
            if (a > b) die("перевёрнутый диапазон " parts[i])
            for (; a <= b; a++) { x = cage2xe(a); if (x < 0) die("нет клетки " a); out = out "," x }
        } else {
            x = cage2xe(parts[i]); if (x < 0) die("нет клетки " parts[i]); out = out "," x
        }
    }
    return substr(out, 2)
}
# список номеров xe -> pbmp "xe0-xe11,xe43"
function pbmp(list,   n, v, i, j, s, have) {
    delete have
    n = split(list, v, ",")
    for (i = 1; i <= n; i++) if (v[i] != "") have[v[i] + 0] = 1
    s = ""
    for (i = 0; i <= 63; i++) {
        if (!(i in have)) continue
        j = i; while ((j + 1) in have) j++
        s = s "," (i == j ? "xe" i : "xe" i "-xe" j)
        i = j
    }
    return substr(s, 2)
}
function die(msg) { printf "vlan-gen: %s:%d: %s\n", FILENAME, FNR, msg > "/dev/stderr"; err = 1; exit 1 }

/^[ \t]*(#|$)/ { next }
$1 == "shutdown" { if (NF != 2) die("ожидалось \"shutdown <клетки>\""); down = down "," expand($2); next }
$1 != "vlan" { die("ожидалось \"vlan <vid> ...\" или \"shutdown <клетки>\"") }
{
    vid = $2
    if (vid !~ /^[0-9]+$/ || vid + 0 < 2 || vid + 0 > 4094) die("vid должен быть 2..4094: " vid)
    if (vid in seen) die("VLAN " vid " описан дважды")
    seen[vid] = 1; order[++nv] = vid; untag[vid] = ""; tag[vid] = ""; name[vid] = ""
    for (f = 3; f <= NF; f++) {
        if ($f ~ /^untagged=/)    untag[vid] = expand(substr($f, 10))
        else if ($f ~ /^tagged=/) tag[vid]   = expand(substr($f, 8))
        else if ($f ~ /=/)        die("неизвестный параметр " $f)
        else                      name[vid]  = $f
    }
    n = split(untag[vid], u, ",")
    for (i = 1; i <= n; i++) {
        if (u[i] in owner) die("клетка " xe2cage(u[i]) " untagged и в VLAN " owner[u[i]] ", и в VLAN " vid)
        owner[u[i]] = vid
    }
    n = split(tag[vid], t, ",")
    for (i = 1; i <= n; i++)
        if (owner[t[i]] == vid) die("клетка " xe2cage(t[i]) " в VLAN " vid " и tagged, и untagged")
}
END {
    if (err) exit 1
    print "# сгенерировано vlan-gen.sh — не править руками, правьте vlan.conf"
    print "# 1) всё назад в VLAN 1 (идемпотентность)"
    print "vlan clear"
    print "vlan add 1 PortBitMap=xe UntagBitMap=xe"
    print "pvlan set xe 1"
    print "# 2) раскладка"
    acc = ""
    for (k = 1; k <= nv; k++) {
        vid = order[k]
        members = untag[vid] (untag[vid] != "" && tag[vid] != "" ? "," : "") tag[vid]
        if (members == "") { print "# VLAN " vid " " name[vid] ": пустой, пропущен"; continue }
        printf "# VLAN %s %s\n", vid, name[vid]
        if (untag[vid] != "")
            printf "vlan create %s PortBitMap=%s UntagBitMap=%s\n", vid, pbmp(members), pbmp(untag[vid])
        else
            printf "vlan create %s PortBitMap=%s\n", vid, pbmp(members)
        if (untag[vid] != "") acc = acc "," untag[vid]
    }
    if (acc != "") {
        print "# 3) access-порты уходят из VLAN 1 и получают свой PVID"
        printf "vlan remove 1 PortBitMap=%s\n", pbmp(substr(acc, 2))
        for (k = 1; k <= nv; k++)
            if (untag[order[k]] != "") printf "pvlan set %s %s\n", pbmp(untag[order[k]]), order[k]
    }
    print "# 4) выключенные порты (shutdown); остальные включены"
    print "port xe enable=true"
    if (down != "") printf "port %s enable=false\n", pbmp(substr(down, 2))
    if (bo && boot) { print "# 5) гидра: головы QSFP в 10G (PCS-репитер стартует в 1G)"; print "port xe48-xe63 an=off sp=10000" }
}' "$CONF"
