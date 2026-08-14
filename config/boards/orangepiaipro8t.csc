# Huawei Ascend 310B / Orange Pi AI Pro 8T, 8TOPS NPU, eMMC, PCIe, USB3
declare -g BOARD_NAME="Orange Pi AI Pro 8T"
declare -g BOARD_VENDOR="xunlong"
declare -g BOARD_MAINTAINER="eWloYW8,yoolc"
declare -g BOARDFAMILY="ascend310b"
declare -g KERNEL_TARGET="current,legacy"
declare -g KERNEL_TEST_TARGET="current"
declare -g BOOTCONFIG="ascend310b_hboot2_defconfig"
declare -g IMAGE_PARTITION_TABLE="gpt"
declare -g BOOT_FDT_FILE="hi1910b/hi1910B-orangepiaipro8t.dtb"
declare -g SRC_EXTLINUX="yes"
declare -g OFFSET=32
declare -g BOOTSIZE=0
