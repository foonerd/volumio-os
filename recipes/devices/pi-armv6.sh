#!/usr/bin/env bash
# shellcheck disable=SC2034

################################################################################
# Raspberry Pi ARMv6 Device Recipe (Legacy)
# 
# Target devices: Pi 1 (all models), Pi Zero, Pi Zero W, CM1
# Architecture: ARMv6 32-bit (Raspbian armhf for maximum compatibility)
################################################################################

DEVICE_SUPPORT_TYPE="S"
DEVICE_STATUS="T"

################################################################################
# BASE SYSTEM CONFIGURATION
################################################################################

BASE="Raspbian"
ARCH="armhf"
BUILD="arm"

DEBUG_IMAGE="no"

################################################################################
# DEVICE IDENTIFICATION
################################################################################

DEVICENAME="Raspberry Pi"
DEVICEFAMILY="raspberry"
DEVICEREPO="https://github.com/volumio/platform-${DEVICEFAMILY}.git"

################################################################################
# IMPORT RASPBERRY PI FAMILY CONFIGURATION
################################################################################

source "${SRC}"/recipes/devices/families/raspberry.sh

################################################################################
# VOLUMIO FEATURE FLAGS
################################################################################

VOLVARIANT=no
MYVOLUMIO=no
VOLINITUPDATER=yes
KIOSKMODE=no

################################################################################
# PARTITION LAYOUT
################################################################################

BOOT_START=1
BOOT_END=385
IMAGE_END=4673
BOOT_TYPE=msdos
BOOT_TYPE_SSD=gpt
BOOT_USE_UUID=yes
INIT_TYPE="initv3"
INIT_UUID_TYPE="pi"

################################################################################
# PLYMOUTH SPLASH SCREEN CONFIGURATION
################################################################################

PLYMOUTH_THEME="volumio-adaptive"
INIT_PLYMOUTH_DISABLE="no"
UPDATE_PLYMOUTH_SERVICES_FOR_KMS_DRM="yes"

################################################################################
# INITRAMFS MODULES
################################################################################
# Modules loaded in initramfs for early boot hardware support
################################################################################

################################################################################
# CORE FILESYSTEM AND STORAGE
################################################################################
MODULES=(
	"fuse"
	"nls_iso8859_1"
	"nvme"
	"nvme_core"
	"overlay"
	"squashfs"
	"uas"
)

################################################################################
# ALSA SOUND SUBSYSTEM
################################################################################
MODULES+=(
	"snd"
	"snd-timer"
	"snd-pcm"
	"snd-pcm-dmaengine"
	"snd-compress"
	"snd-soc-core"
)

################################################################################
# AUDIO CODECS
################################################################################
MODULES+=(
	"snd-soc-hdmi-codec"
	"snd-bcm2835"
	"snd-soc-bcm2835-i2s"
)

################################################################################
# I2C AND SPI CONTROLLERS
################################################################################
MODULES+=(
	"i2c-bcm2835"
	"i2c-brcmstb"
	"spi-bcm2835"
)

################################################################################
# PI 5 RP1 I/O CONTROLLER
################################################################################
MODULES+=(
	"rp1-fw"
	"rp1-mailbox"
	"rp1-pio"
)

################################################################################
# DISPLAY INFRASTRUCTURE
################################################################################
MODULES+=(
	"backlight"
	"drm_panel_orientation_quirks"
)

################################################################################
# DRM/KMS FOUNDATION
################################################################################
MODULES+=(
	"drm"
	"drm_kms_helper"
	"drm_display_helper"
	"drm_dma_helper"
	"cec"
	"vc4"
)

################################################################################
# DSI DISPLAY PANELS
################################################################################
MODULES+=(
	"panel-raspberrypi-touchscreen"
	"panel-ilitek-ili9881c"
	"panel-waveshare-dsi"
	"panel-waveshare-dsi-v2"
)

################################################################################
# SPI/FBTFT DISPLAYS
################################################################################
MODULES+=(
	"fbtft"
	"fb_ili9340"
	"fb_ili9341"
	"fb_ili9488"
	"fb_st7735r"
	"fb_st7789v"
	"fb_hx8357d"
)

################################################################################
# TOUCH CONTROLLER DRIVERS
################################################################################
MODULES+=(
	"goodix"
	"ads7846"
)

PACKAGES=()

################################################################################
# RASPBERRY PI KERNEL CONFIGURATION
################################################################################

declare -A PI_KERNELS=(
	[6.6.62]="9a9bda382acec723c901e5ae7c7f415d9afbf635|master|1816"
	[6.12.27]="f54e67fef6e726725d3a8f56d232194497bd247c|master|1876"
	[6.12.34]="4f435f9e89a133baab3e2c9624b460af335bbe91|master|1889"
	[6.12.47]="6d1da66a7b1358c9cd324286239f37203b7ce25c|master|1904"
	[6.12.50]="a22bb2f110bc8953523714ac58251f47ae4e2d2b|master|1909"
)

KERNEL_VERSION="6.12.47"

################################################################################
# RPI-UPDATE FLAGS
################################################################################
# ARMv6 hardware can only run kernel.img (ARMv6 variant)
# PROBLEM: WANT_32BIT=1 installs ALL 32-bit kernels (kernel.img, kernel7.img, kernel7l.img)
# WORKAROUND: Install all, then cleanup unwanted variants
################################################################################

RPI_UPDATE_FLAGS=(
	"WANT_32BIT=1"
	"WANT_64BIT=0"
	"WANT_PI2=0"
	"WANT_PI4=0"
	"WANT_PI5=0"
	"WANT_16K=0"
	"WANT_64BIT_RT=0"
)

################################################################################
# DEVICE CUSTOMIZATION FUNCTIONS
################################################################################

write_device_files() {
	# log "Running write_device_files" "ext"
	:
}

write_device_bootloader() {
	:
}

################################################################################
# DEVICE_IMAGE_TWEAKS
################################################################################

device_image_tweaks() {
	device_image_tweaks_common
	
	################################################################################
	# POST-INSTALLATION CLEANUP - DEFENSE IN DEPTH
	################################################################################
	# RATIONALE: Even with the rpi-update patch, we implement aggressive
	# cleanup as a safety net. This ensures that if:
	#   1. The patch fails to apply
	#   2. Future rpi-update versions change the filtering logic
	#   3. Modules are installed through other mechanisms
	# ...we still end up with ONLY the kernel variants we want.
	################################################################################
	
	log "Post-installation cleanup: Removing incompatible kernel variants" "info"
	
	################################################################################
	# Remove unwanted kernel module directories
	# Use pattern matching on directory names to catch all variants
	################################################################################
	
	for kdir in /lib/modules/*; do
		[[ ! -d "$kdir" ]] && continue
		kbase=$(basename "$kdir")
		
		################################################################################
		# Keep ONLY base ARMv6 kernel modules (no suffix or + suffix only)
		# Remove: -v7+, -v7l+, -v8+, -2712, -16k+, -rt+, +rpt-rpi-*
		################################################################################
		
		if [[ "$kbase" == *"-v7+"* ]] || [[ "$kbase" == *"-v7l+"* ]] || \
		   [[ "$kbase" == *"-v8+"* ]] || [[ "$kbase" == *"-2712"* ]] || \
		   [[ "$kbase" == *"-16k+"* ]] || [[ "$kbase" == *"-rt+"* ]] || \
		   [[ "$kbase" == *"+rpt-rpi-"* ]]; then
			log "Removing incompatible kernel for ARMv6: $kbase" "info"
			rm -rf "$kdir"
			continue
		fi
	done
	
	################################################################################
	# Remove incompatible kernel images from /boot
	################################################################################
	
	for kimg in /boot/kernel*.img; do
		[[ ! -f "$kimg" ]] && continue
		kname=$(basename "$kimg")
		
		################################################################################
		# Keep ONLY kernel.img (ARMv6)
		# Remove: kernel7.img, kernel7l.img, kernel8.img, kernel_2712.img
		################################################################################
		
		if [[ "$kname" != "kernel.img" ]]; then
			log "Removing incompatible kernel image for ARMv6: $kname" "info"
			rm -f "$kimg"
		fi
	done
	
	log "Raspi Kernel and Modules cleanup completed" "okay"
	
	################################################################################
	# Call common cleanup for depmod and config generation
	################################################################################
	cleanup_pi_kernels_common
	
	################################################################################
	# DEVICE-SPECIFIC BOOT CONFIGURATION
	################################################################################
	
	log "Writing config.txt file" "info"
	cat <<-EOF >/boot/config.txt
		### DO NOT EDIT THIS FILE ###
		### APPLY CUSTOM PARAMETERS TO userconfig.txt ###
		initramfs volumio.initrd
		gpu_mem=128
		gpu_mem_256=32
		gpu_mem_512=32
		gpu_mem_1024=128
		max_usb_current=1
		include volumioconfig.txt
		include userconfig.txt
	EOF

	log "Writing volumioconfig.txt file" "info"
	cat <<-EOF >/boot/volumioconfig.txt
		### DO NOT EDIT THIS FILE ###
		### APPLY CUSTOM PARAMETERS TO userconfig.txt ###
		dtoverlay=vc4-kms-v3d
		# dtparam=uart0_console # Disabled by default
		arm_64bit=0
		dtparam=audio=on
		audio_pwm_mode=2
		dtparam=i2c_arm=on
		disable_splash=1
		hdmi_force_hotplug=1
		force_eeprom_read=0
		display_auto_detect=1
	EOF

	generate_pi_cmdline
}

################################################################################
# GENERATE_PI_CMDLINE
################################################################################

generate_pi_cmdline() {
	log "Writing cmdline.txt file" "info"
	
	kernel_params=()
	
	if [[ $DEBUG_IMAGE == yes ]]; then
		SHOW_SPLASH="nosplash"
		KERNEL_QUIET=""
		KERNEL_LOGLEVEL="loglevel=8 debug break= use_kmsg=yes"
	else
		SHOW_SPLASH="splash"
		KERNEL_QUIET="quiet"
		KERNEL_LOGLEVEL="loglevel=0 nodebug use_kmsg=no"
	fi

	kernel_params+=("${SHOW_SPLASH}")
	kernel_params+=("plymouth.ignore-serial-consoles")
	kernel_params+=("dwc_otg.fiq_enable=1" "dwc_otg.fiq_fsm_enable=1" "dwc_otg.fiq_fsm_mask=0xF" "dwc_otg.nak_holdoff=1")
	kernel_params+=("${KERNEL_QUIET}")
	kernel_params+=("console=serial0,115200" "console=tty1")
	kernel_params+=("imgpart=UUID=${UUID_IMG} imgfile=/volumio_current.sqsh bootpart=UUID=${UUID_BOOT} datapart=UUID=${UUID_DATA} uuidconfig=cmdline.txt")
	kernel_params+=("pcie_aspm=off" "pci=pcie_bus_safe")
	kernel_params+=("rootwait" "bootdelay=7")
	kernel_params+=("logo.nologo")
	kernel_params+=("vt.global_cursor_default=0")
	kernel_params+=("net.ifnames=0")
	kernel_params+=("snd-bcm2835.enable_compat_alsa=${compat_alsa}" "snd_bcm2835.enable_hdmi=1" "snd_bcm2835.enable_headphones=1")

	if [[ $DEBUG_IMAGE == yes ]]; then
		log "Creating debug image" "dbg"
		log "Adding Serial Debug parameters" "dbg"
		echo "include debug.txt" >>/boot/config.txt
		cat <<-EOF >/boot/debug.txt
			enable_uart=1
			dtoverlay=pi3-miniuart-bt
		EOF
		log "Enabling SSH" "dbg"
		touch /boot/ssh
		if [[ -f /boot/bootcode.bin ]]; then
			log "Enable serial boot debug" "dbg"
			sed -i -e "s/BOOT_UART=0/BOOT_UART=1/" /boot/bootcode.bin
		fi
	fi

	kernel_params+=("${KERNEL_LOGLEVEL}")
	log "Setting ${#kernel_params[@]} Kernel params:" "${kernel_params[*]}" "info"
	cat <<-EOF >/boot/cmdline.txt
		${kernel_params[@]}
	EOF
}

################################################################################
# CHROOT TWEAKS
################################################################################

device_chroot_tweaks() {
	log "Running device_chroot_tweaks" "ext"
	
	################################################################################
	# CUSTOM FIRMWARE ARRAY
	################################################################################
	# Define firmware packages to install during chroot
	# These are kernel modules and firmware for audio HATs and WiFi chips
	################################################################################
	
	declare -A CustomFirmware=(
		[AlloPiano]="https://github.com/allocom/piano-firmware/archive/master.tar.gz"
		[TauDAC]="https://github.com/taudac/modules/archive/rpi-volumio-${KERNEL_VERSION}-taudac-modules.tar.gz"
		[Bassowl]="https://raw.githubusercontent.com/Darmur/bassowl-hat/master/driver/archives/modules-rpi-${KERNEL_VERSION}-bassowl.tar.gz"
		[wm8960]="https://raw.githubusercontent.com/hftsai256/wm8960-rpi-modules/main/wm8960-modules-rpi-${KERNEL_VERSION}.tar.gz"
		[brcmfmac43430b0]="https://raw.githubusercontent.com/volumio/volumio3-os-static-assets/master/firmwares/brcmfmac43430b0/brcmfmac43430b0.tar.gz"
		[vfirmware]="https://raw.githubusercontent.com/volumio/volumio3-os-static-assets/master/firmwares/bookworm/firmware-volumio.tar.gz"
		[PiCustom]="https://raw.githubusercontent.com/Darmur/volumio-rpi-custom/main/output/modules-rpi-${KERNEL_VERSION}-custom.tar.gz"
	)
	
	################################################################################
	# Call family common chroot tweaks
	# This installs packages, configures system, and installs CustomFirmware
	################################################################################
	device_chroot_tweaks_common
}

device_chroot_tweaks_pre() {
	log "Running device_chroot_tweaks_pre" "ext"
	:
}

device_chroot_tweaks_post() {
	:
}

device_image_tweaks_post() {
	log "Running device_image_tweaks_post" "ext"
	device_image_tweaks_post_common
}
