#!/usr/bin/env bash

# 构建 Debian RISC-V 镜像（单分区方案：/boot 位于根文件系统内）
# 适用于支持 ext4 启动的设备（如 Orange Pi RV2 + U-Boot）

set -euo pipefail

# --- 用户可配置变量 ---
MODEL=${MODEL:-orangepi-rv2}
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ROOT_IMG=debian-${MODEL}-${TIMESTAMP}.img

DIST="trixie"
BOARD="orangepi-rv2"

BASE_TOOLS="binutils file tree sudo bash-completion u-boot-menu initramfs-tools openssh-server network-manager dnsmasq-base libpam-systemd ppp wireless-regdb wpasupplicant libengine-pkcs11-openssl iptables systemd-timesyncd vim usbutils libgles2 parted pciutils wget"
ADDONS="initramfs-tools "

CHROOT_TARGET="rootfs"

# --- 函数定义 ---

machine_info() {
    echo "--- 显示构建环境信息 ---"
    uname -a
    echo "CPU核心数: $(nproc)"
    lscpu
    whoami
    env | head -n 10
    fdisk -l | head -n 20
    df -h
    echo "--------------------------"
}

init() {
    echo "--- 1. 初始化环境和镜像文件 ---"
    mkdir -p rootfs
    apt update
    echo "创建 8GB 大小的镜像文件: $ROOT_IMG"
    fallocate -l 8G "$ROOT_IMG"
}

install_deps() {
    echo "--- 2. 安装构建依赖 ---"
    apt install -y gdisk dosfstools g++-12-riscv64-linux-gnu build-essential \
        libncurses-dev gawk flex bison openssl libssl-dev \
        dkms libelf-dev libudev-dev libpci-dev libiberty-dev autoconf mkbootimg \
        fakeroot genext2fs genisoimage libconfuse-dev mtd-utils mtools qemu-utils squashfs-tools \
        device-tree-compiler rauc u-boot-tools f2fs-tools swig mmdebstrap parted \
        binfmt-support qemu-user-static curl wget kpartx
}

qemu_setup() {
    echo "--- 3. 设置 QEMU (用于 chroot 到 riscv64 环境) ---"
    update-binfmts --display
}

img_setup() {
    echo "--- 4. 创建单分区（ext4）并挂载 ---"

    # 动态分配 loop 设备
    DEVICE=$(losetup --find --show "$ROOT_IMG")
    echo "镜像已关联到 loop 设备: $DEVICE"

    # 创建单个 ext4 分区（占满 100%）
    parted -s -a optimal -- "$DEVICE" mktable msdos
    parted -s -a optimal -- "$DEVICE" mkpart primary ext4 0% 100%

    # 重读分区表
    partprobe "$DEVICE" || blockdev --rereadpt "$DEVICE" || true
    sleep 2

    # 使用 kpartx 创建分区映射
    kpartx -av "$DEVICE" >/dev/null
    DEVBASE=$(basename "$DEVICE")
    ROOT_PART="/dev/mapper/${DEVBASE}p1"

    # 等待设备出现
    for i in {1..10}; do
        if [ -b "$ROOT_PART" ]; then
            break
        fi
        sleep 1
    done

    if [ ! -b "$ROOT_PART" ]; then
        echo "错误：无法创建根分区设备！" >&2
        exit 1
    fi

    # 格式化为 ext4，卷标为 debian-root
    mkfs.ext4 -F -L debian-root "$ROOT_PART"

    # 挂载到 rootfs
    mount "$ROOT_PART" rootfs
    if ! mountpoint -q rootfs; then
        echo "错误：无法挂载根分区！" >&2
        exit 1
    fi

    echo "根分区挂载成功: $ROOT_PART"
    echo "$DEVICE" > /tmp/.build_device
}

make_rootfs() {
    echo "--- 5. 使用 debootstrap 构建根文件系统 ---"
    sudo debootstrap --arch=riscv64 --no-check-gpg unstable "$CHROOT_TARGET" http://mirrors.tuna.tsinghua.edu.cn/debian
}

after_mkrootfs() {
    echo "--- 6. chroot 配置系统 ---"

    if ! mountpoint -q "$CHROOT_TARGET"; then
        echo "错误：根分区未挂载！" >&2
        exit 1
    fi

    # fstab：仅根分区
    cat > "$CHROOT_TARGET/etc/fstab" << EOF
LABEL=debian-root   /   ext4    defaults,noatime 0 1
EOF

    # chroot 配置
    sudo chroot "$CHROOT_TARGET" /bin/bash << 'EOF'
set -euo pipefail
apt update
useradd -m -s /bin/bash -G adm,sudo,audio debian
echo 'debian:debian' | chpasswd
echo debian > /etc/hostname
echo 127.0.1.1 debian >> /etc/hosts
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
apt install -y --no-install-recommends binutils file tree sudo bash-completion u-boot-menu initramfs-tools openssh-server network-manager dnsmasq-base libpam-systemd ppp wireless-regdb wpasupplicant libengine-pkcs11-openssl iptables systemd-timesyncd vim usbutils libgles2 parted pciutils wget initramfs-tools 
u-boot-update
exit
EOF

    echo "$TIMESTAMP" > "$CHROOT_TARGET/etc/debian-release"

    cat > "$CHROOT_TARGET/etc/apt/sources.list" << EOF
deb https://ports.debian.org/debian-ports/ trixie main contrib non-free non-free-firmware
EOF

    # 清理 SSH 密钥
    rm -f "$CHROOT_TARGET"/etc/ssh/ssh_host_*

    # 创建 /boot 目录（如果不存在）
    mkdir -p "$CHROOT_TARGET/boot"

    # 拷贝 boot 文件（内核、dtb 等）
    if [ -d ./boot ]; then
        echo "拷贝 boot 文件到 /boot..."
        cp -rv ./boot/* "$CHROOT_TARGET/boot/"
    else
        echo "警告：未找到 ./boot 目录，跳过 bootloader/内核拷贝。"
    fi

    # 清理 apt 缓存
    rm -rf "$CHROOT_TARGET"/var/lib/apt/lists/*

    # 同步并卸载
    sync
    sleep 2
    umount "$CHROOT_TARGET" || true

    # 清理 kpartx
    DEVICE=$(cat /tmp/.build_device)
    kpartx -dv "$DEVICE" >/dev/null || true
    rm -f /tmp/.build_device
}

# --- 主执行流程 ---
machine_info
init
install_deps
qemu_setup
img_setup
make_rootfs
after_mkrootfs

# 最终清理
sync
sleep 1
DEVICE=$(cat /tmp/.build_device 2>/dev/null || losetup -j "$ROOT_IMG" | cut -d: -f1)
if [ -n "$DEVICE" ]; then
    losetup -d "$DEVICE" 2>/dev/null || true
fi
rm -f /tmp/.build_device

echo "✅ 镜像制作完成: ${ROOT_IMG}"
echo "💡 请确保 U-Boot 配置为从 ext4 的 /boot 加载内核（例如使用 ext4load）。"
