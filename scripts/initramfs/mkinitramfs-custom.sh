#!/usr/bin/env bash
#set -eo pipefail Disabled for now

function error() {
  log "mkinitramfs failed" "$(basename "$0")" "err"
}

trap error INT ERR
umask 0022
export PATH='/usr/bin:/sbin:/bin'

# Defaults
keep="n"
CONFDIR="/etc/initramfs-tools"
verbose="n"
# Will be updated by busybox's conf hook, if present
BUSYBOXDIR=
export BUSYBOXDIR

usage() {
  cat <<EOF

Usage: mkinitramfs [option]... -o outfile [version]

Options:
  -c compress	Override COMPRESS setting in initramfs.conf.
  -d confdir	Specify an alternative configuration directory.
  -l level	Override COMPRESSLEVEL setting in initramfs.conf.
  -k		Keep temporary directory used to make the image.
  -o outfile	Write to outfile.
  -r root	Override ROOT setting in initramfs.conf.

See mkinitramfs(8) for further details.

EOF
}

usage_error() {
  usage >&2
  exit 2
}

OPTIONS=$(getopt -o c:d:hl:ko:r:v --long help -n "$0" -- "$@") || usage_error

eval set -- "$OPTIONS"

while true; do
  case "$1" in
  -c)
    compress="$2"
    shift 2
    ;;
  -d)
    CONFDIR="$2"
    shift 2
    if [ ! -d "${CONFDIR}" ]; then
      echo "${0}: ${CONFDIR}: Not a directory" >&2
      exit 1
    fi
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  -l)
    compresslevel="$2"
    shift 2
    ;;
  -o)
    outfile="$2"
    shift 2
    ;;
  -k)
    keep="y"
    shift
    ;;
  -r)
    ROOT="$2"
    shift 2
    ;;
  -v)
    verbose="y"
    shift
    ;;
  --)
    shift
    break
    ;;
  *)
    echo "Internal error!" >&2
    exit 1
    ;;
  esac
done

# For dependency ordered mkinitramfs hook scripts.
. /usr/share/initramfs-tools/scripts/functions
. /usr/share/initramfs-tools/hook-functions
# shellcheck source=/dev/null
. "${CONFDIR}/initramfs.conf"

EXTRA_CONF=''
maybe_add_conf() {
  if [ -e "$1" ] &&
    basename "$1" |
    grep '^[[:alnum:]][[:alnum:]\._-]*$' |
      grep -qv '\.dpkg-.*$'; then
    if [ -d "$1" ]; then
      echo "W: $1 is a directory instead of file" >&2
    else
      EXTRA_CONF="${EXTRA_CONF} $1"
      # shellcheck source=/dev/null
      . "$1"
    fi
  fi
}
for i in /usr/share/initramfs-tools/conf.d/*; do
  # Configuration files in /etc mask those in /usr/share
  if ! [ -e "${CONFDIR}"/conf.d/"$(basename "${i}")" ]; then
    maybe_add_conf "${i}"
  fi
done
for i in "${CONFDIR}"/conf.d/*; do
  maybe_add_conf "${i}"
done

# source package confs
for i in /usr/share/initramfs-tools/conf-hooks.d/*; do
  if [ -d "${i}" ]; then
    echo "W: ${i} is a directory instead of file." >&2
  elif [ -e "${i}" ]; then
    # shellcheck disable=SC1090
    . "${i}"
  fi
done

# Check busybox dependency
if [ "${BUSYBOX}" = "y" ] && [ -z "${BUSYBOXDIR}" ]; then
  echo >&2 "E: @BUSYBOX_PACKAGES@, version @BUSYBOX_MIN_VERSION@ or later, is required but not installed"
  exit 1
fi

if [ -n "${UMASK:-}" ]; then
  umask "${UMASK}"
fi

if [ -z "${outfile}" ]; then
  usage_error
fi

touch "$outfile"
outfile="$(readlink -f "$outfile")"

## Wrap original mkinitramfs -> build_initramfs
build_initramfs() {
  # And by "version" we really mean path to kernel modules
  # This is braindead, and exists to preserve the interface with mkinitrd
  if [ ${#} -ne 1 ]; then
    version="$(uname -r)"
  else
    version="${1}"
  fi

  case "${version}" in
  /lib/modules/*/[!/]*) ;;
  /lib/modules/[!/]*)
    version="${version#/lib/modules/}"
    version="${version%%/*}"
    ;;
  esac

  case "${version}" in
  */*)
    echo "$PROG: ${version} is not a valid kernel version" >&2
    exit 2
    ;;
  esac

  if [ -z "${compress:-}" ]; then
    compress=${COMPRESS?}
  fi
  unset COMPRESS

  if ! command -v "${compress}" >/dev/null 2>&1; then
    echo "W: No ${compress} in ${PATH}, using gzip" >&2
    compress=gzip
  fi

  # Check that kernel supports selected compressor, and fall back to gzip.
  # Exit if even gzip is not supported.
  case "${compress}" in
  gzip) kconfig_sym=CONFIG_RD_GZIP ;;
  bzip2) kconfig_sym=CONFIG_RD_BZIP2 ;;
  lzma) kconfig_sym=CONFIG_RD_LZMA ;;
  xz) kconfig_sym=CONFIG_RD_XZ ;;
  lzop) kconfig_sym=CONFIG_RD_LZO ;;
  lz4) kconfig_sym=CONFIG_RD_LZ4 ;;
  zstd) kconfig_sym=CONFIG_RD_ZSTD ;;
  esac
  while ! grep -q "^$kconfig_sym=y" "/boot/config-${version}"; do
    if [ "${compress}" = gzip ]; then
      echo "E: gzip compression ($kconfig_sym) not supported by kernel" >&2
      exit 1
    fi
    echo "W: ${compress} compression ($kconfig_sym) not supported by kernel, using gzip" >&2
    compress=gzip
    kconfig_sym=CONFIG_RD_GZIP
  done

  if [ -z "${compresslevel:-}" ]; then
    compresslevel=${COMPRESSLEVEL:-}
  fi
  case "${compress}" in
  lz4) compresslevel="-${compresslevel:-9}" ;;
  zstd) compresslevel="-${compresslevel:-9}" ;;
  #gzip|xz|bzip2|lzma|lzop included
  *)
    # We're not using a compression level by default
    compresslevel="${compresslevel:+-${compresslevel}}"
    ;;
  esac
  unset COMPRESSLEVEL

  case "${compress}" in
  gzip) # If we're doing a reproducible build, use gzip -n
    if [ -n "${SOURCE_DATE_EPOCH}" ]; then
      compress="gzip -n"
    # Otherwise, substitute pigz if it's available
    elif command -v pigz >/dev/null; then
      compress=pigz
    fi
    if [ -n "${compresslevel}" ]; then
      compress="${compress} ${compresslevel}"
    fi
    ;;
  lz4) compress="lz4 ${compresslevel} -l" ;;
  zstd)
    compress="zstd -q ${compresslevel}"
    # If we're not doing a reproducible build, enable multithreading
    test -z "${SOURCE_DATE_EPOCH}" && compress="$compress -T0"
    ;;
  xz)
    compress="xz ${compresslevel} --check=crc32"
    # If we're not doing a reproducible build, enable multithreading
    test -z "${SOURCE_DATE_EPOCH}" && compress="$compress --threads=0"
    ;;
  bzip2 | lzma | lzop)
    compress="${compress} ${compresslevel}"
    ;;
  *) echo "W: Unknown compression command ${compress}" >&2 ;;
  esac

  if [ -d "${outfile}" ]; then
    echo "${outfile} is a directory" >&2
    exit 1
  fi

  MODULESDIR="/lib/modules/${version}"

  if [ ! -e "${MODULESDIR}" ]; then
    echo "W: missing ${MODULESDIR}" >&2
    echo "W: Ensure all necessary drivers are built into the linux image!" >&2
  fi
  if [ ! -e "${MODULESDIR}/modules.dep" ]; then
    depmod "${version}"
  fi

  # Prepare to clean up temporary files on exit
  DESTDIR=
  __TMPCPIOGZ=
  __TMPMAINCPIO=
  __TMPEARLYCPIO=
  # shellcheck disable=SC2317
  clean_on_exit() {
    if [ "${keep}" = "y" ]; then
      echo "Working files in ${DESTDIR:-<not yet created>}," \
        "early initramfs in ${__TMPEARLYCPIO:-<not yet created>}," \
        "main initramfs in ${__TMPMAINCPIO:-<not yet created>} and" \
        "overlay in ${__TMPCPIOGZ:-<not yet created>}"
    else
      for path in "${DESTDIR}" "${__TMPCPIOGZ}" "${__TMPMAINCPIO}" "${__TMPEARLYCPIO}"; do
        test -z "${path}" || rm -rf "${path}"
      done
    fi
  }
  trap clean_on_exit EXIT
  trap "exit 1" INT TERM # makes the EXIT trap effective even when killed

  # Create temporary directory and files for initramfs contents
  [ -n "${TMPDIR}" ] && [ ! -w "${TMPDIR}" ] && unset TMPDIR
  DESTDIR="$(mktemp -d "${TMPDIR:-/var/tmp}/mkinitramfs_XXXXXX")" || exit 1
  chmod 755 "${DESTDIR}"
  __TMPCPIOGZ="$(mktemp "${TMPDIR:-/var/tmp}/mkinitramfs-OL_XXXXXX")" || exit 1
  __TMPMAINCPIO="$(mktemp "${TMPDIR:-/var/tmp}/mkinitramfs-MAIN_XXXXXX")" || exit 1
  __TMPEARLYCPIO="$(mktemp "${TMPDIR:-/var/tmp}/mkinitramfs-FW_XXXXXX")" || exit 1

  DPKG_ARCH=$(dpkg --print-architecture)

  # Export environment for hook scripts.
  #
  export MODULESDIR
  export version
  export CONFDIR
  export DESTDIR
  export DPKG_ARCH
  export verbose
  export KEYMAP
  export MODULES
  export BUSYBOX
  export RESUME
  export FSTYPE

  # Private, used by 'catenate_cpiogz'.
  export __TMPCPIOGZ

  # Private, used by 'prepend_earlyinitramfs'.
  export __TMPEARLYCPIO

  # Create usr-merged filesystem layout, to avoid duplicates if the host
  # filesystem is usr-merged.
  for d in /bin /lib* /sbin; do
    mkdir -p "${DESTDIR}/usr${d}"
    ln -s "usr${d}" "${DESTDIR}${d}"
  done
  for d in conf/conf.d etc run scripts ${MODULESDIR}; do
    mkdir -p "${DESTDIR}/${d}"
  done

  # Copy in modules.builtin, modules.builtin.modinfo and modules.order (not generated by depmod)
  # and modules.builtin.bin (generated by depmod, but too late to avoid
  # error messages as in #948257)
  for x in modules.builtin modules.builtin.bin modules.builtin.modinfo modules.order; do
    if [ -f "${MODULESDIR}/${x}" ]; then
      cp -p "${MODULESDIR}/${x}" "${DESTDIR}${MODULESDIR}/${x}"
    fi
  done

  # MODULES=list case.  Always honour.
  for x in "${CONFDIR}/modules" /usr/share/initramfs-tools/modules.d/*; do
    if [ -f "${x}" ]; then
      add_modules_from_file "${x}"
    fi
  done

  # MODULES=most is default
  case "${MODULES}" in
  dep)
    dep_add_modules
    ;;
  most)
    auto_add_modules
    ;;
  netboot)
    auto_add_modules base
    auto_add_modules net
    ;;
  list)
    # nothing to add
    ;;
  *)
    echo "W: mkinitramfs: unsupported MODULES setting: ${MODULES}." >&2
    echo "W: mkinitramfs: Falling back to MODULES=most." >&2
    auto_add_modules
    ;;
  esac

  # Resolve hidden dependencies
  hidden_dep_add_modules

  # Add firmware for built-in code
  add_builtin_firmware

  # First file executed by linux
  cp -p /usr/share/initramfs-tools/init "${DESTDIR}/init"

  # add existant boot scripts
  for b in $(cd /usr/share/initramfs-tools/scripts/ && find . \
    -regextype posix-extended -regex '.*/[[:alnum:]\._-]+$' -type f); do
    [ -d "${DESTDIR}/scripts/$(dirname "${b}")" ] ||
      mkdir -p "${DESTDIR}/scripts/$(dirname "${b}")"
    cp -p "/usr/share/initramfs-tools/scripts/${b}" \
      "${DESTDIR}/scripts/$(dirname "${b}")/"
  done
  # Prune dot-files/directories and limit depth to exclude VCS files
  for b in $(cd "${CONFDIR}/scripts" && find . -maxdepth 2 -name '.?*' -prune -o \
    -regextype posix-extended -regex '.*/[[:alnum:]\._-]+$' -type f -print); do
    [ -d "${DESTDIR}/scripts/$(dirname "${b}")" ] ||
      mkdir -p "${DESTDIR}/scripts/$(dirname "${b}")"
    cp -p "${CONFDIR}/scripts/${b}" "${DESTDIR}/scripts/$(dirname "${b}")/"
  done

  echo "DPKG_ARCH=${DPKG_ARCH}" >"${DESTDIR}/conf/arch.conf"
  cp -p "${CONFDIR}/initramfs.conf" "${DESTDIR}/conf"
  for i in ${EXTRA_CONF}; do
    copy_file config "${i}" /conf/conf.d
  done

  # ROOT hardcoding
  if [ -n "${ROOT:-}" ]; then
    echo "ROOT=${ROOT}" >"${DESTDIR}/conf/conf.d/root"
  fi

  if ! command -v ldd >/dev/null 2>&1; then
    echo "E: no ldd around - install libc-bin" >&2
    exit 1
  fi

  # fstab and mtab
  touch "${DESTDIR}/etc/fstab"
  ln -s /proc/mounts "${DESTDIR}/etc/mtab"

  # module-init-tools
  copy_exec /sbin/modprobe /sbin
  copy_exec /sbin/rmmod /sbin
  mkdir -p "${DESTDIR}/etc/modprobe.d" "${DESTDIR}/lib/modprobe.d"
  for file in /etc/modprobe.d/*.conf /lib/modprobe.d/*.conf; do
    if test -e "$file" || test -L "$file"; then
      copy_file config "$file"
    fi
  done

  run_scripts /usr/share/initramfs-tools/hooks
  run_scripts "${CONFDIR}"/hooks

  # cache boot run order
  for b in $(cd "${DESTDIR}/scripts" && find . -mindepth 1 -type d); do
    cache_run_scripts "${DESTDIR}" "/scripts/${b#./}"
  done

  # decompress modules for boot speed, if possible
  find "${DESTDIR}/${MODULESDIR}" -name '*.ko.*' | while read -r ko; do
    case "$ko" in
    *.xz)
      if ! command -v xz >/dev/null 2>&1; then
        break
      fi
      xz -d "${ko}"
      ;;
    *.zst)
      if ! command -v zstd >/dev/null 2>&1; then
        break
      fi
      zstd -q -d --rm "${ko}"
      ;;
    esac
  done

  # generate module deps
  depmod -a -b "${DESTDIR}" "${version}"
  rm -f "${DESTDIR}/lib/modules/${version}"/modules.*map

  # make sure that library search path is up to date
  cp -pPr /etc/ld.so.conf* "$DESTDIR"/etc/
  if ! ldconfig -r "$DESTDIR"; then
    [ "$(id -u)" != "0" ] &&
      echo "ldconfig might need uid=0 (root) for chroot()" >&2
  fi
  # The auxiliary cache is not reproducible and is always invalid at boot
  # (see #845034)
  if [ -d "${DESTDIR}"/var/cache/ldconfig ]; then
    rm -f "${DESTDIR}"/var/cache/ldconfig/aux-cache
    rmdir --ignore-fail-on-non-empty "${DESTDIR}"/var/cache/ldconfig
  fi

  # Apply DSDT to initramfs
  if [ -e "${CONFDIR}/DSDT.aml" ]; then
    copy_file DSDT "${CONFDIR}/DSDT.aml"
  fi

  [ "${verbose}" = y ] && echo "Building cpio ${outfile} initramfs"

  (
    # preserve permissions if root builds the image, see #633582
    [ "$(id -ru)" != 0 ] && cpio_owner_root="-R 0:0"

    # if SOURCE_DATE_EPOCH is set, try and create a reproducible image
    if [ -n "${SOURCE_DATE_EPOCH}" ]; then
      # ensure that no timestamps are newer than $SOURCE_DATE_EPOCH
      find "${DESTDIR}" -newermt "@${SOURCE_DATE_EPOCH}" -print0 |
        xargs -0r touch --no-dereference --date="@${SOURCE_DATE_EPOCH}"

      # --reproducible requires cpio >= 2.12
      cpio_reproducible="--reproducible"
    fi

    # work around lack of "set -o pipefail" for the following pipe:
    # cd "${DESTDIR}" && find . | LC_ALL=C sort | cpio --quiet $cpio_owner_root $cpio_reproducible -o -H newc >>"${outfile}" || exit 1
    ec1=1
    ec2=1
    exec 3>&1
    eval "$(
      # http://cfaj.freeshell.org/shell/cus-faq-2.html
      exec 4>&1 >&3 3>&-
      cd "${DESTDIR}"
      {
        find . 4>&-
        echo "ec1=$?;" >&4
      } | {
        LC_ALL=C sort
      } | {
        # shellcheck disable=SC2086
        cpio --quiet $cpio_owner_root $cpio_reproducible -o -H newc 4>&- >"${__TMPMAINCPIO}"
        echo "ec2=$?;" >&4
      }
    )"
    if [ "$ec1" -ne 0 ]; then
      echo "E: mkinitramfs failure find $ec1 cpio $ec2" >&2
      exit "$ec1"
    fi
    if [ "$ec2" -ne 0 ]; then
      echo "E: mkinitramfs failure cpio $ec2" >&2
      exit "$ec2"
    fi
  ) || exit 1

  {
    if [ -s "${__TMPEARLYCPIO}" ]; then
      cat "${__TMPEARLYCPIO}" || exit 1
    fi

    $compress -c "${__TMPMAINCPIO}" ||
      {
        echo "E: mkinitramfs failure $compress $?" >&2
        exit 1
      }

    if [ -s "${__TMPCPIOGZ}" ]; then
      cat "${__TMPCPIOGZ}" || exit 1
    fi
  } >"${outfile}" || exit 1

}

## Prepare a initramfs for Volumio.initrd
build_volumio_initramfs() {
  log "Creating Volumio intramsfs" "info"
  #shellcheck disable=SC2012 #We know it's going to be alphanumeric only!
  mapfile -t versions < <(ls -t /lib/modules | sort)
  # Pick how many kernels we want to add
  # (Future proofing for Rpi 5,6,7 etc..) ¯\_(ツ)_/¯

  num_ker_max=4

  log "Found ${#versions[@]} kernel version(s)" "${versions[*]}" "info"
  CMP=${COMPRESS?}
  log "Defauting to ${CMP} for initramfs compression"
  for ver in "${!versions[@]}"; do
    if [[ $ver -gt $num_ker_max ]]; then
      log "Using only ${num_ker_max} kernels" "wrn"
      log "Ignoring kernel ${versions[ver]}" "err"
      break
    fi
    log "Building intramsfs for Kernel[${ver}]: ${versions[ver]}" "info"
    unset compresslevel
    compress=${CMP}
    build_initramfs "${versions[ver]}"
    log "initramfs built for Kernel[${ver}]: ${versions[ver]} at ${DESTDIR}" "okay"
    if [[ $ver -eq 0 ]]; then
      # The first initramfs location
      DESTDIR_VOL=${DESTDIR}
    elif [[ $ver -ge 0 ]]; then
      log "Copying modules from ${DESTDIR} to ${DESTDIR_VOL}"
      cp -rf "${DESTDIR}/lib/modules/${versions[ver]}" \
        "${DESTDIR_VOL}/lib/modules/${versions[ver]}"
    fi    
  done
  # Set correct final tmp/mkinitramfs_XXXXXX
  DESTDIR=${DESTDIR_VOL}

  # Add in VolumioOS customisation
  log "Adding Volumio specific binaries" "info"
  # Add VolumioOS binaries
  volbins=('/sbin/parted' '/sbin/findfs' '/bin/lsblk' '/sbin/mke2fs'
    '/sbin/e2fsck' '/sbin/resize2fs' '/sbin/mke2fsfull' '/sbin/mkfs.vfat' '/sbin/fsck.fat')
  if [[ ${DPKG_ARCH} = 'i386' ]] || [[ ${DPKG_ARCH} = 'amd64' ]]; then
    log "Adding x86/x64 specific binaries (sgdisk/lsblk/dmidecode..etc)" "info"
    volbins+=('/usr/sbin/fdisk' '/usr/sbin/sgdisk' '/usr/sbin/dmidecode')
  fi
  # mkinitramfs for installer's do not have a volumio-init-updater
  if [[ -f "/usr/local/sbin/volumio-init-updater" ]]; then
    volbins+=('/usr/local/sbin/volumio-init-updater')
  fi
  for bin in "${volbins[@]}"; do
    if [[ -f ${bin} ]]; then
      log "Adding $bin to /sbin" "info"
      copy_exec "$bin" /sbin
    else
      log "$bin not found!" "wrn"
    fi
  done

}

## Create initrd image from initramsfs
build_initrd() {
  log "Creating volumio.initrd Image from ${DESTDIR}" "info"
  # Remove auto-generated scripts
  rm -rf "${DESTDIR}/scripts"
  # Add additional init scripts (in case there are any)
  if [ -d /root/scripts ]; then
    mkdir "${DESTDIR}/scripts"
    cp -pdR /root/scripts/* "${DESTDIR}/scripts/"
  fi
  cp /root/init "${DESTDIR}"
  cd "${DESTDIR}"
  OPTS=("-o")
  [ "${verbose}" = y ] && OPTS+=("-v") || OPTS+=("--quiet")
  log "Compressing volumio.initrd with ${compress}" "dbg"
  find . -print0 | cpio "${OPTS[@]}" -0 --format=newc | ${compress} >/boot/volumio.initrd
  # Check size
  log "Created: /boot/volumio.initrd" "okay"
  log "Boot partition info:" "dbg" "$(du -sh /boot)"
}

build_volumio_initramfs
build_initrd
