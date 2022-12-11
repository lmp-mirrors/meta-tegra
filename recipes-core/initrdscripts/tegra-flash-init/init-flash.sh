#!/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin
mount -t proc proc -o nosuid,nodev,noexec /proc
mount -t devtmpfs none -o nosuid /dev
mount -t sysfs sysfs -o nosuid,nodev,noexec /sys
#mount -t efivarfs efivarfs -o nosuid,nodev,noexec /sys/firmware/efi/efivars
mount -t configfs configfs -o nosuid,nodev,noexec /sys/kernel/config

[ ! /usr/sbin/wd_keepalive ] || /usr/sbin/wd_keepalive &

dd if=/dev/zero of=/tmp/dummy.disk bs=512 count=32
if INITRD_FLASH_DUMMY=/tmp/dummy.disk ROOTFS_DEVICE=/dev/nvme0n1 /usr/bin/l4t-gadget-config-setup l4t-initrd-flashing INITRD_FLASH_DUMMY ROOTFS_DEVICE; then
    /usr/bin/gadget-start
fi

exec sh
