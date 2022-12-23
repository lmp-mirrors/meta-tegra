#!/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin
mount -t proc proc -o nosuid,nodev,noexec /proc
mount -t devtmpfs none -o nosuid /dev
mount -t sysfs sysfs -o nosuid,nodev,noexec /sys
mount -t configfs configfs -o nosuid,nodev,noexec /sys/kernel/config

[ ! /usr/sbin/wd_keepalive ] || /usr/sbin/wd_keepalive &
[ -d /run/usbgx ] || mkdir /run/usbgx
sernum=$(cat /sys/devices/platform/efuse-burn/ecid 2>/dev/null)
[ -n "$sernum" ] || sernum=$(cat /sys/module/tegra_fuse/tegra_chip_uid 2>/dev/null)
if [ -n "$sernum" ]; then
    # Restricted to 8 characters for the ID_VENDOR tag
    sernum=$(printf "%x" "$sernum" | tail -c8)
fi
[ -n "$sernum" ] || sernum="UNKNOWN"
UDC=$(ls -1 /sys/class/udc | head -n 1)

wait_for_storage() {
    local file_or_dev="$1"
    local message="Waiting for $file_or_dev..."
    local tries
    for tries in $(seq 1 15); do
	if [ -e "$file_or_dev" ]; then
	    if [ "$message" = "." ]; then
		echo "[OK]"
	    else
		echo "Found $file_or_dev"
	    fi
	    break
	fi
	echo -n "$message"
	message="."
	sleep 1
    done
    if [ $tries -ge 15 ]; then
	echo "[FAIL]"
	return 1
    fi
    return 0
}

setup_usb_export() {
    local storage_export="$1"
    local export_name="$2"
    wait_for_storage "$storage_export" || return 1
    if [ -e /sys/kernel/config/usb_gadget/l4t ]; then
	gadget-vid-pid-remove 1d6b:104
    fi
    sed -e"s,@SERIALNUMBER@,$sernum," -e"s,@STORAGE_EXPORT@,$storage_export," /usr/share/usbgx/l4t-initrd-flashing.schema.in > /run/usbgx/l4t.schema
    chmod 0644 /run/usbgx/l4t.schema
    gadget-import l4t /run/usbgx/l4t.schema
    printf "%-8s%-16s" "$export_name" "$sernum" > /sys/kernel/config/usb_gadget/l4t/functions/mass_storage.l4t_storage/lun.0/inquiry_string
    echo "$UDC" > /sys/kernel/config/usb_gadget/l4t/UDC
    if [ -e /sys/class/usb_role/usb2-0-role-switch/role ]; then
	echo "device" > /sys/class/usb_role/usb2-0-role-switch/role
    fi
    echo "Exported $storage_export as $export_name"
}

wait_for_connect() {
    local suspended
    local count=0
    echo -n "Waiting for host to connect..."
    while true; do
	suspended=$(expr $(cat /sys/class/udc/$UDC/device/gadget/suspended) \+ 0)
	if [ $suspended -eq 0 ]; then
	    echo "[connected]"
	    break
	fi
	sleep 1
	count=$(expr $count \+ 1)
	if [ $count -ge 5 ]; then
	    echo -n "."
	    count=0
	fi
    done
}

wait_for_disconnect() {
    local suspended
    local count=0
    echo -n "Waiting for host to disconnect..."
    while true; do
	suspended=$(expr $(cat /sys/class/udc/$UDC/device/gadget/suspended) \+ 0)
	if [ $suspended -eq 1 ]; then
	    echo "[disconnected]"
	    break
	fi
	sleep 1
	count=$(expr $count \+ 1)
	if [ $count -ge 5 ]; then
	    echo -n "."
	    count=0
	fi
    done
    echo "" > /sys/kernel/config/usb_gadget/l4t/UDC
}

get_flash_package() {
    rm -rf /tmp/blpkg_tree
    mkdir -p /tmp/blpkg_tree/flashpkg/logs
    chmod 777 /tmp/blpkg_tree/flashpkg
    echo "PENDING: expecting command sequence from host" > /tmp/blpkg_tree/flashpkg/status
    dd if=/dev/zero of=/tmp/blpkg.ext4 bs=1M count=128
    mke2fs -t ext4 -d /tmp/blpkg_tree /tmp/blpkg.ext4
    setup_usb_export /tmp/blpkg.ext4 blpkg || return 1
    wait_for_connect || return 1
    wait_for_disconnect || return 1
}

process_bootloader_package() {
    program-boot-device /tmp/blpkg/flashpkg/bootloader
}


if ! get_flash_package; then
    exec sh
fi

mkdir -p /tmp/blpkg
mount -t ext4 /tmp/blpkg.ext4 /tmp/blpkg

if [ ! -e /tmp/blpkg/flashpkg/conf/command_sequence ]; then
    echo "No command sequence in flash package, nothing to do"
    commands_to_run="reboot"
else
    commands_to_run=$(cat /tmp/blpkg/flashpkg/conf/command_sequence)
fi
PIDS=
while [ -n "$commands_to_run" ]; do
    this_command=$(echo "$commands_to_run" | cut -d';' -f 1)
    trimlen=$(expr ${#this_command} \+ 2)
    commands_to_run=$(echo "${commands_to_run}" | tail -c +$trimlen)
    cmd=$(echo "$this_command" | cut -d' ' -f 1)
    cmdlen=$(expr ${#cmd} \+ 1)
    args=$(echo "${this_command}" | tail -c +$cmdlen | sed -e's,^[[:space:]]*,,')
    case "$cmd" in
	bootloader)
	    process_bootloader_package 2>&1 > /tmp/blpkg/flashpkg/logs/bootloader.log &
	    PIDS="$PIDS $!"
	    ;;
	erase-mmc)
	    if [ -b /dev/mmcblk0 ]; then
		blkdiscard -f /dev/mmcblk0 2>&1 > /tmp/blpkg/flashpkg/logs/erase-mmc.log
	    else
		echo "/dev/mmcblk0 does not exist, skipping" > /tmp/blpkg/flashpkg/logs/erase-mmc.log
	    fi
	    ;;
	export-devices)
	    for dev in $args; do
		setup_usb_export /dev/$dev $dev 2>&1 > /tmp/blpkg/flashpkg/logs/export-$dev.log
		wait_for_connect 2>&1 >> /tmp/blpkg/flashpkg/logs/export-$dev.log
		wait_for_disconnect 2>&1 >> /tmp/blpkg/flashpkg/logs/export-$dev.log
	    done
	    ;;
	reboot)
	    if [ -n "$PIDS" ]; then
		echo "Waiting for background jobs to finish..."
		wait $PIDS
	    fi
	    echo "COMPLETE: reboot $args" > /tmp/blpkg/flashpkg/status
	    umount /tmp/blpkg && setup_usb_export /tmp/blpkg.ext4 blpkg && wait_for_connect && wait_for_disconnect

	    if [ "$args" = "forced-recovery" ]; then
		reboot-recovery
	    else
		reboot -f
	    fi
	    ;;
	*)
	    echo "Unrecognized command: $cmd $args" >&2
	    ;;
    esac

done

# Should never break out of the above loop
exec sh
