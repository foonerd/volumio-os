#!/usr/bin/env bash
# shellcheck disable=SC2034

################################################################################
# Raspberry Pi Device Family Configuration
# 
# This file contains common code shared across all Raspberry Pi device recipes:
# - pi.sh (ARMv7 - Pi 2+)
# - pi-armv6.sh (ARMv6 - Pi 1/Zero/Zero W)
# - cm4.sh (Compute Module 4)
# - pi-kiosk.sh (Kiosk variant)
#
# Device recipes should source this file and override specific functions or
# variables as needed for device-specific behavior.
################################################################################

################################################################################
# KERNEL REPOSITORY CONFIGURATION
################################################################################

# Official Raspberry Pi firmware repository
# Contains kernel images, modules, device trees, and bootloader files
RpiRepo="https://github.com/raspberrypi/rpi-firmware"

# rpi-update tool repository and branch
# Used to fetch and install specific kernel versions from rpi-firmware
RpiUpdateRepo="raspberrypi/rpi-update"

# We ended with 10 versions of 6.12.34 kernels from master branch.
# Using older branch to avoid boot failures
# Can be overridden to specific commit if needed for stability
RpiUpdateBranch="master"
# RpiUpdateBranch="1dd909e2c8c2bae7adb3eff3aed73c3a6062e8c8"

################################################################################
# COMMON DEVICE_IMAGE_TWEAKS FUNCTION
################################################################################
# This function handles configuration that happens OUTSIDE the chroot
# Device recipes can call this function and add device-specific tweaks after
################################################################################

device_image_tweaks_common() {
	
	################################################################################
	# HOSTAPD CONFIGURATION
	################################################################################
	# Configure WiFi access point settings for Volumio hotspot mode
	# Used when device acts as WiFi AP for initial setup or when no network available
	################################################################################
	
	log "Fixing hostapd.conf" "info"
	cat <<-EOF >"${ROOTFSMNT}/etc/hostapd/hostapd.conf"
		interface=wlan0
		driver=nl80211
		channel=4
		hw_mode=g
		wmm_enabled=0
		macaddr_acl=0
		ignore_broadcast_ssid=0
		# Auth
		auth_algs=1
		wpa=2
		wpa_key_mgmt=WPA-PSK
		rsn_pairwise=CCMP
		# Volumio specific
		ssid=Volumio
		wpa_passphrase=volumio2
	EOF

	################################################################################
	# RASPBERRY PI APT REPOSITORY
	################################################################################
	# Add official Raspberry Pi package repository
	# Provides Pi-specific packages: firmware, sys-mods, bluetooth, etc.
	# Uses ${SUITE} variable which is bookworm or trixie
	################################################################################
	
	log "Adding archive.raspberrypi debian repo" "info"
	cat <<-EOF >"${ROOTFSMNT}/etc/apt/sources.list.d/raspi.list"
		deb http://archive.raspberrypi.com/debian/ ${SUITE} main
		# Uncomment line below then 'apt-get update' to enable 'apt-get source'
		#deb-src http://archive.raspberrypi.com/debian/ ${SUITE} main
		# https://github.com/volumio/volumio-os/issues/45 - mesa libs unmet dependencies
		deb http://archive.raspberrypi.com/debian/ ${SUITE} untested
	EOF

	################################################################################
	# BLOCK RASPBERRY PI KERNEL PACKAGES
	################################################################################
	# raspberrypi-{kernel,bootloader} packages update kernel & firmware files
	# and break Volumio. Installation may be triggered by manual or plugin installs
	# explicitly or through dependencies like chromium, sense-hat, picamera, etc.
	# Using Pin-Priority < 0 prevents installation entirely
	# libraspberrypi0 also blocked as it can trigger kernel updates
	################################################################################
	
	log "Blocking raspberrypi-bootloader and raspberrypi-kernel" "info"
	cat <<-EOF >"${ROOTFSMNT}/etc/apt/preferences.d/raspberrypi-kernel"
		Package: raspberrypi-bootloader
		Pin: release *
		Pin-Priority: -1

		Package: raspberrypi-kernel
		Pin: release *
		Pin-Priority: -1

		Package: libraspberrypi0
		Pin: release *
		Pin-Priority: -1
	EOF

	################################################################################
	# RPI-UPDATE TOOL INSTALLATION
	################################################################################
	# Fetch rpi-update script used for kernel installation
	# This tool downloads specific kernel versions from rpi-firmware repo
	################################################################################
	
	log "Fetching rpi-update" "info"
	curl -L --output "${ROOTFSMNT}/usr/bin/rpi-update" \
		"https://raw.githubusercontent.com/${RpiUpdateRepo}/${RpiUpdateBranch}/rpi-update"
	chmod +x "${ROOTFSMNT}/usr/bin/rpi-update"

	################################################################################
	# RPI-UPDATE BUG FIX
	################################################################################
	# PROBLEM: rpi-update has a bug in its module filtering logic.
	# The script uses: VERSION=$(echo $BASEDIR | cut -sd "-" -f2)
	# This extracts ONLY field 2 when splitting by "-":
	#   6.12.47-v8+      -> VERSION="v8+"     (correct)
	#   6.12.47-v8-16k+  -> VERSION="v8"      (WRONG! should be "v8-16k")
	#   6.12.47-v8-rt+   -> VERSION="v8"      (WRONG! should be "v8-rt")
	#
	# RESULT: WANT_16K=0 and WANT_64BIT_RT=0 flags are ignored because the
	# filter never sees "v8-16k+" or "v8-rt+", only "v8".
	#
	# DECISION: Patch rpi-update before execution to fix the extraction logic.
	# This ensures filtering works correctly at the source, reducing unnecessary
	# downloads and filesystem operations.
	################################################################################
	
	log "Patching rpi-update to fix module filtering bug" "info"
	sed -i 's/VERSION=$(echo $BASEDIR | cut -sd "-" -f2)/VERSION=$(echo $BASEDIR | cut -sd "+" -f1 | cut -sd "-" -f2-)/' "${ROOTFSMNT}/usr/bin/rpi-update"
	
	################################################################################
	# NEW LOGIC: Extract everything between first "-" and the "+"
	#   6.12.47-v8+      -> VERSION="v8"
	#   6.12.47-v8-16k+  -> VERSION="v8-16k"
	#   6.12.47-v8-rt+   -> VERSION="v8-rt"
	# Now the filtering logic will correctly identify and skip unwanted variants.
	################################################################################

	################################################################################
	# BLEEDING EDGE KERNEL DETECTION (OPTIONAL)
	################################################################################
	# For testing latest kernels, check what is newest available on master branch
	# Things *might* break, so you are warned!
	# Device recipe sets RPI_USE_LATEST_KERNEL=yes to enable
	################################################################################
	
	if [[ ${RPI_USE_LATEST_KERNEL:-no} == yes ]]; then
		branch=master
		log "Using bleeding edge Rpi kernel" "info" "$branch"
		RpiRepoApi=${RpiRepo/github.com/api.github.com\/repos}
		RpiRepoRaw=${RpiRepo/github.com/raw.githubusercontent.com}
		log "Fetching latest kernel details from ${RpiRepo}" "info"
		RpiGitSHA=$(curl --silent "${RpiRepoApi}/branches/${branch}")
		readarray -t RpiCommitDetails <<<"$(jq -r '.commit.sha, .commit.commit.message' <<<"${RpiGitSHA}")"
		log "Rpi latest kernel -- ${RpiCommitDetails[*]}" "info"
		# Parse required info from uname_string
		uname_string=$(curl --silent "${RpiRepoRaw}/${RpiCommitDetails[0]}/uname_string")
		RpiKerVer=$(awk '{print $3}' <<<"${uname_string}")
		KERNEL_VERSION=${RpiKerVer/+/}
		RpiKerRev=$(awk '{print $1}' <<<"${uname_string##*#}")
		PI_KERNELS[${KERNEL_VERSION}]+="${RpiCommitDetails[0]}|${branch}|${RpiKerRev}"
		# Make life easier
		log "Using rpi-update SHA:${RpiCommitDetails[0]} Rev:${RpiKerRev}" "${KERNEL_VERSION}" "dbg"
		log "[${KERNEL_VERSION}]=\"${RpiCommitDetails[0]}|${branch}|${RpiKerRev}\"" "dbg"
	fi

	################################################################################
	# KERNEL INSTALLATION
	################################################################################
	# Install kernel using rpi-update with device-specific configuration
	################################################################################
	
	install_pi_kernel
	
	################################################################################
	# POST-INSTALLATION CLEANUP
	################################################################################
	# Device-specific cleanup handled by device recipe
	# Family provides common cleanup function that device can call
	################################################################################
}

################################################################################
# KERNEL INSTALLATION FUNCTION
################################################################################
# Uses rpi-update to fetch and install specific kernel version
# Device recipe must define:
# - PI_KERNELS associative array with version mappings
# - KERNEL_VERSION to select which version to install
# - RPI_UPDATE_FLAGS array with WANT_* flags for kernel variants
################################################################################

install_pi_kernel() {
	################################################################################
	# Parse kernel information from PI_KERNELS array
	# Format: [VERSION]="COMMIT|BRANCH|REV"
	################################################################################
	
	IFS=\| read -r KERNEL_COMMIT KERNEL_BRANCH KERNEL_REV <<<"${PI_KERNELS[$KERNEL_VERSION]}"

	log "Adding kernel ${KERNEL_VERSION} using rpi-update" "info"
	log "Fetching SHA: ${KERNEL_COMMIT} from branch: ${KERNEL_BRANCH}" "info"
	
	################################################################################
	# RPI-UPDATE ARGUMENTS
	################################################################################
	# UPDATE_SELF=0           - Don't update rpi-update itself
	# ROOT_PATH               - Target root filesystem path
	# BOOT_PATH               - Target boot partition path
	# SKIP_WARNING=1          - Skip interactive warnings
	# SKIP_BACKUP=1           - Don't backup old kernel (we're building fresh)
	# SKIP_CHECK_PARTITION=1  - Don't verify partition setup (we're in chroot)
	#
	# WANT_* flags control which kernel variants to install:
	# - WANT_32BIT: ARMv6/ARMv7 32-bit kernels (kernel.img, kernel7.img, kernel7l.img)
	# - WANT_64BIT: ARMv8 64-bit kernels (kernel8.img, kernel_2712.img)
	# - WANT_PI2: Include Pi 2/3 optimized kernel7.img
	# - WANT_PI4: Include Pi 4/400/CM4 optimized kernel7l.img
	# - WANT_PI5: Include Pi 5 optimized kernel_2712.img
	# - WANT_16K: Include 16K page size kernels (*-16k+) for Pi 5
	# - WANT_64BIT_RT: Include realtime kernels (*-rt+)
	#
	# Device recipes define RPI_UPDATE_FLAGS array with appropriate values
	################################################################################
	
	RpiUpdate_args=(
		"UPDATE_SELF=0"
		"ROOT_PATH=${ROOTFSMNT}"
		"BOOT_PATH=${ROOTFSMNT}/boot"
		"SKIP_WARNING=1"
		"SKIP_BACKUP=1"
		"SKIP_CHECK_PARTITION=1"
	)
	
	# Add device-specific WANT flags from device recipe
	for flag in "${RPI_UPDATE_FLAGS[@]}"; do
		RpiUpdate_args+=("${flag}")
	done
	
	################################################################################
	# Execute rpi-update with configured parameters
	################################################################################
	
	env "${RpiUpdate_args[@]}" "${ROOTFSMNT}"/usr/bin/rpi-update "${KERNEL_COMMIT}"
}

################################################################################
# COMMON KERNEL CLEANUP FUNCTION
################################################################################
# Remove unwanted kernel module directories and finalize kernel installation
# This is called by device recipes after install_pi_kernel
################################################################################

cleanup_pi_kernels_common() {
	################################################################################
	# FINALIZE KERNEL INSTALLATIONS
	################################################################################
	# Run depmod on all installed kernels to generate module dependencies
	# Create config files needed for initramfs generation
	################################################################################
	
	log "Finalise all kernels with depmod and other tricks" "info"
	
	################################################################################
	# Kernel variant reference (for documentation):
	# https://www.raspberrypi.com/documentation/computers/linux_kernel.html
	#
	# +       --> Pi 1, Zero, Zero W, CM1 (ARMv6)
	# -v7+    --> Pi 2, 3, 3+, Zero 2 W, CM3, CM3+ (ARMv7)
	# -v7l+   --> Pi 4, 400, CM4 (ARMv7 with LPAE)
	# -v8+    --> Pi 3, 3+, 4, 400, Zero 2 W, CM3, CM3+, CM4 (ARMv8 64-bit)
	# -2712   --> Pi 5 (BCM2712 SoC)
	################################################################################

	# Reconfirm our final kernel lists - we may have deleted some!
	#shellcheck disable=SC2012
	mapfile -t kver < <(ls -t /lib/modules | sort)
	for ver in "${kver[@]}"; do
		log "Running depmod on" "${ver}"
		depmod "${ver}"
		
		################################################################################
		# Create minimal kernel config for initramfs-tools
		# initramfs-tools checks for compression support in kernel config
		# Our kernels support both ZSTD and GZIP but config files don't exist
		################################################################################
		cat <<-EOF >"/boot/config-${ver}"
			CONFIG_RD_ZSTD=y
			CONFIG_RD_GZIP=y
		EOF
	done
	log "Raspi Kernel and Modules installed" "okay"
}

################################################################################
# COMMON CHROOT TWEAKS FUNCTION
################################################################################
# This function runs INSIDE the chroot environment
# Installs packages and configures system-level Pi-specific settings
################################################################################

device_chroot_tweaks_common() {
	################################################################################
	# DETECT DEBIAN SUITE FROM CHROOT
	################################################################################
	# The ${SUITE} variable from build environment may not be available in chroot
	# Read suite name from /etc/os-release which is created by debootstrap
	# This ensures correct APT repository configuration for bookworm, trixie, etc.
	################################################################################
	
	log "Detecting suite from /etc/os-release" "info"
	if [[ -f /etc/os-release ]]; then
		CHROOT_SUITE=$(grep VERSION_CODENAME /etc/os-release | cut -d'=' -f2)
		log "Detected suite: ${CHROOT_SUITE}" "info"
	else
		log "Could not detect suite, defaulting to bookworm" "wrn"
		CHROOT_SUITE="bookworm"
	fi
	
	################################################################################
	# ADD RASPBERRY PI REPOSITORY IN CHROOT
	################################################################################
	# Must configure repository inside chroot for package installation
	# This duplicates configuration from device_image_tweaks but necessary
	# because we're in a different execution context
	################################################################################
	
	log "Adding Pi repository for ${CHROOT_SUITE}" "info"
	cat >/etc/apt/sources.list.d/raspi.list <<EOF
deb http://archive.raspberrypi.com/debian/ ${CHROOT_SUITE} main untested
EOF

	################################################################################
	# INSTALL PI-SPECIFIC PACKAGES
	################################################################################
	# pi-bluetooth:          Bluetooth firmware and configuration for Pi WiFi/BT chips
	# raspberrypi-sys-mods:  System modifications and udev rules for Pi hardware
	# rpi-eeprom:            EEPROM update tools for Pi 4/5 bootloader
	# raspi-utils:           Utility tools (raspi-config, etc.)
	# libdtovl0:             Device tree overlay library
	# firmware-libertas:     WiFi firmware for Marvell chipsets
	# firmware-mediatek:     WiFi firmware for MediaTek chipsets
	################################################################################
	
	log "Installing Pi-specific packages" "info"
	apt-get update
	apt-get install -y --no-install-recommends \
		pi-bluetooth \
		raspberrypi-sys-mods \
		rpi-eeprom \
		raspi-utils \
		libdtovl0 \
		firmware-libertas \
		firmware-mediatek

	################################################################################
	# USER GROUP MEMBERSHIP
	################################################################################
	# Add volumio user to hardware access groups
	# gpio:  Access to /dev/gpiomem for GPIO control without root
	# i2c:   Access to /dev/i2c-* devices for I2C communication
	# spi:   Access to /dev/spidev* for SPI communication
	# input: Access to input devices (required for some touchscreens)
	################################################################################
	
	log "Adding volumio to gpio,i2c,spi group" "info"
	usermod -a -G gpio,i2c,spi,input volumio

	################################################################################
	# VIDEO CORE LIBRARY CONFIGURATION
	################################################################################
	# VideoCore is the GPU/multimedia processor in Raspberry Pi
	# Legacy applications and some plugins need access to VideoCore libraries
	################################################################################
	
	log "Handling Video Core quirks" "info"

	################################################################################
	# Add /opt/vc/lib to dynamic linker search path
	# VideoCore libraries (libvcos, libmmal, etc.) are installed here
	# Many Pi-specific applications depend on these libraries
	################################################################################
	
	log "Adding /opt/vc/lib to linker" "info"
	cat <<-EOF >/etc/ld.so.conf.d/00-vmcs.conf
		/opt/vc/lib
	EOF
	log "Updating LD_LIBRARY_PATH" "info"
	ldconfig

	################################################################################
	# LD-LINUX.SO.3 COMPATIBILITY SYMLINK
	################################################################################
	# libraspberrypi0 package normally creates this symlink
	# But we block that package, so create symlink manually
	# Required for some binary-only Pi applications that hardcode this path
	# Only needed on 32-bit armhf builds
	################################################################################
	
	if [[ ! -f /lib/ld-linux.so.3 ]] && [[ "$(dpkg --print-architecture)" = armhf ]]; then
		log "Linking /lib/ld-linux.so.3"
		ln -s /lib/ld-linux-armhf.so.3 /lib/ld-linux.so.3 2>/dev/null || true
		ln -s /lib/arm-linux-gnueabihf/ld-linux-armhf.so.3 /lib/arm-linux-gnueabihf/ld-linux.so.3 2>/dev/null || true
	fi

	################################################################################
	# VIDEO CORE UTILITY SYMLINKS
	################################################################################
	# Legacy VideoCore utilities used by some plugins and scripts
	# NOTE: Quoting popcornmix "Code from here is no longer installed on latest
	# RPiOS Bookworm images. If you are using code from here you should rethink
	# your solution. Consider this repo closed."
	# https://github.com/RPi-Distro/firmware/blob/debian/debian/libraspberrypi-bin.links
	# TODO: Clean this up! Identify which utilities are actually needed and why
	################################################################################
	
	log "Symlinking vc bins" "info"
	VC_BINS=(
		"edidparser"
		"raspistill"
		"raspivid"
		"raspividyuv"
		"raspiyuv"
		"tvservice"
		"vcdbg"
		"vchiq_test"
		"dtoverlay-pre"
		"dtoverlay-post"
	)

	for bin in "${VC_BINS[@]}"; do
		if [[ ! -f /usr/bin/${bin} && -f /opt/vc/bin/${bin} ]]; then
			ln -s "/opt/vc/bin/${bin}" "/usr/bin/${bin}"
			log "Linked ${bin}"
		else
			log "${bin} wasn't linked!" "wrn"
		fi
	done

	################################################################################
	# VCGENCMD PERMISSIONS
	################################################################################
	# vcgencmd is used to query VideoCore for system information
	# (temperature, voltage, clock speeds, etc.)
	# Default permissions are root-only, this allows video group access
	# Volumio user is member of video group for this access
	################################################################################
	
	log "Fixing vcgencmd permissions" "info"
	cat <<-EOF >/etc/udev/rules.d/10-vchiq.rules
		SUBSYSTEM=="vchiq",GROUP="video",MODE="0660"
	EOF

	################################################################################
	# CUSTOM FIRMWARE INSTALLATION (OPTIONAL)
	################################################################################
	# Device recipes can define CustomFirmware associative array
	# with firmware name as key and download URL as value
	# Used for additional drivers, firmware blobs, or custom binaries
	################################################################################
	
	if [[ ${#CustomFirmware[@]} -gt 0 ]]; then
		log "Adding Custom firmware from github" "info"
		# TODO: There is gcc mismatch between Bookworm and rpi-firmware
		# In chroot environment ld-linux.so.3 complains when using drop-ship to /usr
		# This is why we extract to /tmp first, then copy selectively
		for key in "${!CustomFirmware[@]}"; do
			mkdir -p "/tmp/$key" && cd "/tmp/$key"
			wget -nv "${CustomFirmware[$key]}" -O "$key.tar.gz" || {
				log "Failed to get firmware:" "err" "${key}"
				rm "$key.tar.gz" && cd - && rm -rf "/tmp/$key"
				continue
			}
			tar --strip-components 1 --exclude "*.hash" --exclude "*.md" -xf "$key.tar.gz"
			rm "$key.tar.gz"
			if [[ -d boot ]]; then
				log "Updating /boot content" "info"
				cp -rp boot "${ROOTFS}"/ && rm -rf boot
			fi
			log "Adding $key update" "info"
			cp -rp * "${ROOTFS}"/usr && cd - && rm -rf "/tmp/$key"
		done
	fi

	################################################################################
	# GPIOMEM DEVICE NAME CHANGE
	################################################################################
	# Kernel 6.1.54+ renamed bcm2835-gpiomem to gpiomem
	# Update udev rules to match new device name
	# This affects GPIO access permissions for non-root users
	################################################################################
	
	if [[ "${KERNEL_SEMVER[0]}" -gt 6 ]] ||
		[[ "${KERNEL_SEMVER[0]}" -eq 6 && "${KERNEL_SEMVER[1]}" -gt 1 ]] ||
		[[ "${KERNEL_SEMVER[0]}" -eq 6 && "${KERNEL_SEMVER[1]}" -eq 1 && "${KERNEL_SEMVER[2]}" -ge 54 ]]; then
		log "Rename gpiomem in udev rules" "info"
		sed -i 's/bcm2835-gpiomem/gpiomem/g' /etc/udev/rules.d/99-com.rules
	fi

	################################################################################
	# ENABLE I2C KERNEL MODULE
	################################################################################
	# i2c-dev provides userspace access to I2C bus
	# Required for I2C DACs, displays, sensors, etc.
	# Device tree must also enable I2C hardware (done in config.txt)
	################################################################################
	
	log "Enabling i2c-dev module" "info"
	echo "i2c-dev" >>/etc/modules
}

################################################################################
# COMMON POST-TWEAKS FUNCTION
################################################################################
# Runs after chroot and initramfs creation, before image finalization
################################################################################

device_image_tweaks_post_common() {
	################################################################################
	# PLYMOUTH SYSTEMD SERVICES FOR KMS/DRM
	################################################################################
	# For displays using KMS (Kernel Mode Setting) without framebuffer bridge,
	# Plymouth requires modified systemd service files
	# Device recipe sets UPDATE_PLYMOUTH_SERVICES_FOR_KMS_DRM=yes to enable
	#
	# This affects:
	# - Official Pi Touch Display 2 (DSI)
	# - Waveshare DSI displays
	# - Any display using panel drivers without fbdev emulation
	################################################################################
	
	if [[ "${UPDATE_PLYMOUTH_SERVICES_FOR_KMS_DRM}" == yes ]]; then
		log "Updating plymouth systemd services" "info"
		cp -dR "${SRC}"/volumio/framebuffer/systemd/* "${ROOTFSMNT}"/lib/systemd
	fi
}

################################################################################
# END OF RASPBERRY PI FAMILY CONFIGURATION
################################################################################
