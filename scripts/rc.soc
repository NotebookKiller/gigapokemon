set rcerror=false
init soc
init misc
init mmu
init bcm
port xe enable=true stp=forward an=on
# --- Форс-10G на портах с 10G-линком (DAC/SFP к 10G-партнёрам) ---
# 10G DAC/SFP НЕ линкуются autoneg'ом -> нужен форс sp=10000 an=off. 1G-порты и autoneg-10G
# остаются на an=on выше. Список портов — под текущую коммутацию (панель3=xe3, панель23=xe18);
# панель48=xe43 линкуется 1G (дальний конец 1G) -> оставлен на an=on. Править при смене кабелей.
# (Generic-auto по типу модуля/сигналу — отдельная безопасная задача, НЕ слепой перебор скорости.)
port xe3,xe18 sp=10000 an=off
linkscan 250000
port xe linkscan=on
echo "BOX_INIT_DONE"
