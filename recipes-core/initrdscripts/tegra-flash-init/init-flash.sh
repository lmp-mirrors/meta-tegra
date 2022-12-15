#!/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin
mount -t proc proc -o nosuid,nodev,noexec /proc
mount -t devtmpfs none -o nosuid /dev
mount -t sysfs sysfs -o nosuid,nodev,noexec /sys
mount -t configfs configfs -o nosuid,nodev,noexec /sys/kernel/config

[ ! /usr/sbin/wd_keepalive ] || /usr/sbin/wd_keepalive &

reboot_recovery=
erase_mmcblk0=
for bootarg in $(cat /proc/cmdline); do
    case "$bootarg" in
	l4tflash.bootdev=*) export ROOTFS_DEVICE="${bootarg##l4tflash.bootdev=}" ;;
	l4tflash.reboot-recovery) reboot_recovery=yes ;;
	l4tflash.erase-mmcblk0)  erase_mmcblk0=yes ;;
    esac
done

if [ -z "$ROOTFS_DEVICE" ]; then
    echo "ERR: missing l4tflash.bootdev setting in kernel command line" >&2
    exec sh
fi
message="Waiting for $ROOTFS_DEVICE..."
for tries in $(seq 1 15); do
    if [ -e "$ROOTFS_DEVICE" ]; then
	echo "[OK]"
	break
    fi
    echo -n "$message"
    message="."
    sleep 1
done
if [ $tries -ge 15 ]; then
    echo "[FAIL]"
    exec sh
fi
if [ ! -b "$ROOTFS_DEVICE" ]; then
    echo "ERR: not a block device: $ROOTFS_DEVICE" >&2
    exec sh
fi

if [ -n "$erase_mmcblk0" -a -b /dev/mmcblk0 ]; then
    echo "Erasing /dev/mmcblk0"
    blkdiscard -f /dev/mmcblk0
fi

if /usr/bin/l4t-gadget-config-setup l4t-initrd-flashing ROOTFS_DEVICE; then
    /usr/bin/gadget-start
    if [ -e /sys/class/usb_role/usb2-0-role-switch/role ]; then
	echo "device" > /sys/class/usb_role/usb2-0-role-switch/role
    fi
    udcname=$(cat /sys/kernel/config/usb_gadget/l4t/UDC)
    echo -n "Waiting for host to connect..."
    while true; do
	suspended=$(expr $(cat /sys/class/udc/$udcname/device/gadget/suspended) \+ 0)
	if [ $suspended -eq 0 ]; then
	    echo "[connected]"
	    break
	fi
	sleep 1
	echo -n "."
    done
    echo -n "Waiting for host to disconnect..."
    while true; do
	suspended=$(expr $(cat /sys/class/udc/$udcname/device/gadget/suspended) \+ 0)
	if [ $suspended -eq 1 ]; then
	    echo "[disconnected]"
	    break
	fi
	sleep 5
	echo -n "."
    done
    sync
    if [ -n "$reboot_recovery" ]; then
	echo "Rebooting to RCM..."
	reboot-recovery
    else
	echo "Rebooting..."
	reboot -f
    fi
else
    echo "ERR: could not set up USB gadget for $ROOTFS_DEVICE" >&2
fi
exec sh
