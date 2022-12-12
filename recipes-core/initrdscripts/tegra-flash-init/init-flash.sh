#!/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin
mount -t proc proc -o nosuid,nodev,noexec /proc
mount -t devtmpfs none -o nosuid /dev
mount -t sysfs sysfs -o nosuid,nodev,noexec /sys
mount -t configfs configfs -o nosuid,nodev,noexec /sys/kernel/config

[ ! /usr/sbin/wd_keepalive ] || /usr/sbin/wd_keepalive &

for bootarg in $(cat /proc/cmdline); do
    case "$bootarg" in
	l4tflash.bootdev=*) export ROOTFS_DEVICE="${bootarg##l4tflash.bootdev=}" ;;
    esac
done

if [ -z "$ROOTFS_DEVICE" ]; then
    echo "ERR: missing l4tflash.bootdev setting in kernel command line" >&2
    exec sh
fi
if [ ! -b "$ROOTFS_DEVICE" ]; then
    echo "ERR: not a block device: $ROOTFS_DEVICE" >&2
    exec sh
fi

if ! blkdiscard -f "$ROOTFS_DEVICE"; then
    echo "ERR: could not clear $ROOTFS_DEVICE" >&2
    exec sh
fi

if /usr/bin/l4t-gadget-config-setup l4t-initrd-flashing ROOTFS_DEVICE; then
    /usr/bin/gadget-start
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
    echo "Rebooting..."
    reboot -f
else
    echo "ERR: could not set up USB gadget for $ROOTFS_DEVICE" >&2
fi
exec sh
