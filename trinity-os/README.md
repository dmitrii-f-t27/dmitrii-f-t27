# Trinity OS — L0 (киоск-образ)

Первая ступень из `research/custom-os-for-spatial-apps-analysis.md`: собственный
загружаемый образ ОС, который стартует сразу в полноэкранное spatial-приложение.

Стек: **Linux 6.12 LTS → Mesa (Intel/AMD/virtio) → cog + WPE WebKit прямо на DRM/KMS**.
Ни X11, ни рабочего стола — только ядро, графический стек и веб-runtime.
Демо-приложение на борту: CesiumJS-глобус с живыми самолётами (OpenSky) и
землетрясениями (USGS) — «Worldview Lite». URL киоска меняется в одном файле.

## Требования к хосту сборки

- **Linux x86_64** (нативный или виртуалка; под macOS/Windows — не собирается).
- SSD с **ext4** (exFAT/NTFS не подойдут — сборке нужны симлинки и права).
  Свободное место: **~40 ГБ**, время первой сборки: 1–3 часа (WPE WebKit — самое долгое).
- Пакеты (Ubuntu/Debian):
  `sudo apt install build-essential libncurses-dev unzip bc rsync file wget cpio python3 libssl-dev libelf-dev qemu-system-x86 ovmf`

## Быстрый старт (на SSD)

```bash
# SSD смонтирован, например, в /mnt/ssd
sudo mkdir -p /mnt/ssd/trinity && sudo chown $USER /mnt/ssd/trinity
cd /mnt/ssd/trinity
git clone <этот репозиторий> repo && cd repo/trinity-os

make            # скачает Buildroot 2026.02.3, применит конфиг, соберёт образ
make qemu       # проверить в QEMU (virtio-gpu, EFI/OVMF)
make flash DEV=/dev/sdX   # записать на флешку/диск для загрузки на mini-PC
```

Артефакт сборки: `build/output/images/disk.img` — GPT-образ с EFI-разделом
(GRUB2 + ядро) и ext4-rootfs. Грузится на любом x86_64 с UEFI и GPU Intel/AMD.

## Что внутри

```
trinity-os/
├── Makefile                      # обёртка: скачать buildroot, собрать, qemu, flash
├── external/                     # BR2_EXTERNAL-дерево (наша «дистрибуция»)
│   ├── configs/trinity_kiosk_x86_64_defconfig
│   └── board/trinity/
│       ├── linux.config          # базовый конфиг ядра (от buildroot board/pc)
│       ├── linux-extra.fragment  # + amdgpu, igc, HID
│       ├── busybox.fragment      # + httpd для локального приложения
│       ├── grub-efi.cfg, genimage-efi.cfg, post-*.sh   # загрузка и сборка образа
│       └── rootfs-overlay/
│           ├── etc/init.d/S90apphttpd   # httpd 127.0.0.1:8080 → /opt/trinity/app
│           ├── etc/init.d/S99kiosk      # cog -P drm $KIOSK_URL, автоперезапуск
│           └── opt/trinity/
│               ├── etc/kiosk.conf       # KIOSK_URL — единственная настройка
│               └── app/index.html       # Worldview Lite (Cesium + OpenSky + USGS)
└── scripts/                      # qemu-run.sh, flash-to-disk.sh
```

## Эксплуатация

- **Сменить приложение киоска**: отредактировать `KIOSK_URL` в
  `/opt/trinity/etc/kiosk.conf` на устройстве (или в overlay и пересобрать).
  Когда развернём God's Eye View — указываем его URL, больше ничего не нужно.
- **Отладка**: Ctrl+Alt+F2 — getty на tty2; ssh — dropbear (задать пароль root
  при первом входе); лог киоска — `/var/log/kiosk.log`.
- **Сеть**: DHCP на eth0 из коробки; время — chrony (важно для TLS).

## Известные ограничения L0

- Обновления — только перезаписью образа (A/B OTA — это уже L1, RAUC).
- WPE даёт WebGL2 — CesiumJS хватает; WebGPU появится на этапе Chromium/L1.
- Wi-Fi требует донастройки (wpa_supplicant) — базово рассчитываем на Ethernet.
- Демо-приложение тянет CesiumJS с CDN — киоску нужен интернет.
  Следующий шаг — вендорить Cesium в образ и поднять data-fusion daemon (см. Phase 0, шаг 3).
