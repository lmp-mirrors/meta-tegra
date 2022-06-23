CUDA_PKG = "cuda-nvcc"

require cuda-shared-binaries.inc

L4T_DEB_GROUP = "cuda-nvcc"
COMPATIBLE_HOST:x86-64 = "(-)"
MAINSUM = "d30ff7c5fe0ef8c2394f433147cf447b12f3f8cf86f1e888a76429a56e88478a"

do_install:append() {
    for d in bin lib nvvm nvvmx; do
        rm -rf ${D}${prefix}/local/cuda-${CUDA_VERSION}/$d
    done
}

CONTAINER_CSV_FILES = ""
CONTAINER_CSV_PKGNAME = ""
FILES:${PN} = "${prefix}/local/cuda-${CUDA_VERSION}/include"
FILES:${PN}-dev = ""

BBCLASSEXTEND = "native nativesdk"
