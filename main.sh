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
    # 添加 debootstrap 和 e2fsprogs 以确保 blkid 可用
    apt install -y gdisk dosfstools g++-12-riscv64-linux-gnu build-essential \
        libncurses-dev gawk flex bison openssl libssl-dev \
        dkms libelf-dev libudev-dev libpci-dev libiberty-dev autoconf mkbootimg \
        fakeroot genext2fs genisoimage libconfuse-dev mtd-utils mtools qemu-utils squashfs-tools \
        device-tree-compiler rauc u-boot-tools f2fs-tools swig mmdebstrap parted \
        binfmt-support qemu-user-static curl wget kpartx debootstrap e2fsprogs
}

qemu_setup() {
    echo "--- 3. 设置 QEMU (用于 chroot 到 riscv64 环境) ---"
    update-binfmts --display
}

# --- 修复后的 img_setup：获取并保存分区 UUID ---
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
        kpartx -dv "$DEVICE" >/dev/null || true
        losetup -d "$DEVICE" 2>/dev/null || true
        exit 1
    fi

    # 格式化为 ext4，卷标为 debian-root
    mkfs.ext4 -F -L debian-root "$ROOT_PART"

    # 关键修改：获取分区 UUID
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    if [ -z "$ROOT_UUID" ]; then
        echo "错误：无法获取根分区 UUID！" >&2
        exit 1
    fi
    echo "根分区 UUID: $ROOT_UUID"
    echo "$ROOT_UUID" > /tmp/.root_uuid

    # 挂载到 rootfs 
    mount "$ROOT_PART" rootfs
    if ! mountpoint -q rootfs; then
        echo "错误：无法挂载根分区！" >&2
        kpartx -dv "$DEVICE" >/dev/null || true
        losetup -d "$DEVICE" 2>/dev/null || true
        exit 1
    fi

    echo "根分区挂载成功: $ROOT_PART"
    echo "$DEVICE" > /tmp/.build_device
}

make_rootfs() {
    echo "--- 5. 使用 debootstrap 构建根文件系统 ---"
    sudo debootstrap --arch=riscv64 --no-check-gpg "${DIST}" "$CHROOT_TARGET" http://mirrors.tuna.tsinghua.edu.cn/debian
}

# --- 最终修复后的 after_mkrootfs：处理 UUID 和 orangepiEnv.txt ---
after_mkrootfs() {
    echo "--- 6. chroot 配置系统 ---"

    if ! mountpoint -q "$CHROOT_TARGET"; then
        echo "错误：根分区未挂载！" >&2
        exit 1
    fi

    ROOT_UUID=$(cat /tmp/.root_uuid)

    # 关键修复 1: fstab 使用 UUID
    cat > "$CHROOT_TARGET/etc/fstab" << EOF
UUID=${ROOT_UUID}    /    ext4     defaults,noatime 0 1
EOF

    # 复制 qemu-riscv64-static 到 chroot 环境
    cp /usr/bin/qemu-riscv64-static "$CHROOT_TARGET/usr/bin/"

    # chroot 配置
    sudo chroot "$CHROOT_TARGET" /bin/bash << 'EOF_CHROOT'
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" 

apt update

# 确保安装 e2fsprogs（包含 blkid）和 u-boot-menu
apt install -y --no-install-recommends binutils file tree sudo bash-completion u-boot-menu initramfs-tools openssh-server network-manager dnsmasq-base libpam-systemd ppp wireless-regdb wpasupplicant libengine-pkcs11-openssl iptables systemd-timesyncd vim usbutils libgles2 parted pciutils wget initramfs-tools e2fsprogs

# 关键修复 2: 运行 u-boot-update
u-boot-update

# --- 用户配置 ---
useradd -m -s /bin/bash -G adm,sudo,audio debian
echo 'debian:debian' | chpasswd
echo debian > /etc/hostname
echo 127.0.1.1 debian >> /etc/hosts
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

exit
EOF_CHROOT

    # 清理 qemu-riscv64-static
    rm -f "$CHROOT_TARGET/usr/bin/qemu-riscv64-static"

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
        # 使用 -a 保留权限和符号链接
        cp -arv ./boot/* "$CHROOT_TARGET/boot/" 
    else
        echo "警告：未找到 ./boot 目录，跳过 bootloader/内核拷贝。"
    fi

    # --- 关键修复 3: 替换 orangepiEnv.txt 中的 UUID ---
    ORANGEPI_ENV_FILE="$CHROOT_TARGET/boot/orangepiEnv.txt"
    if [ -f "$ORANGEPI_ENV_FILE" ]; then
        echo "--- 修复 orangepiEnv.txt 中的 rootdev UUID ---"
        # 使用 sed 替换文件中 rootdev=UUID= 后面的任何 UUID 格式字符串
        sed -i "s/rootdev=UUID=[0-9a-fA-F-]*/rootdev=UUID=${ROOT_UUID}/g" "$ORANGEPI_ENV_FILE"
        
        # 验证替换是否成功
        echo "验证 orangepiEnv.txt 中的 rootdev:"
        grep "rootdev" "$ORANGEPI_ENV_FILE"
    else
        echo "警告：未找到 Orange Pi U-Boot 环境文件 (${ORANGEPI_ENV_FILE})，跳过 UUID 替换。"
    fi
    # --------------------------------------------------

    # 清理 apt 缓存
    rm -rf "$CHROOT_TARGET"/var/lib/apt/lists/*

    # 同步并卸载
    sync
    sleep 2
    umount "$CHROOT_TARGET" || true

    # 清理 kpartx 和 UUID 文件
    DEVICE=$(cat /tmp/.build_device)
    kpartx -dv "$DEVICE" >/dev/null || true
    rm -f /tmp/.build_device /tmp/.root_uuid
}

# --- 主执行流程 ---
machine_info
init
install_deps
qemu_setup
img_setup
make_rootfs
after_mkrootfs

# --- 7. 挂载镜像并打印 U-Boot 启动配置 ---
echo "--- 7. 挂载镜像并打印 U-Boot 启动配置 ---"
DEVICE=$(losetup -f --show "$ROOT_IMG")
kpartx -av "$DEVICE" >/dev/null
DEVBASE=$(basename "$DEVICE")
ROOT_PART="/dev/mapper/${DEVBASE}p1"

# 再次挂载根分区
mkdir -p /mnt/temp_root
mount "$ROOT_PART" /mnt/temp_root

BOOT_SCRIPT_FILE="/mnt/temp_root/boot/boot.scr"

if [ -f "$BOOT_SCRIPT_FILE" ]; then
    echo "✅ 找到 U-Boot 启动脚本文件: ${BOOT_SCRIPT_FILE}"
    
    # u-boot-menu 通常会生成一个文本文件 /boot/boot.cmd，然后编译成 boot.scr
    BOOT_CMD_FILE="/mnt/temp_root/boot/boot.cmd"
    if [ -f "$BOOT_CMD_FILE" ]; then
        echo "--- 原始 U-Boot 启动命令文件 (${BOOT_CMD_FILE}) ---"
        cat "$BOOT_CMD_FILE"
    else
        echo "警告：未找到原始 U-Boot 启动命令文件 (/boot/boot.cmd)。"
    fi

    # 打印 orangepiEnv.txt (包含新 UUID 的文件)
    ORANGEPI_ENV_FILE="/mnt/temp_root/boot/orangepiEnv.txt"
    if [ -f "$ORANGEPI_ENV_FILE" ]; then
        echo "--- orangepiEnv.txt (Orange Pi U-Boot 环境配置) ---"
        cat "$ORANGEPI_ENV_FILE"
    fi
    echo "---------------------------------------------------------"
    
else
    echo "警告：在 /boot 目录下未找到 U-Boot 启动脚本文件 (boot.scr)。"
fi

# 最终清理
sync
umount /mnt/temp_root || true
kpartx -dv "$DEVICE" >/dev/null || true
losetup -d "$DEVICE" 2>/dev/null || true
rmdir /mnt/temp_root 2>/dev/null || true

rm -f /tmp/.build_device 2>/dev/null || true
rm -f /tmp/.root_uuid 2>/dev/null || true

echo "✅ 镜像制作完成: ${ROOT_IMG}"
echo "💡 请检查上方打印的配置，确保 'rootdev' 参数正确使用了您的新分区 UUID。"
