# put-arch-onto-disk

This repo contains a script which creates a bootable (BIOS, non-UEFI at the moment) disk image based on the latest Arch Linux and then optionally uses dd to write it to a disk. The indended use is for creating bootable USB flash drives, so the default root file system is F2FS, although that is configurable (like many other things).

### Requirements
1. Be running Arch Linux
1. `sudo pacman -S --needed util-linux coreutils gptfdisk f2fs-tools e2fsprogs btrfs-progs arch-install-scripts procps-ng sed`
1. Understand that the script provided here comes with no guarentees that it won't destroy your computer and everything attached to it :-)

### Usage

1. First examine the top of the `put-arch-onto-disk.sh` scipt to make sure you understand what the defaults are (they should be safe, since there is no DDing by default).
1. Then define the appropriate environment variables to override the defaults and call the script.

### Example

For a useful install onto a USB flash drive at /dev/sdz:
```
TARGET_DISK=/dev/sdz DD_TO_TARGET=true CLEAN_UP=true USE_TARGET_DISK=true PACKAGE_LIST="base-devel f2fs-tools networkmanager bash-completion sudo vim grub efibootmgr btrfs-progs arch-install-scripts fuse dosfstools os-prober mtools freetype2 fuse dialog ifplugd wpa_actiond mkinitcpio-nfs-utils linux-atm libmicrohttpd openssh fail2ban" ./put-arch-onto-disk.sh
```
You'll be prompted for your sudo password.
