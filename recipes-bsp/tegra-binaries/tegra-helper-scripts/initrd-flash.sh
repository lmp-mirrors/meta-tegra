#!/bin/bash

here=$(readlink -f $(dirname "$0"))

declare -A DEFAULTS

usage() {
    cat <<EOF
Insert help text here
EOF
}

if [ ! -e .env.initrd-flash ]; then
    echo "Missing environment settings" >&2
    exit 1
fi

. .env.initrd-flash


PRESIGNED=
if [ -e .presigning-vars ]; then
    . .presigning-vars
    PRESIGNED=yes
fi

usb_instance=
user_keyfile=
keyfile=
sbk_keyfile=
skip_bootloader=0

ARGS=$(getopt -n $(basename "$0") -l "usb-instance:,user_key:,help,skip-bootloader" -o "u:v:h" -- "$@")
if [ $? -ne 0 ]; then
    usage >&2
    exit 1
fi
eval set -- "$ARGS"
unset ARGS

while true; do
    case "$1" in
	--usb-instance)
	    usb_instance="$2"
	    shift 2
	    ;;
	--user_key)
	    user_keyfile="$2"
	    shift 2
	    ;;
	--skip-bootloader)
	    skip_bootloader=1
	    shift
	    ;;
	-u)
	    keyfile="$2"
	    shift 2
	    ;;
	-v)
	    sbk_keyfile="$2"
	    shift 2
	    ;;
	-h|--help)
	    usage
	    exit 0
	    ;;
	--)
	    shift
	    break
	    ;;
	*)
	    echo "Error processing options" >&2
	    exit 1
	    ;;
    esac
done

have_odmsign_func=0
if [ -e "$here/odmsign.func" ]; then
    have_odmsign_func=1
fi
if [ -n "$PRESIGNED" ]; then
    if [ -n "$user_keyfile" -o -n "$keyfile" -o -n "$sbk_keyfile" ]; then
	echo "WARN: binaries already signed; ignoring signing options" >&2
	user_keyfile=
	keyfile=
	sbk_keyfile=
    fi
elif [ -n "$keyfile" -o -n "$sbk_keyfile" -o -n "$user_keyfile" ] && [ $have_odmsign_func -eq 0 ]; then
    echo "ERR: missing odmsign.func from secureboot package, cannot sign binaries" >&2
    exit 1
fi

wait_for_rcm() {
    "$here/find-jetson-usb" --wait "$usb_instance"
}

copy_signed_binaries() {
    local signdir="${1:-signed}"
    local xmlfile="${2:-flash.xml.tmp}"
    local destdir="${3:-.}"
    local blksize partnumber partname partsize partfile partguid parttype partfilltoend
    local line

    while read line; do
	eval "$line"
	[ -n "$partfile" ] || continue
	if [ ! -e "$signdir/$partfile" ]; then
	    if [ ! -e "$destdir/$partfile" ] && ! echo "$partfile" | grep -q "FILE"; then
		echo "ERR: could not copy $partfile from $signdir" >&2
		return 1
	    fi
	else
	    cp "$signdir/$partfile" "$destdir"
	fi
    done < <("$here/nvflashxmlparse" -t boot "$signdir/$xmlfile"; "$here/nvflashxmlparse" -t rootfs "$signdir/$xmlfile")
}

sign_binaries() {
    if [ -n "$PRESIGNED" ]; then
	if ! copy_bootloader_files bootloader_staging; then
	    return 1
	fi
	return 0
    fi
    if [ -z "$BOARDID" -o -z "$FAB" ]; then
	wait_for_rcm
    fi
    local flashin="flash.xml.in"
    MACHINE=$MACHINE BOARDID=$BOARDID FAB=$FAB BOARDSKU=$BOARDSKU BOARDREV=$BOARDREV CHIPREV=$CHIPREV fuselevel=$fuselevel \
	   "$here/$FLASH_HELPER" --no-flash --sign -u "$keyfile" -v "$sbk_keyfile" --user_key "$user_keyfile" \
	   $flashin $DTBFILE $EMMC_BCTS $ODMDATA $LNXFILE $ROOTFS_IMAGE
    if [ $have_odmsign_func -eq 0 ]; then
	cp signed/flash.xml.tmp secureflash.xml
	cp signed/flash.idx flash.idx
	copy_signed_binaries
    else
	cp flashcmd.txt doflash.sh
    fi
    if ! copy_bootloader_files bootloader_staging; then
	return 1
    fi
    . ./boardvars.sh
    if [ $EXTERNAL_ROOTFS_DRIVE -eq 1 ]; then
	MACHINE=$MACHINE BOARDID=$BOARDID FAB=$FAB BOARDSKU=$BOARDSKU BOARDREV=$BOARDREV CHIPREV=$CHIPREV fuselevel=$fuselevel \
	       "$here/$FLASH_HELPER" --external-device --no-flash --sign -u "$keyfile" -v "$sbk_keyfile" --user_key "$user_keyfile" \
	       external-flash.xml.in $DTBFILE $EMMC_BCTS $ODMDATA $LNXFILE $ROOTFS_IMAGE
	if [ $have_odmsign_func -eq 0 ]; then
	    if [ -e signed/flash.xml.tmp ]; then
		cp signed/flash.xml.tmp external-secureflash.xml
		copy_signed_binaries
	    else
		cp flash.xml external-secureflash.xml
	    fi
	fi
    fi
}

prepare_for_rcm_boot() {
    if [ $have_odmsign_func -eq 1 ]; then
	"$here/rewrite-tegraflash-args" -o rcm-boot.sh --bins kernel=initrd-flash.img,kernel_dtb=kernel_$DTBFILE --cmd rcmboot --add="--securedev" doflash.sh
	# For t234: hack taken from odmsign.func
	sed -i -e's,mb2_t234_with_mb2_bct_MB2,mb2_t234_with_mb2_cold_boot_bct_MB2,' rcm-boot.sh
	chmod +x rcm-boot.sh
    fi
}

run_rcm_boot() {
    if [ $have_odmsign_func -eq 1 ]; then
	./rcm_boot.sh
    else
	MACHINE=$MACHINE BOARDID=$BOARDID FAB=$FAB BOARDSKU=$BOARDSKU BOARDREV=$BOARDREV CHIPREV=$CHIPREV fuselevel=$fuselevel \
	       "$here/$FLASH_HELPER" --rcm-boot -u "$keyfile" -v "$sbk_keyfile" --user_key "$user_keyfile" \
	       flash.xml.in $DTBFILE $EMMC_BCTS $ODMDATA initrd-flash.img $ROOTFS_IMAGE
    fi
}

mount_partition() {
    local dev="$1"
    if udisksctl mount -b "$dev" > /dev/null; then
	cat /proc/mounts | grep "^$dev" | cut -d' ' -f2
	return 0
    fi
    echo ""
    return 1
}

unmount_and_release() {
    local mnt="$1"
    local dev="$2"
    if [ -n "$mnt" ]; then
	if ! umount "$1"; then
	    udisksctl unmount -b "$dev"
	fi
    fi
    udisksctl power-off -b "$dev"
}

wait_for_usb_storage() {
    local sessid="$1"
    local name="$2"
    local count=0
    local output candidate cand_model cand_vendor

    echo -n "Waiting for USB storage device $name from $sessid..." >&2
    while [ -z "$output" ]; do
	for candidate in /dev/sd[a-z]; do
	    [ -b "$candidate" ] || continue
	    cand_model=$(udevadm info --query=property $candidate | grep '^ID_MODEL=' | cut -d= -f2)
	    if [ "$cand_model" = "$sessid" ]; then
		cand_vendor=$(udevadm info --query=property $candidate | grep '^ID_VENDOR=' | cut -d= -f2)
		if [ "$cand_vendor" = "$name" ]; then
		    echo "[$candidate]" >&2
		    output="$candidate"
		    break
		fi
	    fi
	done
	if [ -z "$output" ]; then
	    sleep 1
	    count=$(expr $count \+ 1)
	    if [ $count -ge 5 ]; then
		echo -n "." >&2
		count=0
	    fi
	fi
    done
    echo "$output"
}

copy_bootloader_files() {
    local dest="$1"
    local partnumber partloc partname start_location partsize partfile partattrs partsha
    local devnum instnum
    local is_spi is_mmcboot
    rm -f "$dest/partitions.conf"
    while IFS=", " read partnumber partloc start_location partsize partfile partattrs partsha; do
	# Need to trim off leading blanks
	devnum=$(echo "$partloc" | cut -d':' -f 1)
	instnum=$(echo "$partloc" | cut -d':' -f 2)
	partname=$(echo "$partloc" | cut -d':' -f 3)
	# SPI is 3:0
	# eMMC boot blocks (boot0/boot1) are 0:3
	# eMMC user is 1:3
	# NVMe (any external device) is 9:0
	if [ $devnum -eq 3 -a $instnum -eq 0 ] || [ $devnum -eq 0 -a $instnum -eq 3 ]; then
	    if [ -n "$partfile" ]; then
		cp "$partfile" "$dest/"
	    fi
	    if [ $devnum -eq 3 -a $instnum -eq 0 ]; then
		is_spi=yes
	    elif [ $devnum -eq 0 -a $instnum -eq 3 ]; then
		is_mmcboot=yes
	    fi
	    echo "$partname:$start_location:$partsize:$partfile" >> "$dest/partitions.conf"
	fi
    done < flash.idx
    if [ -n "$is_spi" ]; then
	if [ -n "$is_mmcboot" ]; then
	    echo "ERR: found bootloader entries for both SPI flash and eMMC boot partitions" >&2
	    return 1
	fi
	echo "spi" > "$dest/boot_device_type"
    elif [ -n "$is_mmcboot" ]; then
	echo "mmcboot" > "$dest/boot_device_type"
    else
	echo "ERR: no SPI or eMMC boot partition entries found" >&2
	return 1
    fi
    return 0
}

generate_flash_package() {
    local dev=$(wait_for_usb_storage "$session_id" "blpkg")
    local exports

    if [ -z "$dev" ]; then
	echo "ERR: could not locate USB storage device for sending flashing commands" >&2
	return 1
    fi
    local devsize=$(cat /sys/block/$(basename $dev)/size 2>/dev/null)
    echo "Device size in blocks: $devsize" >&2
    local mnt=$(mount_partition "$dev")
    if [ -z "$mnt" ]; then
	echo "ERR: could not mount USB storage for writing flashing commands" >&2
	return 1
    fi
    mkdir "$mnt/flashpkg/conf"
    if [ $EXTERNAL_ROOTFS_DRIVE -eq 1 -a $BOOT_PARTITIONS_ON_EMMC -eq 1 ]; then
	exports="export-devices mmcblk0 $ROOTFS_DEVICE;"
    else
	exports="export-devices $ROOTFS_DEVICE;"
	[ $EXTERNAL_ROOTFS_DRIVE -eq 0 ] || exports="erase-mmc;${exports}"
    fi
    local command_sequence
    if [ $skip_bootloader -eq 0 ]; then
	command_sequence="bootloader;${exports}reboot"
    else
	command_sequence="${exports}reboot"
    fi
    echo "$command_sequence" > "$mnt/flashpkg/conf/command_sequence"
    echo "Flash command sequence: $command_sequence"
    mkdir "$mnt/flashpkg/bootloader"
    cp bootloader_staging/* "$mnt/flashpkg/bootloader"
    unmount_and_release "$mnt" "$dev"
}

write_to_device() {
    local devname="$1"
    local flashlayout="$2"
    local dev=$(wait_for_usb_storage "$session_id" "$devname")
    local opts="$3"
    local rewritefiles="secureflash.xml"
    local datased
    if [ -z "$dev" ]; then
	echo "ERR: could not find $devname" >&2
	return 1
    fi
    if [ -e external-secureflash.xml ]; then
	rewritefiles="external-secureflash.xml,$rewritefiles"
    fi
    "$here/nvflashxmlparse" --rewrite-contents-from=$rewritefiles -o initrd-flash.xml "$flashlayout"
    if [ -n "$DATAFILE" ]; then
	datased="-es,DATAFILE,$DATAFILE,"
    else
	datased="-e/DATAFILE/d"
    fi
    sed -i -e"s,APPFILE_b,$ROOTFS_IMAGE," -e"s,APPFILE,$ROOTFS_IMAGE," $datased initrd-flash.xml
    "$here/make-sdcard" -y $opts initrd-flash.xml "$dev"
    unmount_and_release "" "$dev"
}

get_final_status() {
    local dtstamp="$1"
    local dev=$(wait_for_usb_storage "$session_id" "blpkg")
    local mnt final_status logdir logfile
    if [ -z "$dev" ]; then
	echo "ERR: could not get final status from device" >&2
	return 1
    fi
    mnt=$(mount_partition "$dev")
    if [ -z "$mnt" ]; then
	echo "ERR: could not mount USB device to get final status from device" >&2
	return 1
    fi
    final_status=$(cat $mnt/flashpkg/status)
    if [ -d "$mnt/flashpkg/logs" ]; then
	logdir="device-logs-$dtstamp"
	if [ -d "$logdir" ]; then
	    echo "Logs directory $logdir already exists, replacing" >&2
	    rm -rf "$logdir"
	fi
	mkdir "$logdir"
	for logfile in "$mnt"/flashpkg/logs/*; do
	    [ -f "$logfile" ] || continue
	    cp -v "$logfile" "$logdir/"
	done
    fi
    unmount_and_release "$mnt" "$dev"
    echo "Final status: $final_status"
    return 0
}

dtstamp=$(date +"%Y-%m-%d-%H.%M.%S")
logfile="log.initrd-flash.$dtstamp"
echo "Starting at $(date -Is)" | tee "$logfile"
if ! wait_for_rcm 2>&1 | tee -a "$logfile"; then
    echo "ERR: Device not found at $(date -Is)" | tee -a "$logfile"
    exit 1
fi
echo "Step 1: Sign binaries"
rm -rf bootloader_staging
mkdir bootloader_staging
if ! sign_binaries 2>&1 >>"$logfile"; then
    echo "ERR: signing failed at $(date -Is)"  | tee -a "$logfile"
    exit 1
fi
if [ -z "$PRESIGNED" ]; then
    [ ! -f ./boardvars.sh ] || . ./boardvars.sh
fi
echo "Step 2: Boot Jetson via RCM"
if ! wait_for_rcm 2>&1 | tee -a "$logfile"; then
    echo "ERR: Device not found at $(date -Is)" | tee -a "$logfile"
    exit 1
fi
if ! run_rcm_boot 2>&1 >>"$logfile"; then
    echo "ERR: RCM boot failed at $(date -Is)" | tee -a "$logfile"
    exit 1
fi
[ ! -f ./boardvars.sh ] || . ./boardvars.sh

if [ -z "$BR_CID" ]; then
    echo "ERR: did not get unique ID at $(date -Is)" | tee -a "$logfile"
    exit 1
fi

session_id=$("$here/brcid-to-uid" $BR_CID)
session_id=$(echo -n "$session_id" | tail -c8)

# Boot device flashing
echo "Step 3: Send flash sequence commands"
if ! generate_flash_package 2>&1 | tee -a "$logfile"; then
    echo "ERR: could not create command package at $(date -Is)" | tee -a "$logfile"
    exit 1
fi
echo "Step 4: format and write storage device(s)"
if [ $EXTERNAL_ROOTFS_DRIVE -eq 1 ]; then
    if [ $BOOT_PARTITIONS_ON_EMMC -eq 1 ]; then
	echo "  -- writing boot partitions to internal storage device"
	if ! write_to_device mmcblk0 flash.xml.in --no-final-part 2>&1 | tee -a "$logfile"; then
	    echo "ERR: write failure to internal storage at $(date -Is)" | tee -a "$logfile"
	    exit 1
	fi
    fi
    echo "  -- writing partitions to external storage device"
    if ! write_to_device $ROOTFS_DEVICE external-flash.xml.in 2>&1 | tee -a "$logfile"; then
	echo "ERR: write failure to external storage at $(date -Is)" | tee -a "$logfile"
	exit 1
    fi
else
    echo " -- writing to internal storage device"
    if ! write_to_device $ROOTFS_DEVICE flash.xml.in 2>&1 | tee -a "$logfile"; then
	echo "ERR: write failure to internal storage at $(date -Is)" | tee -a "$logfile"
	exit 1
    fi
fi
echo "Step 5: Wait for final status from device (please be patient)"
if ! get_final_status "$dtstamp" 2>&1 | tee -a "$logfile"; then
    echo "ERR: failed to retrieve device status at $(date -Is)" | tee -a "$logfile"
    exit 1
fi
echo "Successfully finished at $(date -Is)" | tee -a "$logfile"
exit 0
