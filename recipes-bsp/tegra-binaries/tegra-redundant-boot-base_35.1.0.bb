DESCRIPTION = "L4T bootloader update support tools"
L4T_DEB_COPYRIGHT_MD5 = "fe65a18c0cbf70d19e3d6202a8c825b6"

L4T_DEB_TRANSLATED_BPN = "nvidia-l4t-tools"

require tegra-debian-libraries-common.inc

MAINSUM = "8e4d140cdcd3349e93cc28d87e0e0c61dd091f9535f1e022812ecb0fe5e00bb2"

do_install() {
	install -d ${D}${sbindir}
	install -m 0755 ${S}/usr/sbin/nvbootctrl ${D}${sbindir}
	install -m 0755 ${S}/usr/sbin/nv_bootloader_payload_updater ${D}${sbindir}
	install -m 0755 ${S}/usr/sbin/nv_update_engine ${D}${sbindir}
	install -d ${D}/opt/ota_package
}

PACKAGES = "tegra-redundant-boot-nvbootctrl ${PN} ${PN}-dev"
FILES:tegra-redundant-boot-nvbootctrl = "${sbindir}/nvbootctrl"
FILES:${PN} += "/opt/ota_package"
RDEPENDS:${PN} = "tegra-redundant-boot-nvbootctrl setup-nv-boot-control-service tegra-configs-bootloader util-linux-lsblk"
INSANE_SKIP:${PN} = "ldflags"
RDEPENDS:tegra-redundant-boot-nvbootctrl = "setup-nv-boot-control"
INSANE_SKIP:tegra-redundant-boot-nvbootctrl = "ldflags"
