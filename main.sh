#!/usr/bin/env bash

# 这是一个 Bash 脚本，用于自动化构建一个 Debian RISC-V 镜像
# 参考: https://github.com/revyos/mkimg-sg2042/blob/master/mkrootfs-debian.sh

# --- 脚本行为设置 ---
# -e: 如果任何命令返回非零退出状态（表示错误），则立即退出脚本。
# -u: 如果试图使用未定义的变量，则视为错误并立即退出。
# -o pipefail: 如果管道中的任何命令失败，则整个管道的退出状态为失败状态。
set -euo pipefail

# --- 用户可配置变量 ---
MODEL=${MODEL:-orangepi-rv2}                      # 目标设备型号，默认为 orangepi-rv2
DEVICE=/dev/loop100                               # 指定一个临时的 loop 设备用于挂载镜像文件
CHROOT_TARGET=rootfs                              # 用于挂载和构建根文件系统的临时目录名
TIMESTAMP=$(date +%Y%m%d-%H%M%S)                  # 生成一个时间戳，用于命名镜像文件
ROOT_IMG=debian-${MODEL}-${TIMESTAMP}.img         # 最终生成的镜像文件名

DIST="trixie"                                     # 指定 Debian 的发行版代号 (trixie 是 Debian 13)
BOARD="orangepi-rv2"                              # 开发板名称

# == 软件包列表 ==
# 只保留最基本的系统工具，用于创建一个最小化的系统
BASE_TOOLS="binutils file tree sudo bash-completion u-boot-menu initramfs-tools openssh-server network-manager dnsmasq-base libpam-systemd ppp wireless-regdb wpasupplicant libengine-pkcs11-openssl iptables systemd-timesyncd vim usbutils libgles2 parted pciutils wget"
# 固件包，例如用于 WiFi/蓝牙和显卡
ADDONS="initramfs-tools firmware-amd-graphics firmware-realtek"

# 以下是可选软件包组，当前均设置为空，以构建一个最小系统
XFCE_DESKTOP=""       # XFCE 桌面环境相关的包
BENCHMARK_TOOLS=""    # 性能测试工具
FONTS=""              # 字体
EXTRA_TOOLS=""        # 额外的工具
DOCKER=""             # Docker 容器引擎
LIBREOFFICE=""        # LibreOffice 办公套件

# --- 函数定义 ---

# 打印当前构建环境的主机信息，用于调试
machine_info() {
    echo "--- 显示构建环境信息 ---"
    uname -a                # 显示内核信息
    echo "CPU核心数: $(nproc)" # 显示 CPU 核心数
    lscpu                   # 显示 CPU 架构信息
    whoami                  # 显示当前用户
    env | head -n 10        # 显示环境变量（前10行）
    fdisk -l | head -n 20   # 显示磁盘分区信息（前20行）
    df -h                   # 显示磁盘空间使用情况
    echo "--------------------------"
}

# 初始化构建环境
init() {
    echo "--- 1. 初始化环境和镜像文件 ---"
    # 创建一个名为 rootfs 的目录，用作后续操作的挂载点
    mkdir -p rootfs

    # 更新宿主机的软件包列表
    apt update

    # 创建一个指定大小的空镜像文件，这里是 8GB。
    # fallocate 比 dd 更快，因为它只是预分配空间而不写入零。
    echo "创建 8GB 大小的镜像文件: $ROOT_IMG"
    fallocate -l 8G $ROOT_IMG
}

# 在宿主机上安装构建所需的依赖软件包
install_deps() {
    echo "--- 2. 安装构建依赖 ---"
    apt install -y gdisk dosfstools g++-12-riscv64-linux-gnu build-essential \
        libncurses-dev gawk flex bison openssl libssl-dev \
        dkms libelf-dev libudev-dev libpci-dev libiberty-dev autoconf mkbootimg \
        fakeroot genext2fs genisoimage libconfuse-dev mtd-utils mtools qemu-utils squashfs-tools \
        device-tree-compiler rauc u-boot-tools f2fs-tools swig mmdebstrap parted
}

# 设置 QEMU 和 binfmt，使得可以在 x86_64 主机上执行 RISC-V 架构的程序
qemu_setup() {
    echo "--- 3. 设置 QEMU (用于 chroot 到 riscv64 环境) ---"
    apt install -y binfmt-support qemu-user-static curl wget
    # 显示当前的 binfmt 配置，确保 riscv64 的解释器已正确设置
    update-binfmts --display
}

# 设置镜像文件，包括分区和格式化
img_setup() {
    echo "--- 4. 分区并格式化镜像文件 ---"
    # 将镜像文件关联到一个 loop 设备，这样可以像操作物理硬盘一样操作它
    losetup -P "${DEVICE}" $ROOT_IMG
    
    # 使用 parted 对 loop 设备进行分区 (msdos 分区表)
    # -s: 脚本模式，不进行交互
    parted -s -a optimal -- "${DEVICE}" mktable msdos
    # 创建第一个分区: FAT32 格式，256MB，用于 EFI/Boot
    parted -s -a optimal -- "${DEVICE}" mkpart primary fat32 0% 256MiB
    # 创建第二个分区: ext4 格式，占用剩余所有空间，用于根文件系统
    parted -s -a optimal -- "${DEVICE}" mkpart primary ext4 256MiB 100%

    # 通知内核重新读取分区表
    partprobe "${DEVICE}"

    # 格式化分区
    # 格式化 p1 为 vfat (FAT32)，并设置卷标为 EFI
    mkfs.vfat "${DEVICE}p1" -n EFI
    # 格式化 p2 为 ext4，并设置卷标为 debian-root
    mkfs.ext4 -F -L debian-root "${DEVICE}p2"

    # 挂载分区到本地目录
    echo "挂载分区到 ./rootfs 目录..."
    # 挂载根分区
    mount "${DEVICE}p2" rootfs
    # 在根分区内创建 boot 和 efi 目录作为 EFI 分区的挂载点
    mkdir -p rootfs/boot
    mkdir -p rootfs/boot/efi
    # 挂载 EFI 分区
    mount "${DEVICE}p1" rootfs/boot/efi
}

# 使用 debootstrap 构建基础的 Debian 根文件系统
make_rootfs() {
    echo "--- 5. 使用 debootstrap 构建根文件系统 ---"
    # mmdebstrap 是 debootstrap 的一个现代替代品，通常更快。这里保留了命令作为参考。
    # mmdebstrap --architectures=riscv64 \
    # --skip=check/empty,check/gpg \
    # --include="ca-certificates locales dosfstools $BASE_TOOLS $ADDONS" \
    # $DIST "$CHROOT_TARGET" \
    # "deb https://ports.debian.org/debian-ports/ $DIST main contrib non-free non-free-firmware"

    # 使用 debootstrap 工具在 $CHROOT_TARGET (即 ./rootfs) 目录中构建一个 riscv64 架构的 Debian 系统
    # --arch: 指定目标架构
    # --no-check-gpg: 跳过 GPG 密钥检查
    # unstable: 指定 Debian 版本
    # http://mirrors.tuna.tsinghua.edu.cn/debian: 指定清华大学的镜像源以加快下载速度
    sudo debootstrap --arch=riscv64 --no-check-gpg unstable $CHROOT_TARGET http://mirrors.tuna.tsinghua.edu.cn/debian
}

# 在 debootstrap 完成后，通过 chroot 进入新系统进行配置
after_mkrootfs() {
    echo "--- 6. chroot 到新系统并进行配置 ---"
    # 设置 fstab 文件，用于定义系统启动时如何挂载分区
    mkdir -p "$CHROOT_TARGET"/etc
    cat > "$CHROOT_TARGET"/etc/fstab << EOF
LABEL=debian-root   /               ext4    defaults,noatime,x-systemd.device-timeout=300s,x-systemd.mount-timeout=300s 0 0
LABEL=EFI           /boot/efi       vfat    defaults,noatime,x-systemd.device-timeout=300s,x-systemd.mount-timeout=300s 0 0
EOF

    # 使用 chroot 命令将根目录切换到新生成的文件系统中，并在其中执行一系列命令
    sudo chroot $CHROOT_TARGET /bin/bash << EOF
# 更新新系统内的软件包列表
apt update

# 添加一个名为 'debian' 的用户，并设置密码为 'debian'
# -m: 创建家目录
# -s /bin/bash: 指定默认 shell
# -G adm,sudo,audio: 将用户添加到 adm, sudo, audio 用户组
useradd -m -s /bin/bash -G adm,sudo,audio debian
echo 'debian:debian' | chpasswd

# 修改主机名
echo debian > /etc/hostname
echo 127.0.1.1 debian >> /etc/hosts

# 设置时区为上海
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

# 退出 chroot 环境
exit
EOF

    # 在新系统中写入一个包含构建时间戳的文件
    echo "$TIMESTAMP" > rootfs/etc/debian-release

    # 覆盖新系统中的 apt 源列表，使用 ports.debian.org (用于非主流架构)
    cat > $CHROOT_TARGET/etc/apt/sources.list << EOF
deb https://ports.debian.org/debian-ports/ $DIST main contrib non-free non-free-firmware
EOF

    # 移除 SSH 主机密钥，这样每个基于此镜像启动的设备都会在首次启动时生成新的、唯一的密钥
    echo "清理 SSH 主机密钥..."
    rm -f "$CHROOT_TARGET"/etc/ssh/ssh_host_*

    # 拷贝预先准备好的 bootloader 和内核文件到新系统的 /boot 目录
    echo "拷贝 boot 文件..."
    cp -rv ./boot/* "$CHROOT_TARGET/boot/"
    
    # 清理 apt 缓存，减小镜像体积
    echo "清理 apt 缓存..."
    rm -vrf "$CHROOT_TARGET"/var/lib/apt/lists/*

    # 【重要修复】
    # 必须先同步缓存，确保所有数据都从内存写入到 loop 设备
    echo "同步文件系统缓存到磁盘..."
    sync
    
    # 【重要修复】
    # 使用递归方式卸载所有挂载点。这会先卸载内部的 ./rootfs/boot/efi，再卸载外部的 ./rootfs，顺序正确。
    echo "以正确的顺序卸载所有文件系统..."
    umount -R "$CHROOT_TARGET"
}

# --- 主执行流程 ---
machine_info   # 打印主机信息
init           # 创建镜像文件
install_deps   # 安装依赖
qemu_setup     # 设置 QEMU
img_setup      # 分区、格式化并挂载镜像
make_rootfs    # 构建根文件系统
after_mkrootfs # chroot并配置系统、最后安全卸载

# 【重要修复】
# 在分离 loop 设备之前，再次执行 sync 是一个好习惯，确保万无一失。
echo "最终同步..."
sync

# 分离 loop 设备，完成镜像制作
echo "分离 loop 设备..."
losetup -d "${DEVICE}"

echo "镜像制作完成: ${ROOT_IMG}"

