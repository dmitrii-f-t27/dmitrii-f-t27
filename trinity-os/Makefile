# Trinity OS L0 — сборка киоск-образа.
# Всё тяжёлое (исходники, скачанное, артефакты) живёт в ./build — держите проект на SSD.
#
#   make buildroot   — скачать и распаковать Buildroot
#   make config      — применить trinity_kiosk_x86_64_defconfig
#   make             — полная сборка (1-3 часа при первом запуске)
#   make qemu        — запустить образ в QEMU (нужен qemu-system-x86_64 с KVM)
#   make flash DEV=/dev/sdX — записать образ на диск/флешку
#   make menuconfig  — тонкая настройка
#   make savedefconfig — сохранить изменения обратно в defconfig

BUILDROOT_VERSION ?= 2026.02.3
DEFCONFIG         ?= trinity_kiosk_x86_64_defconfig

TOP           := $(CURDIR)
BUILD_DIR     ?= $(TOP)/build
BUILDROOT_DIR := $(BUILD_DIR)/buildroot-$(BUILDROOT_VERSION)
OUTPUT_DIR    ?= $(BUILD_DIR)/output
DL_DIR        ?= $(BUILD_DIR)/dl
EXTERNAL      := $(TOP)/external

IMAGE := $(OUTPUT_DIR)/images/disk.img

BR_MAKE = $(MAKE) -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR) BR2_EXTERNAL=$(EXTERNAL) BR2_DL_DIR=$(DL_DIR)

.PHONY: all buildroot config build menuconfig savedefconfig qemu flash clean distclean

all: build

$(BUILDROOT_DIR)/Makefile:
	mkdir -p $(BUILD_DIR)
	curl -fL -o $(BUILD_DIR)/buildroot-$(BUILDROOT_VERSION).tar.gz \
		https://buildroot.org/downloads/buildroot-$(BUILDROOT_VERSION).tar.gz
	tar xzf $(BUILD_DIR)/buildroot-$(BUILDROOT_VERSION).tar.gz -C $(BUILD_DIR)

buildroot: $(BUILDROOT_DIR)/Makefile

$(OUTPUT_DIR)/.config: $(BUILDROOT_DIR)/Makefile $(EXTERNAL)/configs/$(DEFCONFIG)
	$(BR_MAKE) $(DEFCONFIG)

config: $(OUTPUT_DIR)/.config

build: config
	$(BR_MAKE)
	@echo
	@echo "=== Готово: $(IMAGE) ==="
	@echo "Проверка в QEMU:  make qemu"
	@echo "Запись на диск:   make flash DEV=/dev/sdX"

menuconfig: config
	$(BR_MAKE) menuconfig

savedefconfig: config
	$(BR_MAKE) savedefconfig BR2_DEFCONFIG=$(EXTERNAL)/configs/$(DEFCONFIG)

qemu:
	$(TOP)/scripts/qemu-run.sh $(IMAGE)

flash:
	$(TOP)/scripts/flash-to-disk.sh $(IMAGE) $(DEV)

clean:
	rm -rf $(OUTPUT_DIR)

distclean:
	rm -rf $(BUILD_DIR)
