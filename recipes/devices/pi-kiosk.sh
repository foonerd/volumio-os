#!/usr/bin/env bash
# shellcheck disable=SC2034

################################################################################
# Raspberry Pi Kiosk Device Recipe
# 
# Target devices: OEM Pi devices running in kiosk mode
# Architecture: Inherits from pi.sh (ARMv7)
# 
# This recipe extends pi.sh for dedicated kiosk/display applications
# Enables fullscreen browser UI with Chromium for digital signage, displays, etc.
# Requires larger image size to accommodate browser and dependencies
################################################################################

DEVICE_SUPPORT_TYPE="S"
DEVICE_STATUS="M"

################################################################################
# IMPORT BASE PI CONFIGURATION
################################################################################
# Source pi.sh to inherit all standard Pi configuration
# Variables and functions from pi.sh become available here
################################################################################

source "${SRC}"/recipes/devices/pi.sh

################################################################################
# KIOSK-SPECIFIC OVERRIDES
################################################################################

KIOSKMODE=yes
KIOSKBROWSER=chromium

################################################################################
# PARTITION LAYOUT OVERRIDE
################################################################################
# Kiosk mode requires larger image to accommodate:
# - Chromium browser and dependencies (~500 MB)
# - X11 display server
# - Additional graphics libraries
# - Larger /data partition for browser cache
################################################################################

BOOT_END=180
IMAGE_END=3800

################################################################################
# NOTE: All other configuration inherited from pi.sh
################################################################################
# - Kernel version and installation
# - Module list
# - Boot configuration (config.txt, volumioconfig.txt, cmdline.txt)
# - Chroot tweaks
# - Device files
#
# The kiosk-specific setup (browser installation, X11 configuration, etc.)
# is handled by Volumio's kiosk plugin at runtime, not during image build
################################################################################
