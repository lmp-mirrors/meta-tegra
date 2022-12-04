#!/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin
mount -t proc proc -o nosuid,nodev,noexec /proc
mount -t devtmpfs none -o nosuid /dev
mount -t sysfs sysfs -o nosuid,nodev,noexec /sys
mount -t efivarfs efivarfs -o nosuid,nodev,noexec /sys/firmware/efi/efivars

[ ! /usr/sbin/wd_keepalive ] || /usr/sbin/wd_keepalive &

exec sh
