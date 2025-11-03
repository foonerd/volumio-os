#!/usr/bin/env bash
# shellcheck disable=SC2034

################################################################################
# Raspberry Pi Compute Module 4 Device Recipe
# 
# Target devices: CM4, CM4 Lite, custom CM4 carrier boards
# Architecture: Dual kernel (32-bit + 64-bit) with 32-bit userspace
# 
# CM4-specific configuration:
# - Dual kernel setup for troubleshooting:
#   * kernel8.img (64-bit) - default for performance
#   * kernel7l.img (32-bit) - fallback for testing
# - Switch via arm_64bit=0/1 in config.txt
# - 32-bit userspace (BUILD=arm) for compatibility
# - No PiInstaller (CM4 uses eMMC or custom storage)
# - Kiosk mode enabled by default
################################################################################

DEVICE_SUPPORT_TYPE="O"
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

DEVICENAME="CM4"

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
KIOSKMODE=yes
KIOSKBROWSER=vivaldi

################################################################################
# PARTITION LAYOUT
################################################################################

BOOT_START=1
BOOT_END=257
IMAGE_END=3257
BOOT_TYPE=msdos
BOOT_USE_UUID=yes
INIT_TYPE="initv3"
INIT_UUID_TYPE="pi"

################################################################################
# PLYMOUTH SPLASH SCREEN CONFIGURATION
################################################################################

PLYMOUTH_THEME="volumio-adaptive"

log "VARIANT is ${VARIANT}." "info"

if [[ "${VARIANT}" == motivo ]]; then
	log "Building ${VARIANT}: Removing plymouth from init." "info"
	INIT_PLYMOUTH_DISABLE="yes"
else
	log "Using default plymouth initialization in init." "info"
	INIT_PLYMOUTH_DISABLE="no"
fi

if [[ "${VARIANT}" == motivo ]]; then
	log "Building ${VARIANT}: Replacing default plymouth systemd services" "info"
	UPDATE_PLYMOUTH_SERVICES_FOR_KMS_DRM="yes"
else
	log "Using packager default plymouth systemd services" "info"
	UPDATE_PLYMOUTH_SERVICES_FOR_KMS_DRM="no"
fi

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
	"spi-bcm2835"
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
	"panel-dsi-mt"
	"panel-waveshare-dsi"
	"panel-ilitek-ili9881c"
)

################################################################################
# SPI/FBTFT DISPLAYS
################################################################################
MODULES+=(
	"simplefb"
)

################################################################################
# TOUCH CONTROLLER DRIVERS
################################################################################
MODULES+=(
	"goodix"
	"ads7846"
)

PACKAGES=(
	"bluez"
	"bluez-firmware"
	"pi-bluetooth"
	"raspberrypi-sys-mods"
	"fbset"
)

################################################################################
# RASPBERRY PI KERNEL CONFIGURATION
################################################################################

declare -A PI_KERNELS=(
	[6.1.57]="12833d1bee03c4ac58dc4addf411944a189f1dfd|master|1688"
	[6.1.58]="7b859959a6642aff44acdfd957d6d66f6756021e|master|1690"
	[6.1.61]="d1ba55dafdbd33cfb938bca7ec325aafc1190596|master|1696"
	[6.1.64]="01145f0eb166cbc68dd2fe63740fac04d682133e|master|1702"
	[6.1.69]="ec8e8136d773de83e313aaf983e664079cce2815|master|1710"
	[6.1.70]="fc9319fda550a86dc6c23c12adda54a0f8163f22|master|1712"
	[6.1.77]="5fc4f643d2e9c5aa972828705a902d184527ae3f|master|1730"
	[6.6.30]="3b768c3f4d2b9a275fafdb53978f126d7ad72a1a|master|1763"
	[6.6.47]="a0d314ac077cda7cbacee1850e84a57af9919f94|master|1792"
	[6.6.51]="d5a7dbe77b71974b9abb133a4b5210a8070c9284|master|1796"
	[6.6.56]="a5efb544aeb14338b481c3bdc27f709e8ee3cf8c|master|1803"
	[6.6.62]="9a9bda382acec723c901e5ae7c7f415d9afbf635|master|1816"
	[6.12.27]="f54e67fef6e726725d3a8f56d232194497bd247c|master|1876"
	[6.12.34]="4f435f9e89a133baab3e2c9624b460af335bbe91|master|1889"
)

KERNEL_VERSION="6.12.34"

################################################################################
# RPI-UPDATE FLAGS
################################################################################
# CM4 installs BOTH 32-bit and 64-bit kernels for troubleshooting:
# - kernel7l.img (32-bit ARMv7+LPAE) - for testing/fallback
# - kernel8.img (64-bit) - default for performance
# Switch between them via arm_64bit=0/1 in config.txt
################################################################################

RPI_UPDATE_FLAGS=(
	"WANT_32BIT=0"
	"WANT_64BIT=1"
	"WANT_PI2=0"
	"WANT_PI4=1"
	"WANT_PI5=0"
	"WANT_16K=0"
	"WANT_64BIT_RT=0"
)

################################################################################
# DEVICE CUSTOMIZATION FUNCTIONS
################################################################################

write_device_files() {
	:
}

write_device_bootloader() {
	:
}

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
	#
	# DECISION: Remove unwanted variants by pattern matching rather than
	# relying solely on rpi-update flags. This is more robust.
	#
	# CM4-SPECIFIC: We keep BOTH 32-bit and 64-bit kernels for troubleshooting.
	# Default is 64-bit (arm_64bit=1), but users can switch to 32-bit for testing
	# to isolate kernel-specific issues from userspace issues.
	################################################################################
	
	log "Post-installation cleanup: Removing unwanted kernel variants" "info"
	
	# ----------------------------------------------------------------------------
	# STEP 1: Remove unwanted kernel module directories
	# ----------------------------------------------------------------------------
	# DECISION: Use pattern matching on directory names to catch all variants
	# of unwanted kernels, regardless of version number.
	#
	# CM4 KERNEL STRATEGY:
	# - KEEP: kernel7l.img (-v7l+ modules) for 32-bit testing
	# - KEEP: kernel8.img (-v8+ modules) for 64-bit default
	# - REMOVE: Everything else
	# ----------------------------------------------------------------------------
	for kdir in /lib/modules/*; do
		[[ ! -d "$kdir" ]] && continue
		kbase=$(basename "$kdir")
		
		# -----------------------------------------------------------------------
		# Check if this is a keeper: -v7l+ or -v8+
		# -----------------------------------------------------------------------
		if [[ "$kbase" == *"-v7l+"* ]] || [[ "$kbase" == *"-v8+"* ]]; then
			# -------------------------------------------------------------------
			# Even for keeper variants, remove unwanted sub-variants
			# -------------------------------------------------------------------
			
			# Remove Pi 5 16KB page kernels (-v8-16k+ suffix)
			# WHY: CM4 is based on BCM2711, not BCM2712 (Pi 5)
			# SAFE: Standard v8+ kernel works fine
			if [[ "$kbase" == *"-16k+"* ]] || [[ "$kbase" == *"_16k+"* ]]; then
				log "Removing Pi5 16K kernel modules: $kbase" "info"
				rm -rf "$kdir"
				continue
			fi
			
			# Remove realtime kernels (-rt+ suffix)
			# WHY: Volumio does not require PREEMPT_RT for audio workloads
			# DECISION: Standard preemption is sufficient for our use case
			if [[ "$kbase" == *"-rt+"* ]] || [[ "$kbase" == *"_rt+"* ]]; then
				log "Removing RT kernel modules: $kbase" "info"
				rm -rf "$kdir"
				continue
			fi
			
			# Remove Raspberry Pi OS specific kernels (+rpt-rpi-* suffix)
			# WHY: These are Raspberry Pi OS specific variants not used by Volumio
			# EXAMPLE: 6.12.47-v8+rpt-rpi-2712 is RPi OS specific for Pi 5
			if [[ "$kbase" == *"+rpt-rpi-"* ]]; then
				log "Removing RPi OS kernel modules: $kbase" "info"
				rm -rf "$kdir"
				continue
			fi
			
			# If we reach here, this is a clean -v7l+ or -v8+ variant - keep it
			log "Keeping CM4 kernel modules: $kbase" "info"
		else
			# -------------------------------------------------------------------
			# Not a keeper variant - remove it
			# -------------------------------------------------------------------
			
			# Remove base ARMv6 kernel (no suffix or just + suffix)
			# WHY: CM4 is ARMv7/ARMv8, cannot use ARMv6 kernel
			# EXAMPLE: 6.12.47+ is for Pi 1/Zero
			if [[ "$kbase" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+?$ ]]; then
				log "Removing ARMv6 kernel modules: $kbase" "info"
				rm -rf "$kdir"
				continue
			fi
			
			# Remove Pi 2/3 kernels (-v7+ suffix)
			# WHY: CM4 needs -v7l+ (LPAE) variant, not plain -v7+
			# EXAMPLE: 6.12.47-v7+ is for Pi 2/3
			if [[ "$kbase" == *"-v7+"* ]] && [[ "$kbase" != *"-v7l+"* ]]; then
				log "Removing Pi2/3 kernel modules: $kbase" "info"
				rm -rf "$kdir"
				continue
			fi
			
			# Remove Pi 5 kernels (-2712 suffix)
			# WHY: CM4 is based on BCM2711 (Pi 4), not BCM2712 (Pi 5)
			# EXAMPLE: 6.12.47-2712 is Pi 5 specific
			if [[ "$kbase" == *"-2712"* ]] || [[ "$kbase" == *"_2712"* ]]; then
				log "Removing Pi5 BCM2712 kernel modules: $kbase" "info"
				rm -rf "$kdir"
				continue
			fi
			
			# Catch-all for any other unwanted variants
			log "Removing unwanted kernel modules: $kbase" "info"
			rm -rf "$kdir"
		fi
	done
	
	# ----------------------------------------------------------------------------
	# STEP 2: Remove unwanted kernel images from /boot
	# ----------------------------------------------------------------------------
	# DECISION: Remove kernel images we don't need to save boot partition space
	# and avoid confusion about which kernel will be used.
	#
	# CM4 keeps BOTH kernel7l.img and kernel8.img for troubleshooting
	# ----------------------------------------------------------------------------
	for kimg in /boot/kernel*.img; do
		[[ ! -f "$kimg" ]] && continue
		kname=$(basename "$kimg")
		
		# -----------------------------------------------------------------------
		# Keep kernel7l.img and kernel8.img, remove everything else
		# -----------------------------------------------------------------------
		if [[ "$kname" == "kernel7l.img" ]] || [[ "$kname" == "kernel8.img" ]]; then
			log "Keeping CM4 kernel image: $kname" "info"
		else
			log "Removing unwanted kernel image: $kname" "info"
			rm -f "$kimg"
		fi
	done
	
	# ----------------------------------------------------------------------------
	# STEP 3: Verification
	# ----------------------------------------------------------------------------
	# Log what we ended up with for troubleshooting purposes
	# ----------------------------------------------------------------------------
	log "Final kernel module directories:" "info"
	ls -1d /lib/modules/* 2>/dev/null | while read -r kdir; do
		log "  - $(basename "$kdir")" "info"
	done
	
	log "Final kernel images in /boot:" "info"
	ls -1 /boot/kernel*.img 2>/dev/null | while read -r kimg; do
		log "  - $(basename "$kimg")" "info"
	done
	
	log "Raspi Kernel and Modules cleanup completed" "okay"
	
	################################################################################
	# Call common cleanup for depmod and config generation
	################################################################################
	cleanup_pi_kernels_common
	
	################################################################################
	# CM4-SPECIFIC BOOT CONFIGURATION
	################################################################################
	
	log "Writing config.txt file" "info"
	cat <<-EOF >/boot/config.txt
		### DO NOT EDIT THIS FILE ###
		### APPLY CUSTOM PARAMETERS TO userconfig.txt ###
		initramfs volumio.initrd
		gpu_mem=128
		dtparam=ant2
		max_framebuffers=1
		disable_splash=1
		force_eeprom_read=0
		dtparam=audio=off
		start_x=1
		include volumioconfig.txt
		include userconfig.txt
	EOF

	log "Writing volumioconfig.txt file" "info"
	cat <<-EOF >/boot/volumioconfig.txt
		### DO NOT EDIT THIS FILE ###
		### APPLY CUSTOM PARAMETERS TO userconfig.txt ###
		display_auto_detect=1
		enable_uart=1
		arm_64bit=1
		dtparam=uart0=on
		dtparam=uart1=off
		dtoverlay=dwc2,dr_mode=host
		otg_mode=1
		dtoverlay=vc4-kms-v3d,cma-384,audio=off,noaudio=on
	EOF

	generate_cm4_cmdline
}

generate_cm4_cmdline() {
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
	kernel_params+=("snd-bcm2835.enable_compat_alsa=1")

	if [[ $DEBUG_IMAGE == yes ]]; then
		log "Creating debug image" "dbg"
		log "Adding Serial Debug parameters" "dbg"
		echo "include debug.txt" >>/boot/config.txt
		cat <<-EOF >/boot/debug.txt
			enable_uart=1
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
	# CM4-specific firmware for Motivo and custom hardware
	################################################################################
	
	declare -A CustomFirmware=(
		[vfirmware]="https://raw.githubusercontent.com/volumio/volumio3-os-static-assets/master/firmwares/bookworm/firmware-volumio.tar.gz"
		[PiCustom]="https://raw.githubusercontent.com/Darmur/volumio-rpi-custom/main/output/modules-rpi-${KERNEL_VERSION}-custom.tar.gz"
		[MotivoCustom]="https://github.com/volumio/motivo-drivers/raw/main/output/modules-rpi-${KERNEL_VERSION}-motivo.tar.gz"
		[RPiUserlandTools]="https://github.com/volumio/volumio3-os-static-assets/raw/master/tools/rpi-softfp-vc.tar.gz"
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
