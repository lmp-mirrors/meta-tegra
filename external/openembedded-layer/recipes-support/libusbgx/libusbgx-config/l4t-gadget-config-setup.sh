#!/bin/sh
[ -d /run/usbgx ] || mkdir /run/usbgx
[ ! -e /run/usbgx/l4t.schema ] || exit 0
SCHEMENAME=${1:-l4t}
shift
if [ ! -e /usr/share/usbgx/$SCHEMENAME.schema.in ]; then
    echo "ERR: missing gadget schema template for $SCHEMENAME" >&2
    exit 1
fi
sernum=$(cat /proc/device-tree/serial-number 2>/dev/null | tr -d '\000')
[ -n "$sernum" ] || sernum="UNKNOWN"
sed_args=
for varname in "$@"; do
    val=$(eval echo \$$varname)
    sed_args="${sed_args} -es,@${varname}@,$val,"
done
sed -e"s,@SERIALNUMBER@,$sernum," $sed_args /usr/share/usbgx/$SCHEMENAME.schema.in > /run/usbgx/l4t.schema
chmod 0644 /run/usbgx/l4t.schema
