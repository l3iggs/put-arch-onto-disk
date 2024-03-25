#!/usr/bin/env bash
set -o pipefail
set -o errexit
set -o nounset
set -o verbose
set -o xtrace
shopt -s extglob

# put-arch-onto-disk.sh
# This script installs Arch Linux onto media (making it bootable)
# or into a disk image which can later be dd'd onto some media to make it bootable
# this is an unattedded, one-shot command for making an Arch install that works out-of-the-box
# I've made attempts to make it reasonably configurable, but there is some stuff in here
# that you may not want (eg. the network comes up and sshd runs) so don't use this blindly

# example usage:
# TARGET=/dev/sdX sudo ./put-arch-onto-disk.sh |& tee archInstall.log

# define defaults for variables. defaults get overriden by previous definitions

: ${TARGET_ARCH='x86_64'}
: ${PACKAGE_LIST=''}

# local path(s) to package files to be installed
: ${PACKAGE_FILES=''}

# file system options
: ${ROOT_FS_TYPE='btrfs'}
: ${SWAP_SIZE_IS_RAM_SIZE='false'}
: ${SWAP_SIZE=''}  # empty for no swap partition, otherwise like '100MiB'

# target options
: ${TARGET='./bootable_arch.img'}  # if this is not a block device, then it's an image file that will be created
: ${SIZE=''}  # if TARGET is a block device, this is the size of the (or each of the, if AB_ROOTS is true) root partition(s)
# if TARGET is an image file, then it's the total size of that file

# misc options
: ${KEYMAP='us'}  # print options here with `localectl list-keymaps`
: ${TIME_ZONE='America/Edmonton'}  # timedatectl list-timezones
: ${LOCALE='en_US.UTF-8'}
: ${CHARSET='UTF-8'}
: ${ROOT_PASSWORD=''}  # zero length root password string locks out root login, otherwise even ssh via password is enabled for root
: ${THIS_HOSTNAME='archthing'}
: ${PORTABLE='true'}  # set false if you want the bootloader install to mod *this machine's* EFI vars
: ${UCODES='amd-ucode intel-ucode'}  # install these microcodes
: ${COPYIT=''}  # cp anything specified here to /root/install_copied
: ${CP_INTO_BOOT=''}  # cp anything specified here to /boot
: ${SKIP_NSPAWN='false'}  # if true, then don't do the OS setup in a container (do it on first boot)
: ${SKIP_SETUP='false'}  # skip _all_ custom OS setup altogether (implies SKIP_NSPAWN)
: ${AB_ROOTS='false'}  # make a second root partition ready for A/B operation
: ${RDP_SYSTEM='false'}  # enable system-level remote desktop share

# admin user options
: ${ADMIN_USER_NAME='admin'}  # zero length string for no admin user
: ${ADMIN_USER_PASSWORD='admin'}
: ${ADMIN_HOMED='false'}  # 'true' if the user should be a systemd-homed user
: ${ADMIN_SSH_AUTH_KEY=''}  # a public key that can be used to ssh into the admin account
: ${AUTOLOGIN_ADMIN='false'}

# AUR options
: ${AUR_HELPER=''}
#: ${AUR_HELPER='paru'}  # use empty string for no aur support
: ${AUR_PACKAGE_LIST=''}

: ${USE_TESTING='false'}
: ${LUKS_KEYFILE=''}

# for installing into preexisting multi boot setups:
: ${PREEXISTING_BOOT_PARTITION_NUM=''} # this will not be formatted
: ${PREEXISTING_ROOT_PARTITION_NUM=''} # this WILL be formatted
# any pre-existing swap partition will just be used via systemd magic

: ${CUSTOM_MIRROR_URL=''}
# useful with pacoloco on the host with config:
##repos:
##  archlinux:
##    url: http://mirrors.kernel.org/archlinux
##  alarm:
##    url: http://mirror.archlinuxarm.org
# and CUSTOM_MIRROR_URL='http://[ip]:9129/repo/alarm/$arch/$repo' for alarm

## END VARIABLE DEFINITION SECTION ##

if test $EUID -ne 0; then
	echo "Please run with root permissions"
	exit 1
fi

# store off the absolute path to *this* script
THIS="$( cd "$(dirname "$0")" ; pwd -P )"/$(basename $0)

contains() {
	string="$1"
	substring="$2"
	if test "${string#*$substring}" != "$string"; then
		true    # $substring is in $string
	else
		false    # $substring is not in $string
	fi
}

# check SIZE is given for an image file
if test -z "${SIZE}"; then
	if test ! -b "${TARGET}"; then
		echo "You must specify a SIZE when creating an image file."
		exit 1
	fi
fi

TO_EXISTING=true
if test -z "${PREEXISTING_BOOT_PARTITION_NUM}" || test -z "${PREEXISTING_ROOT_PARTITION_NUM}"; then
	if test -z "${PREEXISTING_BOOT_PARTITION_NUM}" && test -z "${PREEXISTING_ROOT_PARTITION_NUM}"; then
		TO_EXISTING=false
	else
		echo "You must specify both root and boot pre-existing partition numbers"
		exit 1
	fi
fi

if contains "${TARGET_ARCH}" "arm" || test "${TARGET_ARCH}" = "aarch64"; then
	HOST_NEEDS="qemu-user-static-binfmt"
	ARCH_SPECIFIC_PKGS="archlinuxarm-keyring"
else
	# alarm does not like/need these
	ARCH_SPECIFIC_PKGS="linux ${UCODES} sbsigntools reflector edk2-shell memtest86+-efi"
	HOST_NEEDS=""
fi

# here are a baseline set of packages for the new install
DEFAULT_PACKAGES="\
base \
${ARCH_SPECIFIC_PKGS} \
libmicrohttpd \
quota-tools \
systemd-ukify \
qrencode \
libpwquality \
libfido2 \
mpdecimal \
gnupg \
mkinitcpio \
haveged \
btrfs-progs \
dosfstools \
exfat-utils \
f2fs-tools \
openssh \
gpart \
parted \
mtools \
nilfs-utils \
ntfs-3g \
gdisk \
arch-install-scripts \
bash-completion \
rsync \
dialog \
ifplugd \
cpupower \
vi \
openssl \
ufw \
crda \
linux-firmware \
wireguard-tools \
polkit \
zsh \
pkgfile \
systemd-resolvconf \
pacman-contrib \
"

if test "${ROOT_FS_TYPE}" = "f2fs"; then
	DEFAULT_PACKAGES="${DEFAULT_PACKAGES} fscrypt"
fi

# if this is a pi then let's make sure we have the packages listed here
if contains "${PACKAGE_LIST}" "raspberry"; then
	PACKAGE_LIST="${PACKAGE_LIST} iw wireless-regdb wireless_tools wpa_supplicant"
fi

# install these packages on the host now. they're needed for the install process
pacman -S --needed --noconfirm btrfs-progs dosfstools f2fs-tools gpart parted gdisk arch-install-scripts hdparm ${HOST_NEEDS} 

# flush writes to disks and re-probe partitions
sync
partprobe

# is this a block device?
if test -b "${TARGET}"; then
	TARGET_DEV="${TARGET}"
	for n in ${TARGET_DEV}* ; do umount $n || true; done
	for n in ${TARGET_DEV}* ; do umount $n || true; done
	for n in ${TARGET_DEV}* ; do umount $n || true; done
	IMG_NAME=""
	hdparm -r0 ${TARGET_DEV}
else  # installing to image file
	IMG_NAME="${TARGET}"
	rm -f "${IMG_NAME}"
	fallocate --length "${SIZE}" "${IMG_NAME}"
	TARGET_DEV=$(losetup --find --nooverlap)
	losetup --partscan ${TARGET_DEV} "${IMG_NAME}"
fi

if test ! -b "${TARGET_DEV}"; then
	echo "ERROR: Install target device ${TARGET_DEV} is not a block device."
	exit 1
fi

# check that install to existing will work here
if test "${TO_EXISTING}" = "true"; then
	PARTLINE=$(parted -s ${TARGET_DEV} print | sed -n "/^ ${PREEXISTING_BOOT_PARTITION_NUM}/p")
	if contains "${PARTLINE}" "fat32" && contains "${PARTLINE}" "boot" && contains "${PARTLINE}" "esp"; then
		echo "Pre-existing boot partition looks good"
	else
		echo "Pre-existing boot partition must be fat32 with boot and esp flags"
		exit 1
	fi
	BOOT_PARTITION=${PREEXISTING_BOOT_PARTITION_NUM}
	ROOTA_PARTITION=${PREEXISTING_ROOT_PARTITION_NUM}

	# do we need to p? (depends on what the media is we're installing to)
	if test -b "${TARGET_DEV}p1"; then
		PEE=p
	else
		PEE=""
	fi
else  # format everything from scratch
	# destroy all file systems and partition tables on the target
	for n in ${TARGET_DEV}+([[:alnum:]]) ; do wipefs -a -f $n || true; done # wipe the partitions' file systems
	for n in ${TARGET_DEV}+([[:alnum:]]) ; do sgdisk -Z $n || true; done # zap the partitions' part tables
	wipefs -a -f ${TARGET_DEV} || true # wipe the device file system
	sgdisk -Z ${TARGET_DEV}  || true # wipe the device partition table
	blkdiscard "${TARGET_DEV}" || true

	NEXT_PARTITION=1
	if contains "${TARGET_ARCH}" "arm" || test "${TARGET_ARCH}" = "aarch64"; then
		echo "No bios grub for arm"
		BOOT_P_TYPE=0700
	else
		BOOT_P_TYPE=ef00
	fi
	BOOT_P_SIZE_MB=550
	sgdisk -n 0:+0:+${BOOT_P_SIZE_MB}MiB -t 0:${BOOT_P_TYPE} -c 0:"EFI system parition GPT" "${TARGET_DEV}"; BOOT_PARTITION=${NEXT_PARTITION}; ((NEXT_PARTITION++))
	if test "${SWAP_SIZE_IS_RAM_SIZE}" = "true"; then
		SWAP_SIZE=`free -b | grep Mem: | awk '{print $2}' | numfmt --to-unit=K`KiB
	fi
	if test -z "${SWAP_SIZE}"; then
		echo "No swap partition"
	else
		sgdisk -n 0:+0:+${SWAP_SIZE} -t 0:8200 -c 0:"Swap GPT" "${TARGET_DEV}"; SWAP_PARTITION=${NEXT_PARTITION}; ((NEXT_PARTITION++))
	fi

	ROOTA_START=$(sgdisk -F "${TARGET_DEV}")
	ROOTA_END=$(sgdisk -E "${TARGET_DEV}")
	if test "${AB_ROOTS}" = "true"; then
		ROOTA_END=$((($ROOTA_START+$ROOTA_END)/2))
	fi
	
	if test -z "${SIZE}" -o -n "${IMG_NAME}"; then
		sgdisk -n 0:${ROOTA_START}:${ROOTA_END} -t 0:8304 -c 0:"Arch Linux rootA GPT" "${TARGET_DEV}"; ROOTA_PARTITION=${NEXT_PARTITION}; ((NEXT_PARTITION++))
	else
		sgdisk -n "0:${ROOTA_START}:+${SIZE}" -t 0:8304 -c 0:"Arch Linux rootA GPT" "${TARGET_DEV}"; ROOTA_PARTITION=${NEXT_PARTITION}; ((NEXT_PARTITION++))
	fi

	if test "${AB_ROOTS}" = "true"; then
		if test -z "${SIZE}" -o -n "${IMG_NAME}"; then
			sgdisk -n 0:+0:+0 -t 0:8304 -c 0:"Arch Linux rootB GPT" "${TARGET_DEV}"; ROOTB_PARTITION=${NEXT_PARTITION}; ((NEXT_PARTITION++))
		else
			sgdisk -n "0:+0:+${SIZE}" -t 0:8304 -c 0:"Arch Linux rootB GPT" "${TARGET_DEV}"; ROOTB_PARTITION=${NEXT_PARTITION}; ((NEXT_PARTITION++))
		fi
	else
		ROOTB_PARTITION=""
	fi

	# make hybrid/protective MBR
	#sgdisk -h "1 2" "${TARGET_DEV}"  # this breaks rpi3
	echo -e "r\nh\n1 2\nN\n0c\nN\n\nN\nN\nw\nY\n" | sudo gdisk "${TARGET_DEV}"  # that's needed for rpi3

	# do we need to p? (depends on what the media is we're installing to)
	if test -b "${TARGET_DEV}p1"; then PEE=p; else PEE=""; fi

	wipefs -a -f ${TARGET_DEV}${PEE}${BOOT_PARTITION}
	mkfs.fat -F32 -n "BOOTF32" ${TARGET_DEV}${PEE}${BOOT_PARTITION}
	if test ! -z "${SWAP_SIZE}"; then
		wipefs -a -f ${TARGET_DEV}${PEE}${SWAP_PARTITION}
		mkswap -L "SWAP" ${TARGET_DEV}${PEE}${SWAP_PARTITION}
	fi
fi

ROOTA_DEVICE=${TARGET_DEV}${PEE}${ROOTA_PARTITION}
wipefs -a -f ${ROOTA_DEVICE} || true
if -n "${ROOTB_PARTITION}"; then
	ROOTB_DEVICE=${TARGET_DEV}${PEE}${ROOTB_PARTITION}
	wipefs -a -f ${ROOTB_DEVICE} || true
else
	ROOTB_DEVICE=""
fi

LUKS_UUID=""
if test -z "${LUKS_KEYFILE}"; then
	echo "Not using encryption"
else
	if test -f "${LUKS_KEYFILE}"; then
		echo "LUKS encryption with keyfile: $(readlink -f \"${LUKS_KEYFILE}\")"
		cryptsetup -q luksFormat ${ROOTA_DEVICE} "${LUKS_KEYFILE}"
		LUKS_UUID=$(cryptsetup luksUUID ${ROOTA_DEVICE})
		cryptsetup -q --key-file ${LUKS_KEYFILE} open ${ROOTA_DEVICE} luks-${LUKS_UUID}
		ROOTA_DEVICE=/dev/mapper/luks-${LUKS_UUID}
	else
		echo "Could not find ${LUKS_KEYFILE}"
		echo "Not using encryption"
		exit 1
	fi
fi

echo "Current partition table:"
sgdisk -p "${TARGET_DEV}"  # print the current partition table

if test "${ROOT_FS_TYPE}" = "f2fs"; then
	LABEL="-l"
	MKFS_FEATURES="-O extra_attr,encrypt,inode_checksum,sb_checksum,compression"
 	MOUNT_ARGS="--options defaults,compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,lazytime"
elif test "${ROOT_FS_TYPE}" = "btrfs"; then
	LABEL="--label"
	MKFS_FEATURES="--metadata dup --features free-space-tree,block-group-tree"
 	MOUNT_ARGS="--options defaults,noatime,compress=zstd:2"
else
	LABEL="-L"
	MKFS_FEATURES=""
 	MOUNT_ARGS="--options defaults"
fi
mkfs.${ROOT_FS_TYPE} ${MKFS_FEATURES} ${LABEL} "ROOT${ROOT_FS_TYPE^^}" ${ROOTA_DEVICE}
if -n "${ROOTB_DEVICE}"; then
	mkfs.${ROOT_FS_TYPE} ${MKFS_FEATURES} ${LABEL} "ROOT${ROOT_FS_TYPE^^}" ${ROOTB_DEVICE}
fi

TMP_ROOT=/tmp/diskRootTarget
mkdir -p ${TMP_ROOT}

mount --types ${ROOT_FS_TYPE} ${MOUNT_ARGS} ${ROOTA_DEVICE} ${TMP_ROOT}

if test "${ROOT_FS_TYPE}" = "btrfs"; then
	btrfs subvolume create ${TMP_ROOT}/root
	btrfs subvolume set-default ${TMP_ROOT}/root
	btrfs subvolume create ${TMP_ROOT}/home  # can be commented to disable home subvol
	umount ${TMP_ROOT}
	mount ${ROOTA_DEVICE} ${MOUNT_ARGS},subvol=root ${TMP_ROOT}
	mkdir ${TMP_ROOT}/home  # can be commented to disable home subvol
	mount ${ROOTA_DEVICE} ${MOUNT_ARGS},subvol=home ${TMP_ROOT}/home  # can be commented to disable home subvol
fi

install -d -m 0700 "${TMP_ROOT}/boot"
mount -o uid=0,gid=0,fmask=0077,dmask=0077 ${TARGET_DEV}${PEE}${BOOT_PARTITION} "${TMP_ROOT}/boot"
install -m644 -Dt /tmp /etc/pacman.d/mirrorlist
cat <<-EOF > /tmp/pacman.conf
	[options]
	HoldPkg     = pacman glibc
	Architecture = ${TARGET_ARCH}
	CheckSpace
	Color
	SigLevel = Required DatabaseOptional TrustedOnly
	LocalFileSigLevel = Optional
	SigLevel = Never
EOF

# enable the testing repo
if test "${USE_TESTING}" = "true"; then
	cat <<-"EOF" >> /tmp/pacman.conf
		[testing]
		Include = /tmp/mirrorlist
	EOF
fi

cat <<-"EOF" >> /tmp/pacman.conf
	[core]
	Include = /tmp/mirrorlist

	[extra]
	Include = /tmp/mirrorlist

	[community]
	Include = /tmp/mirrorlist
EOF

if contains "${TARGET_ARCH}" "arm" || test "${TARGET_ARCH}" = "aarch64"; then
	IS_ARM=1
	cat <<-EOF >> /tmp/pacman.conf
		[alarm]
		Include = /tmp/mirrorlist

		[aur]
		Include = /tmp/mirrorlist
	EOF
	sed '1s;^;Server = http://mirror.archlinuxarm.org/$arch/$repo\n;' -i /tmp/mirrorlist
	sed '1s;^;Server = http://ca.us.mirror.archlinuxarm.org/$arch/$repo\n;' -i /tmp/mirrorlist
else
	IS_ARM=""
fi

if test ! -z "${CUSTOM_MIRROR_URL}"; then
	sed "1s;^;Server = ${CUSTOM_MIRROR_URL}\n;" -i /tmp/mirrorlist
fi

pacstrap -C /tmp/pacman.conf -G -M "${TMP_ROOT}" ${DEFAULT_PACKAGES} ${PACKAGE_LIST}
if test ! -z "${COPYIT}"; then
	mkdir -p /"${TMP_ROOT}/root/install_copied"
	cp -a ${COPYIT} /"${TMP_ROOT}"/root/install_copied/.
fi

if test ! -z "${CP_INTO_BOOT}"; then
	mkdir -p /"${TMP_ROOT}/root/install_copied"
	cp -r ${CP_INTO_BOOT} /"${TMP_ROOT}"/boot/.
fi

if test ! -z "${PACKAGE_FILES}"; then
	pacstrap -C /tmp/pacman.conf -U -G -M "${TMP_ROOT}" ${PACKAGE_FILES}
fi

if test ! -z "${ADMIN_SSH_AUTH_KEY}"; then
	echo -n "${ADMIN_SSH_AUTH_KEY}" > "${TMP_ROOT}"/var/tmp/auth_pub.key
fi

genfstab -t PARTUUID "${TMP_ROOT}" >> "${TMP_ROOT}"/etc/fstab
sed -i '/swap/d' "${TMP_ROOT}"/etc/fstab

# switch rpi to "latest" firmware channel
if test -f "${TMP_ROOT}/etc/default/rpi-update"; then
	sed 's,^FIRMWARE_RELEASE_STATUS.*,FIRMWARE_RELEASE_STATUS="latest",' -i "${TMP_ROOT}/etc/default/rpi-update"
fi

# if test ! -z "${IS_ARM}"; then
# 	cat <<-'EOF' > "${TMP_ROOT}"/root/fix_rpi_boot_conf.sh
# 		#!/usr/bin/env bash

# 		# a script that will reprogram the rpi eeprom to attempt boot first
# 		# from USB and then from SD card

# 		rpi-eeprom-config --out boot.conf

# 		# see config options here:
# 		# https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-4-bootloader-configuration
# 		conf01=('BOOT_ORDER' '0xf14')  # boot usb then sd card
# 		conf02=('BOOT_UART' '0')
# 		arr=(conf01 conf02)

# 		declare -n elmv

# 		for elmv in "${arr[@]}"; do
# 			#if sed "s/^${elmv1[0]}=.*/${elmv1[0]}=${elmv1[1]}/" -i boot.conf; then
# 			if grep ^${elmv[0]}= boot.conf > /dev/null 2>/dev/null; then
# 				sed "s/^${elmv1[0]}=.*/${elmv1[0]}=${elmv1[1]}/" -i boot.conf
# 			else
# 				echo "${elmv[0]}=${elmv[1]}" >> boot.conf
# 			fi
# 		done

# 		sudo rpi-eeprom-config --apply boot.conf
# 		rm boot.conf
# 		sudo reboot
# 	EOF
# 	chmod +x "${TMP_ROOT}"/root/fix_rpi_boot_conf.sh
# fi

if test "${SKIP_SETUP}" != "true"; then
	# setup systemd's resolve stub
	if test "${SKIP_NSPAWN}" != "true"; then
		touch /link_resolv_conf.note #leave a marker so we can complete this setup later
	else
		# breaks network inside container
		ln -sf /run/systemd/resolve/stub-resolv.conf "${TMP_ROOT}/etc/resolv.conf"
	fi

	cat <<-EOF > "${TMP_ROOT}/root/phase_one.sh"
		#!/usr/bin/env bash
		set -o pipefail
		set -o errexit
		set -o nounset
		set -o verbose
		set -o xtrace
		touch /var/tmp/phase_one_setup_failed
		touch /var/tmp/phase_two_setup_failed
		echo 'Starting setup phase 1' | systemd-cat --priority=alert --identifier=p1setup


		# ONLY FOR TESTING:
		#rm /usr/share/factory/etc/securetty
		#rm /etc/securetty

		if test "${ROOT_FS_TYPE}" = "f2fs"
		then
			#fscrypt setup --force
			echo "not setting up fscrypt"
		fi

		# make a root pw for now. if needed, this will be disabled in phase 2
		if test -z "${ROOT_PASSWORD}"
		then
			echo "root:admin"|chpasswd
		else
			echo "root:${ROOT_PASSWORD}"|chpasswd
		fi
		sed 's,^#PermitRootLogin .*,PermitRootLogin yes,g' -i /etc/ssh/sshd_config

		# enable magic sysrq
		echo "kernel.sysrq = 1" > /etc/sysctl.d/99-sysctl.conf

		# set hostname
		echo "${THIS_HOSTNAME}" > /etc/hostname

		# set timezone
		ln -sf "/usr/share/zoneinfo/${TIME_ZONE}" /etc/localtime

		# generate adjtime (this is probably forbidden)
		hwclock --systohc || true
		timedatectl set-ntp true

		# do locale things
		sed -i "s,^#${LOCALE} ${CHARSET},${LOCALE} ${CHARSET},g" /etc/locale.gen
		locale-gen
		localectl set-locale LANG="${LOCALE}"
		unset LANG
		set +o nounset
		source /etc/profile.d/locale.sh
		set -o nounset
		localectl set-keymap --no-convert "${KEYMAP}"

		# set up bashrc
		cat << "END" >> /etc/skel/.bashrc
  			source /usr/share/doc/pkgfile/command-not-found.bash
			export HISTSIZE=10000
			export HISTFILESIZE=20000
			export HISTCONTROL=ignorespace:erasedups
			shopt -s histappend
			function historymerge {
				history -n; history -w; history -c; history -r;
			}
			trap historymerge EXIT
			PROMPT_COMMAND="history -a; \${PROMPT_COMMAND}"
		END

		# vim history setup
		cat << "END" >> /etc/skel/.vimrc
			set undodir=~/.vim/undodir
			set undofile
			set undolevels=1000
			set undoreload=10000
		END

		# setup GnuPG
		install -m700 -d /etc/skel/.gnupg
		touch /tmp/gpg.conf
		echo "keyserver keyserver.ubuntu.com" >> /tmp/gpg.conf
		echo "keyserver-options auto-key-retrieve" >> /tmp/gpg.conf
		touch /tmp/dirmngr.conf
		#echo "hkp-cacert /usr/share/gnupg/sks-keyservers.netCA.pem" >> /tmp/dirmngr.conf
		install -m600 -Dt /etc/skel/.gnupg/ /tmp/gpg.conf
		install -m600 -Dt /etc/skel/.gnupg/ /tmp/dirmngr.conf
		rm /tmp/gpg.conf
		rm /tmp/dirmngr.conf

		# copy over the skel files for the root user
		find /etc/skel -maxdepth 1 -mindepth 1 -exec cp -a {} /root \;

		pacman-key --init
		if [[ \$(uname -m) == *"arm"*  || \$(uname -m) == "aarch64" ]] ; then
			sed '1iallow-weak-key-signatures' -i /etc/pacman.d/gnupg/gpg.conf  # some nasty hack to avoid
			# signature from "Arch Linux ARM Build System <builder@archlinuxarm.org>" is marginal trust
			pacman-key --populate archlinuxarm
			echo 'Server = http://mirror.archlinuxarm.org/\$arch/\$repo' > /etc/pacman.d/mirrorlist
		else
			pacman-key --populate archlinux
			reflector --protocol https --latest 30 --number 20 --sort rate --save /etc/pacman.d/mirrorlist

			if pacman -Q edk2-shell > /dev/null 2>/dev/null; then
				cp /usr/share/edk2-shell/x64/Shell.efi /boot/shellx64.efi
			fi

			# setup boot with systemd-boot
			if test "${PORTABLE}" = "false"; then
				if test -d /sys/firmware/efi/efivars; then
					bootctl --efi-boot-option-description="Linux Boot Manager (${THIS_HOSTNAME})" install
				else
					echo "Can't find UEFI variables and so we won't try to mod them for systemd-boot install"
					bootctl --efi-boot-option-description="Linux Boot Manager (${THIS_HOSTNAME})" --no-variables install
				fi
			else
				bootctl --efi-boot-option-description="Linux Boot Manager (${THIS_HOSTNAME})" --no-variables install
			fi

			mkdir -p /boot/loader/entries
			cat << "END" > /boot/loader/loader.conf
				default arch.conf
				timeout 4
				console-mode auto
				editor yes
			END

			# let systemd update the bootloader
			systemctl enable systemd-boot-update.service

			if pacman -Q memtest86+-efi &> /dev/null; then
				cat << "END" > /boot/loader/entries/memtest.conf
					title  memtest86+
					efi    /memtest86+/memtest.efi
				END
			fi

			UCODE_LINES=""
			if test -f /boot/amd-ucode.img; then
				UCODE_LINES+="initrd  /amd-ucode.img\n"
			fi

			if test -f /boot/intel-ucode.img; then
				UCODE_LINES+="initrd  /intel-ucode.img\n"
			fi

			if pacman -Q linux &> /dev/null; then
				sed 's,^default.*,default arch.conf,g' --in-place /boot/loader/loader.conf
				cat << END > /boot/loader/entries/arch.conf
					title   Arch Linux (${THIS_HOSTNAME})
					linux   /vmlinuz-linux
					\$(echo -e \${UCODE_LINES})
					initrd  /initramfs-linux.img
					options root=PARTUUID=$(lsblk -no PARTUUID ${ROOTA_DEVICE}) rw libata.allow_tpm=1
				END

				cat << END > /boot/loader/entries/arch-fallback.conf
					title   Arch Linux (fallback initramfs, ${THIS_HOSTNAME})
					linux   /vmlinuz-linux
					\$(echo -e \${UCODE_LINES})
					initrd  /initramfs-linux-fallback.img
					options root=PARTUUID=$(lsblk -no PARTUUID ${ROOTA_DEVICE}) rw
				END
			fi

			if pacman -Q linux-lts &> /dev/null; then
				sed --in-place 's,^default.*,default arch-lts.conf,g' /boot/loader/loader.conf
				cat << END > /boot/loader/entries/arch-lts.conf
					title   Arch Linux LTS (${THIS_HOSTNAME})
					linux   /vmlinuz-linux-lts
					\$(echo -e \${UCODE_LINES})
					initrd  /initramfs-linux-lts.img
					options root=PARTUUID=$(lsblk -no PARTUUID ${ROOTA_DEVICE}) rw
				END

				cat << END > /boot/loader/entries/arch-fallback.conf
					title   Arch Linux LTS (fallback initramfs, ${THIS_HOSTNAME})
					linux   /vmlinuz-linux-lts
					\$(echo -e \${UCODE_LINES})
					initrd  /initramfs-linux-lts-fallback.img
					options root=PARTUUID=$(lsblk -no PARTUUID ${ROOTA_DEVICE}) rw
				END
			fi
		fi

		# make pacman color
		sed -i 's/^#Color/Color/g' /etc/pacman.conf

		# enable parallel downloads
		sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

		# if cpupower is installed, enable the service
		if pacman -Q cpupower &> /dev/null; then
			systemctl enable cpupower.service
			if [[ \$(uname -m) == *"arm"*  || \$(uname -m) == "aarch64" ]] ; then
				sed "s,^#governor=.*,governor='performance'," -i /etc/default/cpupower
			fi
		fi

		# enable package cleanup timer
		if pacman -Q pacman-contrib &> /dev/null; then
			systemctl enable paccache.timer
		fi

		# enable btrfs scrub timer
		if pacman -Q btrfs-progs &> /dev/null; then
			systemctl enable btrfs-scrub@-.timer
			systemctl enable btrfs-scrub@home.timer
		fi

		# setup firewall but don't turn it on just yet
		if pacman -Q ufw &> /dev/null; then
			systemctl enable ufw.service
			ufw default deny
			ufw allow 5353/udp comment "allow mDNS"
			ufw allow 5355 comment "allow LLMNR"
			# ufw enable
		fi

		# if openssh is installed, enable the service
		if pacman -Q openssh &> /dev/null; then
			systemctl enable sshd.service
			ufw limit ssh comment "limit ssh"
		fi

		systemctl enable systemd-resolved

		# if networkmanager is installed, enable it, otherwise let systemd things manage the network
		if pacman -Q networkmanager &> /dev/null; then
			systemctl enable NetworkManager.service
   			systemctl enable NetworkManager-wait-online.service
			cat << "END" > /etc/NetworkManager/conf.d/fancy_resolvers.conf
				[connection]
				connection.mdns=yes
				connection.llmnr=yes
			END
		else
			echo "Setting up systemd-networkd service"
			cat << "END" > /etc/systemd/network/20-DHCPany.network
				[Match]
				Name=!wg*

				[Link]
				Multicast=true

				[Network]
				DHCP=yes
				IPv6AcceptRA=yes
				MulticastDNS=yes
				LLMNR=yes

				[DHCPv4]
				UseDomains=yes
				ClientIdentifier=mac

				[IPv6AcceptRA]
				UseDomains=yes
			END

			#sed -i -e 's/hosts: files dns myhostname/hosts: files resolve myhostname/g' /etc/nsswitch.conf

			systemctl enable systemd-networkd
		fi

		# if gdm was installed, let's do a few things
		if pacman -Q gdm &> /dev/null; then
			systemctl enable gdm
			if [ ! -z "${ADMIN_USER_NAME}" ] && [ "${AUTOLOGIN_ADMIN}" = true ]; then
				echo "# Enable automatic login for user" >> /etc/gdm/custom.conf
				echo "[daemon]" >> /etc/gdm/custom.conf
				echo "AutomaticLogin=${ADMIN_USER_NAME}" >> /etc/gdm/custom.conf
				echo "AutomaticLoginEnable=True" >> /etc/gdm/custom.conf
			fi
		fi

		# if lxdm was installed, let's do a few things
		if pacman -Q lxdm &> /dev/null; then
			systemctl enable lxdm
			#TODO: set keyboard layout
			if [ ! -z "${ADMIN_USER_NAME}" ] && [ "${AUTOLOGIN_ADMIN}" = true ] ; then
				echo "# Enable automatic login for user" >> /etc/lxdm/lxdm.conf
				echo "autologin=${ADMIN_USER_NAME}" >> /etc/lxdm/lxdm.conf
			fi
		fi

		# attempt phase two setup (expected to fail in alarm because https://github.com/systemd/systemd/issues/18643)
		if test -f /root/phase_two.sh; then
			echo "Attempting phase two setup" | systemd-cat --priority=alert --identifier=p1setup
			set +o errexit
			bash /root/phase_two.sh
			P2RESULT=\$?
			set -o errexit
			if test -f /var/tmp/phase_two_setup_incomplete -o \${P2RESULT} -ne 0; then
				echo "Phase two setup failed" | systemd-cat --priority=emerg --identifier=p1setup
				echo "Boot into the system natively and run `bash /root/phase_two.sh`" | systemd-cat --priority=emerg --identifier=p1setup
			else
				rm -f /root/phase_two.sh
			fi
		fi

		# link systemd resolve stub now in case we were running in a container and didn't do it earlier 
		if test -f /link_resolv_conf.note; then
			ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
			rm /link_resolv_conf.note
		fi

		# undo container-needed changes to localed.service files
		if test "${SKIP_NSPAWN}" != "true"; then
			sed 's,#PrivateNetwork=yes,PrivateNetwork=yes,g' -i /usr/lib/systemd/system/systemd-localed.service
		fi

		fstrim --verbose --all

		rm -f /var/tmp/phase_one_setup_failed
		echo 'Setup phase 1 was successful' | systemd-cat --priority=alert --identifier=p1setup
		exit 0
	EOF
	chmod +x "${TMP_ROOT}/root/phase_one.sh"

	# create the service that will run phase 1 setup
	cat <<- "EOF" > "${TMP_ROOT}"/usr/lib/systemd/system/container-boot-setup.service
		[Unit]
		Description=Initial system setup tasks to be run in a container
		ConditionPathExists=/root/phase_one.sh

		[Service]
		Type=oneshot
		TimeoutStopSec=10sec
		ExecStart=/usr/bin/bash /root/phase_one.sh
		ExecStartPost=/usr/bin/sh -c 'rm -f /root/phase_one.sh; systemctl disable container-boot-setup; rm -f /usr/lib/systemd/system/container-boot-setup.service; halt'
	EOF

	# activate the service that will run phase 1 setup
	ln -s /usr/lib/systemd/system/container-boot-setup.service "${TMP_ROOT}"/etc/systemd/system/multi-user.target.wants/container-boot-setup.service

	# take care of some rpi config stuff
	#if test -f "${TMP_ROOT}/boot/cmdline.txt"; then
	#	echo "" >> /boot/config.txt
	#	echo "# PoE Hat Fan Speeds" >> /boot/config.txt
	#	echo "dtparam=poe_fan_temp0=50000" >> /boot/config.txt
	#	echo "dtparam=poe_fan_temp1=60000" >> /boot/config.txt
	#	echo "dtparam=poe_fan_temp2=70000" >> /boot/config.txt
	#	echo "dtparam=poe_fan_temp3=80000" >> /boot/config.txt
	#
	#	echo "hdmi_ignore_edid:0=0xa5000080" >> /boot/config.txt
	#	echo "hdmi_force_mode:0=1" >> /boot/config.txt
	#	echo "hdmi_group:0=2" >> /boot/config.txt
	#	echo "hdmi_mode:0=85" >> /boot/config.txt
	#
	#	echo "hdmi_ignore_edid:1=0xa5000080" >> /boot/config.txt
	#	echo "hdmi_force_mode:1=1" >> /boot/config.txt
	#	echo "hdmi_group:1=2" >> /boot/config.txt
	#	echo "hdmi_mode:1=82" >> /boot/config.txt
	#fi

	# add argument(s) to the pi kernel boot params
	#PI_VID_ARG='video=HDMI-A-1:1920x1080'
	#PI_KERNEL_PARAMS=""
	#if test ! -z "\${PI_KERNEL_PARAMS}"; then#
	#	if pacman -Q uboot-raspberrypi &> /dev/null; then
	#		pushd /boot
	#		sed '/^setenv bootargs/ s/$/ '\${PI_KERNEL_PARAMS}'/' file -i boot.txt
	#		./mkscr
	#		popd
	#	elif pacman -Qi linux-rpi &> /dev/null || pacman -Qi linux-rpi-16k &> /dev/null; then
	#		pushd /boot
	#		echo -n " \${PI_KERNEL_PARAMS}" >> cmdline.txt
	#		popd
	#	fi
	#fi


	# make some notes
	cat <<- "EOF" > "${TMP_ROOT}/root/recovery_notes.txt"
		1) mount root in /mnt
		2) mount home in /mnt/home
		3) mount boot in /mnt/boot
		4a) ncdu -x /mnt/home  # to make room in case the FS is full
		4b) ncdu -x /mnt  # to make room in case the FS is full 
		5) pacstrap /mnt $(pactree base -lu | pacman -Qq -)  # reintall base with deps
		6) arch-chroot /mnt
		7a) pacman -Qkknq | awk '{print $1 | "sort"}' | uniq | pacman -S -  # reinstall what's broken
		7b) pacman -Qqn | pacman -S -  # reinstall it all
		8a) paccheck --md5sum --quiet  # check integrity
		8b) pacman -Qkkq  # check integreity v2
		9) exit # exit chroot
		10) umount --recursive /mnt
	EOF

	# add a rootfs expander script
	cat <<- "EOF" > "${TMP_ROOT}/root/online_expand_root.sh"
		#!/usr/bin/env bash
  		# live (on-line) expands the root file system to take up all avialable space
		# nb. this script can be very destructive if its assumptions are not met
		# it assumes
  		# - root is btrfs, ext3 or ext4
    		# - root is mounted on a block device with a GPT
  		# - you have gptfdisk (for the sgdisk command) installed
		# - you have btrfs-tools installed (for the btrfs command) if you're expanding a btrfs root
		# - you have e2fsprogs installed (for the resize2fs command) if you're expanding an ext3 or ext4 root
  		# - if you're expanding an ext3 root, the resize_inode feature is enabled
		# - root is the last partition in the table
		# - the last partition does not end at the end of the block device
		# - there's nothing on the block device between the end of the last
		#     GPT partition and the block device of the disk that you care about
		set -o pipefail
		set -o errexit
		set -o nounset
		set -o verbose
		set -o xtrace

		ROOT_BLOCK="$(findmnt --nofsroot -n --df -e --target / -o SOURCE)"
		ROOT_DEV="/dev/$(lsblk -no pkname ${ROOT_BLOCK})"
		TEH_PART_UUID="$(lsblk -n -oPARTUUID ${ROOT_BLOCK})"
		TEH_PART_LABEL="$(lsblk -n -oPARTLABEL ${ROOT_BLOCK})"
  		TEH_FSTYPE="$(lsblk -n -ofstype ${ROOT_BLOCK})"

		if test "${TEH_FSTYPE}" != "btrfs" -a "${TEH_FSTYPE}" != "ext4" -a "${TEH_FSTYPE}" != "ext3"; then
			echo "Can not expand unsupported file system type: ${TEH_FSTYPE}"
   			exit 44
		fi

		# move backup header to end
		sgdisk -e "${ROOT_DEV}"
		partprobe

		# delete the last partition from the GPT
		N_PARTITIONS="$(sgdisk ${ROOT_DEV} -p | tail -1 | tr -s ' ' | cut -d ' ' -f2)"
		sgdisk -d "${N_PARTITIONS}" "${ROOT_DEV}"

		# remake the partition to fill the disk
		sgdisk -n 0:+0:+0 -t 0:8304 -c 0:"${TEH_PART_LABEL}" -u "0:${TEH_PART_UUID}" "${ROOT_DEV}"
		partprobe
		sync
		partprobe
		sync

		if test "${TEH_FSTYPE}" = "btrfs"; then
  			btrfs filesystem resize max /
		else
			resize2fs -p "${ROOT_BLOCK}"
     		fi

		rm -f /.expand

		sync
		partprobe

		echo "You should probably reboot now"
	EOF
	chmod +x "${TMP_ROOT}/root/online_expand_root.sh"

	# make a phase 2 setup script
	cat <<-EOF > "${TMP_ROOT}/root/phase_two.sh"
		#!/usr/bin/env bash
		set -o pipefail
		set -o errexit
		set -o nounset
		set -o verbose
		set -o xtrace
		echo 'Starting setup phase 2' | systemd-cat --priority=alert --identifier=p2setup

  		pkgfile -u

		# setup admin user
		if test ! -z "${ADMIN_USER_NAME}"; then
			pacman -S --needed --noconfirm sudo
			# users in the wheel group have password triggered sudo powers
			echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/01_wheel_can_sudo

			if test ! -z "${AUR_HELPER}"; then
				pacman -S --needed --noconfirm base-devel
				groupadd aur || true
				MAKEPKG_BACKUP="/var/cache/makepkg/pkg"
				install -d "\${MAKEPKG_BACKUP}" -g aur -m=775
				GRPS="aur,"
			else
				GRPS=""
			fi
			GRPS="\${GRPS}adm,uucp,wheel"

			if test -f /var/tmp/auth_pub.key; then
				ADD_KEY_CMD="--ssh-authorized-keys=\$(cat /var/tmp/auth_pub.key)"
			else
				echo "No user key supplied for ssh, generating one for you"
				mkdir -p /root/admin_sshkeys
				if test ! -f /root/admin_sshkeys/id_rsa.pub; then
					ssh-keygen -q -t rsa -N '' -f /root/admin_sshkeys/id_rsa
				fi
				ADD_KEY_CMD="--ssh-authorized-keys=\$(cat /root/admin_sshkeys/id_rsa.pub)"
			fi

			if test "${ADMIN_HOMED}" = "true"; then
				echo "Creating systemd-homed user"
				systemctl enable systemd-homed
				systemctl start systemd-homed

				STORAGE=directory
				if test "${ROOT_FS_TYPE}" = "btrfs"; then
					STORAGE=subvolume
				elif test "${ROOT_FS_TYPE}" = "f2fs"; then
					# TODO: fscrypt is broken today with "Failed to install master key in keyring: Operation not permitted"
					# see https://github.com/systemd/systemd/issues/18280
					# this first breaks the container setup, then it breaks again on bare metal because the keyring isn't set up
					#STORAGE=fscrypt
					STORAGE=directory
				fi

				if ! userdbctl user ${ADMIN_USER_NAME} &> /dev/null; then
					pacman -S --needed --noconfirm jq
					# make the user with homectl
					jq -n --arg pw "${ADMIN_USER_PASSWORD}" --arg pwhash \$(openssl passwd -6 "${ADMIN_USER_PASSWORD}") '{secret:{password:[\$pw]},privileged:{hashedPassword:[\$pwhash]}}' | homectl --identity=- create ${ADMIN_USER_NAME} --member-of=\${GRPS} --storage=\${STORAGE} "\${ADD_KEY_CMD}"
					sed "s,^#AuthorizedKeysCommand none,AuthorizedKeysCommand /usr/bin/userdbctl ssh-authorized-keys %u,g" -i /etc/ssh/sshd_config
					sed "s,^#AuthorizedKeysCommandUser nobody,AuthorizedKeysCommandUser root,g" -i /etc/ssh/sshd_config
					if test -f /var/tmp/auth_pub.key; then
						grep -qxF 'AuthenticationMethods publickey,password' /etc/ssh/sshd_config || echo "AuthenticationMethods publickey,password" >> /etc/ssh/sshd_config
					fi
				fi  # user doesn't exist
    				#homectl update ${ADMIN_USER_NAME} --shell=/usr/bin/zsh
			else  # non-homed user
				echo "Creating user"
				useradd -m ${ADMIN_USER_NAME} --groups "\${GRPS}"
				echo "${ADMIN_USER_NAME}:${ADMIN_USER_PASSWORD}"|chpasswd
    				#sudo -u ${ADMIN_USER_NAME} chsh -s /usr/bin/zsh
			fi  # user creation method

			rm -f /var/tmp/auth_pub.key

			if test -f /root/admin_sshkeys/id_rsa.pub; then
				if test "${ADMIN_HOMED}" = "true"; then
					PASSWORD="${ADMIN_USER_PASSWORD}" homectl activate ${ADMIN_USER_NAME}
				fi
				install -d /home/${ADMIN_USER_NAME}/.ssh -o ${ADMIN_USER_NAME} -g ${ADMIN_USER_NAME} -m=700
				cp -a /root/admin_sshkeys/* /home/${ADMIN_USER_NAME}/.ssh
				chown ${ADMIN_USER_NAME} /home/${ADMIN_USER_NAME}/.ssh/*
				chgrp ${ADMIN_USER_NAME} /home/${ADMIN_USER_NAME}/.ssh/*
				if test "${ADMIN_HOMED}" = "true"; then
					homectl update ${ADMIN_USER_NAME} --ssh-authorized-keys=@/home/${ADMIN_USER_NAME}/.ssh/authorized_keys
					homectl deactivate ${ADMIN_USER_NAME}
				fi
			fi  # copy in ssh keys

			# gnome shell config
			if pacman -Q gnome-shell > /dev/null 2>/dev/null; then
				if test "${KEYMAP}" = "uk"; then
					export GNOME_KEYS=gb
				else
					export GNOME_KEYS="${KEYMAP}"
				fi
    				if pacman -Q gnome-remote-desktop > /dev/null 2>/dev/null -a test "${RDP_SYSTEM}" = "true"; then
					mkdir -p /root/.local/share/gnome-remote-desktop
					winpr-makecert3 -y 50 -rdp -path /root/.local/share/gnome-remote-desktop
					grdctl --system rdp set-tls-key /root/.local/share/gnome-remote-desktop/$(hostname).key
					grdctl --system rdp set-tls-cert /root/.local/share/gnome-remote-desktop/$(hostname).crt
					grdctl --system rdp set-credentials "${ADMIN_USER_NAME}" "${ADMIN_USER_PASSWORD}"
					grdctl --system rdp enable
    				fi
				echo gsettings set org.gnome.desktop.input-sources sources \"[\(\'xkb\',\'\${GNOME_KEYS}\'\)]\" > /tmp/gset
				unset GNOME_KEYS

				echo gsettings set org.gnome.settings-daemon.plugins.power power-button-action interactive >> /tmp/gset
				echo gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing >> /tmp/gset
				sudo -u ${ADMIN_USER_NAME} dbus-launch bash /tmp/gset
				rm /tmp/gset
			fi

			# prevent sleep at greeter
			if pacman -Q gdm > /dev/null 2>/dev/null; then
				sudo -u gdm dbus-launch gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing
			fi

			if test ! -z "${AUR_HELPER}"; then
				if ! pacman -Q ${AUR_HELPER} > /dev/null 2>/dev/null; then
					# just for now, admin user is passwordless for pacman
					echo "${ADMIN_USER_NAME} ALL=(ALL) NOPASSWD: /usr/bin/pacman" > "/etc/sudoers.d/allow_${ADMIN_USER_NAME}_to_pacman"
					# let root cd with sudo
					echo "root ALL=(ALL) CWD=* ALL" > /etc/sudoers.d/permissive_root_Chdir_Spec

					# get helper pkgbuild
					PASSWORD="${ADMIN_USER_PASSWORD}" homectl activate ${ADMIN_USER_NAME}  || true
					sudo -u ${ADMIN_USER_NAME} -D~ bash -c "curl -s -L https://aur.archlinux.org/cgit/aur.git/snapshot/${AUR_HELPER}.tar.gz | bsdtar -xvf -"

					# make and install helper
					PASSWORD="${ADMIN_USER_PASSWORD}" homectl activate ${ADMIN_USER_NAME}  || true
					sudo -u ${ADMIN_USER_NAME} -D~/${AUR_HELPER} bash -c "makepkg -si --noprogressbar --noconfirm --needed"

					# clean up
					PASSWORD="${ADMIN_USER_PASSWORD}" homectl activate ${ADMIN_USER_NAME}  || true
					sudo -u ${ADMIN_USER_NAME} -D~ bash -c "rm -rf ${AUR_HELPER} .cache/go-build .cargo"
					pacman -Qtdq | pacman -Rns - --noconfirm

				homectl deactivate ${ADMIN_USER_NAME} || true
				fi  #get helper

				# backup future makepkg built packages
				sed -i "s,^#PKGDEST=.*,PKGDEST=\${MAKEPKG_BACKUP},g" /etc/makepkg.conf

				if test ! -z "${AUR_PACKAGE_LIST}"; then
					PASSWORD="${ADMIN_USER_PASSWORD}" homectl activate ${ADMIN_USER_NAME}  || true
					sudo -u ${ADMIN_USER_NAME} -D~ bash -c "${AUR_HELPER//-bin} -Syu --removemake yes --needed --noconfirm --noprogressbar ${AUR_PACKAGE_LIST}"
					homectl deactivate ${ADMIN_USER_NAME} || true
				fi

				# use rate-mirrors if we have it
				if pacman -Q rate-mirrors > /dev/null 2>/dev/null; then
					PASSWORD="${ADMIN_USER_PASSWORD}" homectl activate ${ADMIN_USER_NAME}  || true
					sudo -u ${ADMIN_USER_NAME} -D~ bash -c "rate-mirrors arch > /tmp/mirrorlist"
					homectl deactivate ${ADMIN_USER_NAME} || true
					sudo mv /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.old
					sudo mv /tmp/mirrorlist /etc/pacman.d/mirrorlist
				fi

				# enable byobu if we have it
				if pacman -Q byobu > /dev/null 2>/dev/null; then
					PASSWORD="${ADMIN_USER_PASSWORD}" homectl activate ${ADMIN_USER_NAME}  || true
					sudo -u ${ADMIN_USER_NAME} -D~ bash -c "byobu-enable"
					homectl deactivate ${ADMIN_USER_NAME} || true
				fi

				# take away passwordless sudo for pacman for admin
				rm -rf /etc/sudoers.d/allow_${ADMIN_USER_NAME}_to_pacman
			fi  # add AUR
			# now that we have a proper admin user, ensure ssh login for root with password is disabled
			sed 's,^PermitRootLogin .*,#PermitRootLogin prohibit-password,g' -i /etc/ssh/sshd_config
		fi # add admin

		# change password for root
		# note that root will have perminant password ssh login if ROOT_PASSWORD was set
		if test -z "${ROOT_PASSWORD}"; then
			echo "password locked for root user"
			passwd --lock root
			sed 's,^PermitRootLogin .*,#PermitRootLogin prohibit-password,g' -i /etc/ssh/sshd_config
		fi

		fstrim --verbose --all

		rm -f /var/tmp/phase_two_setup_failed
		echo 'Setup phase 2 was successful' | systemd-cat --priority=alert --identifier=p2setup
		exit 0
	EOF
	chmod +x "${TMP_ROOT}/root/phase_two.sh"

	# make changes needed for nspawn
	if test "${SKIP_NSPAWN}" != "true"; then
		# disable PrivateNetwork to allow localectl to work in a container
		sed 's,PrivateNetwork=yes,#PrivateNetwork=yes,g' -i "${TMP_ROOT}"/usr/lib/systemd/system/systemd-localed.service
	fi
fi

# fix hardcoded root kernel param in rpi.org's kernel package
if test -f "${TMP_ROOT}/boot/cmdline.txt"; then
	sed "s,root=[^ ]*,root=PARTUUID=$(lsblk -no PARTUUID ${ROOTA_DEVICE}),g" -i "${TMP_ROOT}/boot/cmdline.txt"
fi

fstrim --verbose --all

# unmount and clean up everything
umount "${TMP_ROOT}/boot" || true
umount -d "${TMP_ROOT}/boot" || true
if test "${ROOT_FS_TYPE}" = "btrfs"; then
	for n in "${TMP_ROOT}"/home/* ; do umount $n || true; done
	for n in "${TMP_ROOT}"/home/* ; do umount -d $n || true; done
	umount "${TMP_ROOT}/home" || true
	umount -d "${TMP_ROOT}/home" || true
fi
umount "${TMP_ROOT}" || true
umount -d "${TMP_ROOT}" || true
cryptsetup close /dev/mapper/${LUKS_UUID} || true
losetup -D || true
sync
if pacman -Q lvm2 > /dev/null 2>/dev/null; then
	pvscan --cache -aay
fi
rm -r "${TMP_ROOT}" || true

set +o xtrace
set +o verbose
echo $'We\'ll now boot into the partially set up system.'
echo 'A one time systemd service will be run to complete the install/setup'
echo 'This could take a while (like if paru needs to be compiled)'
echo $'Nothing much will appear to be taking place but the container will exit once it\'s complete'
set -o xtrace
set -o verbose

# boot into newly created system to perform setup tasks
if test -z "${IMG_NAME}"; then
	SPAWN_TARGET=${TARGET_DEV}
else
	SPAWN_TARGET="${IMG_NAME}"
fi

if test "${SKIP_NSPAWN}" != "true"; then
	# as of systemd-253, this will fail unless https://github.com/systemd/systemd/pull/28954 is applied
	systemd-nspawn --link-journal=host --boot --image "${SPAWN_TARGET}" init --log-level=debug
fi

if test -n "${ADMIN_SSH_AUTH_KEY}"; then
	set +o xtrace
	set +o verbose
	echo 'If you need to ssh into the system, you can find the keypair you must use in /root/admin_sshkeys'
fi

set +o xtrace
set +o verbose
cat <<- EOF
	Done!
	You can now boot into the new system with (change the network device in the commands below if needed)
	sudo systemd-nspawn --link-journal=host --network-macvlan=eno1 --network-veth --boot --image "${SPAWN_TARGET}"
	or you can can "chroot" into it with
	sudo systemd-nspawn --link-journal=host --network-macvlan=eno1 --network-veth --image "${SPAWN_TARGET}"
	You might want to inspect the journal to see how the setup went
	The presence/absence of the files
	/var/tmp/phase_two_setup_failed
	/var/tmp/phase_one_setup_failed
	/root/phase_one.sh
	/root/phase_two.sh
	might also give you hints about how things went.


	If things didn't work out, here are some recovery stratiges:
	1) use systemd-nspawn to chroot as above
	2) set a password for root with: "passwd root"
	3) exit the chroot
	4) boot into rescue mode with systemd-nspawn like this:
	sudo systemd-nspawn --link-journal=host --network-veth --boot --image "${SPAWN_TARGET}" -- --unit rescue.target
EOF
