# Исходники прошивки / SDK

Из чего собирается наш control-plane (`bcm.user`) и откуда стоковый netdevd.

## Broadcom SDK (главный — из него строим bcm.user)

- **Вендорная версия (у нас):** `sdk-xgs-robo-6.3.2`
  - таргет `systems/linux/user/gto-2_6` (BCM56840/56846 Trident+, PPC e500v2).
  - лежит в `work/bcm/sdk-xgs-robo-6.3.2/` (gitignore — ~4.5 ГБ, не в репо).
  - происхождение: вендорное дерево Gigamon-сборки (`/var/jenkins/.../vendor/sdk-xgs-robo-6.3.2`);
    публично именно 6.3.2 не выложен.
  - наши правки к SDK: `patches/sfpscan.patch` (+ `work/SDK_PATCHES.txt` — правки сборки).
- **Публичное зеркало Broadcom SDK (OpenBCM):**
  <https://github.com/Broadcom-Network-Switching-Software/OpenBCM>
  - ветки/теги `sdk-6.5.x` — новее нашей 6.3.2, но структура и драйверы те же
    (`src/soc/phy/phy84740.c`, `src/appl/diag/*`); использовали как сверочный референс
    при разборе PHY84740/LED/ledproc (см. `reference/bcm84740-sfp-registers.md`).

## Стоковая прошивка (GigaVUE-OS, для реверса)

- GigaVUE-OS 5.4.04 (netdevd 37 МБ) — не из git, снято с SD-карты железки (`gigamon.bin`).
  Разбор: `gigamon.md`, `reference/stock-config-reconstruction.md`.
- GPL-исходники GigaVUE-OS Gigamon публикует по запросу на их open-source/GPL-compliance
  портале (не git-репозиторий); ядро 2.6.34-GIGAMONsmp-gvag, glibc 2.6 / gcc 4.2.2.

## Тулчейн

- ELDK 4.2 (`ppc_85xxDP-`, e500v2) — `work/eldk/`, образ `work/eldk_fsl.iso`.
