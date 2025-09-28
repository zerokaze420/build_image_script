#!/usr/bin/env bash

# Build Debian RISC-V image (Single Partition Scheme: /boot inside root filesystem)
# Suitable for devices supporting ext4 boot (e.g., Orange Pi RV2 + U-Boot)

set -euo pipefail

# --- User Configurable Variables ---
MODEL=${MODEL:-orangepi-rv2}
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ROOT_IMG=debian-${MODEL}-${TIMESTAMP}.img

DIST="trixie"
BOARD="orangepi-rv2"

BASE_TOOLS="binutils file tree sudo bash-completion u-boot-menu initramfs-tools openssh-server network-manager dnsmasq-base libpam-systemd ppp wireless-regdb wpasupplicant libengine-pkcs11-openssl iptables systemd-timesyncd vim usbutils libgles2 parted pciutils wget"

CHROOT_TARGET="rootfs"

# --- Function Definitions ---

machine_info() {
    echo "--- Display Build Environment Information ---"
    uname -a
    echo "CPU Cores: $(nproc)"
    lscpu
    whoami
    env | head -n 10
    fdisk -l | head -n 20
    df -h
    echo "--------------------------"
}

init() {
    echo "--- 1. Initialize Environment and Image File ---"
    mkdir -p rootfs
    apt update
    echo "Creating 8GB image file: $ROOT_IMG"
    fallocate -l 8G "$ROOT_IMG"
}

install_deps() {
    echo "--- 2. Install Build Dependencies ---"
    # Add debootstrap and e2fsprogs to ensure blkid is available
    apt install -y gdisk dosfstools g++-12-riscv64-linux-gnu build-essential \
        libncurses-dev gawk flex bison openssl libssl-dev \
        dkms libelf-dev libudev-dev libpci-dev libiberty-dev autoconf mkbootimg \
        fakeroot genext2fs genisoimage libconfuse-dev mtd-utils mtools qemu-utils squashfs-tools \
        device-tree-compiler rauc u-boot-tools f2fs-tools swig mmdebstrap parted \
        binfmt-support qemu-user-static curl wget kpartx debootstrap e2fsprogs
}

qemu_setup() {
    echo "--- 3. Set up QEMU (for chroot into riscv64 environment) ---"
    update-binfmts --display
}

# --- Revised img_setup: Get and save partition UUID ---
img_setup() {
    echo "--- 4. Create Single Partition (ext4) and Mount ---"

    # Dynamically assign loop device
    DEVICE=$(losetup --find --show "$ROOT_IMG")
    echo "Image linked to loop device: $DEVICE"

    # Create a single ext4 partition (filling 100%)
    parted -s -a optimal -- "$DEVICE" mktable msdos 
    parted -s -a optimal -- "$DEVICE" mkpart primary ext4 0% 100% 

    # Reread partition table
    partprobe "$DEVICE" || blockdev --rereadpt "$DEVICE" || true
    sleep 2

    # Use kpartx to create partition mappings
    kpartx -av "$DEVICE" >/dev/null
    DEVBASE=$(basename "$DEVICE")
    ROOT_PART="/dev/mapper/${DEVBASE}p1"

    # Wait for device to appear
    for i in {1..10}; do
        if [ -b "$ROOT_PART" ]; then
            break
        fi
        sleep 1
    done

    if [ ! -b "$ROOT_PART" ]; then
        echo "Error: Failed to create root partition device!" >&2
        kpartx -dv "$DEVICE" >/dev/null || true
        losetup -d "$DEVICE" 2>/dev/null || true
        exit 1
    fi

    # Format as ext4 with label debian-root
    mkfs.ext4 -F -L debian-root "$ROOT_PART"

    # Crucial modification: Get partition UUID
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    if [ -z "$ROOT_UUID" ]; then
        echo "Error: Failed to get root partition UUID!" >&2
        exit 1
    fi
    echo "Root Partition UUID: $ROOT_UUID"
    echo "$ROOT_UUID" > /tmp/.root_uuid

    # Mount to rootfs 
    mount "$ROOT_PART" rootfs
    if ! mountpoint -q rootfs; then
        echo "Error: Failed to mount root partition!" >&2
        kpartx -dv "$DEVICE" >/dev/null || true
        losetup -d "$DEVICE" 2>/dev/null || true
        exit 1
    fi

    echo "Root partition mounted successfully: $ROOT_PART"
    echo "$DEVICE" > /tmp/.build_device
}

make_rootfs() {
    echo "--- 5. Build Root Filesystem using debootstrap ---"
    sudo debootstrap --arch=riscv64 --no-check-gpg "${DIST}" "$CHROOT_TARGET" http://mirrors.tuna.tsinghua.edu.cn/debian
}

# --- Final revised after_mkrootfs: Handle UUID and orangepiEnv.txt ---
after_mkrootfs() {
    echo "--- 6. Configure System via chroot ---"

    if ! mountpoint -q "$CHROOT_TARGET"; then
        echo "Error: Root partition is not mounted!" >&2
        exit 1
    fi

    ROOT_UUID=$(cat /tmp/.root_uuid)

    # Key fix 1: fstab uses UUID
    cat > "$CHROOT_TARGET/etc/fstab" << EOF
UUID=${ROOT_UUID}    /    ext4     defaults,noatime 0 1
EOF

    # Copy qemu-riscv64-static to the chroot environment
    cp /usr/bin/qemu-riscv64-static "$CHROOT_TARGET/usr/bin/"

    # chroot configuration
    sudo chroot "$CHROOT_TARGET" /bin/bash << 'EOF_CHROOT'
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" 

apt update

# Ensure e2fsprogs (includes blkid) and u-boot-menu are installed
apt install -y --no-install-recommends binutils file tree sudo bash-completion u-boot-menu initramfs-tools openssh-server network-manager dnsmasq-base libpam-systemd ppp wireless-regdb wpasupplicant libengine-pkcs11-openssl iptables systemd-timesyncd vim usbutils libgles2 parted pciutils wget initramfs-tools e2fsprogs

# Key fix 2: Run u-boot-update
u-boot-update

# --- User Configuration ---
useradd -m -s /bin/bash -G adm,sudo,audio debian
echo 'debian:debian' | chpasswd
echo debian > /etc/hostname
echo 127.0.1.1 debian >> /etc/hosts
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

exit
EOF_CHROOT

    # Clean up qemu-riscv64-static
    rm -f "$CHROOT_TARGET/usr/bin/qemu-riscv64-static"

    echo "$TIMESTAMP" > "$CHROOT_TARGET/etc/debian-release"

    cat > "$CHROOT_TARGET/etc/apt/sources.list" << EOF
deb https://ports.debian.org/debian-ports/ trixie main contrib non-free non-free-firmware
EOF

    # Clean up SSH keys
    rm -f "$CHROOT_TARGET"/etc/ssh/ssh_host_*

    # Create /boot directory (if it doesn't exist)
    mkdir -p "$CHROOT_TARGET/boot"

    # Copy boot files (kernel, dtb, etc.)
    if [ -d ./boot ]; then
        echo "Copying boot files to /boot..."
        # Use -a to preserve permissions and symlinks
        cp -arv ./boot/* "$CHROOT_TARGET/boot/" 
    else
        echo "Warning: ./boot directory not found, skipping bootloader/kernel copy."
    fi

    # --- Key fix 3: Replace UUID in orangepiEnv.txt ---
    ORANGEPI_ENV_FILE="$CHROOT_TARGET/boot/orangepiEnv.txt"
    if [ -f "$ORANGEPI_ENV_FILE" ]; then
        echo "--- Fixing rootdev UUID in orangepiEnv.txt ---"
        # Use sed to replace any UUID format string after rootdev=UUID=
        sed -i "s/rootdev=UUID=[0-9a-fA-F-]*/rootdev=UUID=${ROOT_UUID}/g" "$ORANGEPI_ENV_FILE"
        
        # Verify if replacement was successful
        echo "Verifying rootdev in orangepiEnv.txt:"
        grep "rootdev" "$ORANGEPI_ENV_FILE"
    else
        echo "Warning: Orange Pi U-Boot environment file (${ORANGEPI_ENV_FILE}) not found, skipping UUID replacement."
    fi
    # --------------------------------------------------

    # Clean up apt cache
    rm -rf "$CHROOT_TARGET"/var/lib/apt/lists/*

    # Sync and unmount
    sync
    sleep 2
    umount "$CHROOT_TARGET" || true

    # Clean up kpartx and UUID file
    DEVICE=$(cat /tmp/.build_device)
    kpartx -dv "$DEVICE" >/dev/null || true
    rm -f /tmp/.build_device /tmp/.root_uuid
}

# --- Main Execution Flow ---
machine_info
init
install_deps
qemu_setup
img_setup
make_rootfs
after_mkrootfs

# --- 7. Mount Image and Print U-Boot Boot Configuration ---
echo "--- 7. Mount Image and Print U-Boot Boot Configuration ---"
DEVICE=$(losetup -f --show "$ROOT_IMG")
kpartx -av "$DEVICE" >/dev/null
DEVBASE=$(basename "$DEVICE")
ROOT_PART="/dev/mapper/${DEVBASE}p1"

# Re-mount root partition
mkdir -p /mnt/temp_root
mount "$ROOT_PART" /mnt/temp_root

BOOT_SCRIPT_FILE="/mnt/temp_root/boot/boot.scr"

if [ -f "$BOOT_SCRIPT_FILE" ]; then
    echo "✅ Found U-Boot boot script file: ${BOOT_SCRIPT_FILE}"
    
    # u-boot-menu usually generates a text file /boot/boot.cmd, then compiles it into boot.scr
    BOOT_CMD_FILE="/mnt/temp_root/boot/boot.cmd"
    if [ -f "$BOOT_CMD_FILE" ]; then
        echo "--- Original U-Boot Boot Command File (${BOOT_CMD_FILE}) ---"
        cat "$BOOT_CMD_FILE"
    else
        echo "Warning: Original U-Boot boot command file (/boot/boot.cmd) not found."
    fi

    # Print orangepiEnv.txt (file containing the new UUID)
    ORANGEPI_ENV_FILE="/mnt/temp_root/boot/orangepiEnv.txt"
    if [ -f "$ORANGEPI_ENV_FILE" ]; then
        echo "--- orangepiEnv.txt (Orange Pi U-Boot Environment Configuration) ---"
        cat "$ORANGEPI_ENV_FILE"
    fi
    echo "---------------------------------------------------------"
    
else
    echo "Warning: U-Boot boot script file (boot.scr) not found in /boot directory."
fi

# Final Cleanup
sync
umount /mnt/temp_root || true
kpartx -dv "$DEVICE" >/dev/null || true
losetup -d "$DEVICE" 2>/dev/null || true
rmdir /mnt/temp_root 2>/dev/null || true

rm -f /tmp/.build_device 2>/dev/null || true
rm -f /tmp/.root_uuid 2>/dev/null || true

echo "✅ Image creation complete: ${ROOT_IMG}"
echo "💡 Please check the configurations printed above, ensure the 'rootdev' parameter correctly uses your new partition UUID."