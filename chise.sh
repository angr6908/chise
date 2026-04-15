#!/bin/sh

SSH_KEY=""
[ "$1" = "--ssh-key" ] && SSH_KEY="$2" || { echo "Usage: $0 --ssh-key <public-key>"; exit 1; }

[ -d /sys/firmware/efi/efivars ] && USE_UEFI=1 || USE_UEFI=0

printf "Network: 1) DHCP  2) Static [1/2]: "; read NET_MODE
[ "$NET_MODE" = "2" ] && USE_STATIC=1 || USE_STATIC=0

detect_disk() {
    for d in vda sda; do [ -b "/dev/$d" ] && { DISK="/dev/$d"; break; }; done
    [ -z "$DISK" ] && { echo "No disk found"; exit 1; }
    PART_ROOT="${DISK}$( [ "$USE_UEFI" = "1" ] && echo 2 || echo 1 )"
    [ "$USE_UEFI" = "1" ] && PART_EFI="${DISK}1"
}

detect_network() {
    ETH=$(ip -o link show | awk 'NR==2{gsub(/:$/,"",$2); print $2}')
    IPV4=$(ip -4 -o addr show dev $ETH | awk 'NR==1{print $4}')
    GW4=$(ip -4 route show default | awk '{print $3}')
    IPV6=$(ip -6 -o addr show dev $ETH scope global | awk 'NR==1{print $4}')
    GW6=$(ip -6 route show default | awk '{print $3}')
}

partition_and_mount() {
    wipefs -a $DISK
    if [ "$USE_UEFI" = "1" ]; then
        parted -s $DISK mklabel gpt \
            mkpart ESP fat16 1MiB 9MiB set 1 esp on \
            mkpart primary btrfs 9MiB 100%
        sleep 2
        mkfs.fat $PART_EFI
        mkfs.btrfs -f -L root -M $PART_ROOT
        mount -o compress=zstd,noatime,space_cache=v2,discard=async $PART_ROOT /mnt
        mkdir -p /mnt/boot/efi && mount $PART_EFI /mnt/boot/efi
    else
        parted -s $DISK mklabel msdos mkpart primary btrfs 1MiB 100% set 1 boot on
        sleep 2
        mkfs.btrfs -f -L root -M $PART_ROOT
        mount -o compress=zstd,noatime,space_cache=v2,discard=async $PART_ROOT /mnt
    fi
}

bootstrap_debian() {
    debootstrap --arch=amd64 --variant=minbase \
        --include=systemd,systemd-sysv,ca-certificates,curl,dbus,zstd \
        trixie /mnt http://deb.debian.org/debian
    for i in /dev /dev/pts /proc /sys /run; do mount -B $i /mnt$i; done
    [ "$USE_UEFI" = "1" ] && mount --bind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars
}

configure_apt() {
    mkdir -p /mnt/etc/dpkg/dpkg.cfg.d/ /mnt/etc/apt/apt.conf.d/
    cat > /mnt/etc/dpkg/dpkg.cfg.d/01_nodoc << 'EOF'
path-exclude=/usr/share/doc/*
path-exclude=/usr/share/man/*
path-exclude=/usr/share/locale/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/groff/*
path-exclude=/usr/share/lintian/*
path-include=/usr/share/locale/locale.alias
EOF
    cat > /mnt/etc/apt/apt.conf.d/99minimal << 'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::GzipIndexes "true";
Acquire::CompressionTypes::Order:: "gz";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
Acquire::Languages "none";
EOF
    echo "deb http://deb.debian.org/debian trixie main" > /mnt/etc/apt/sources.list
}

install_packages() {
    echo 'debconf debconf/frontend select Noninteractive' | chroot /mnt debconf-set-selections
    [ "$USE_UEFI" = "0" ] && {
        echo "grub-pc grub-pc/install_devices string $DISK" | chroot /mnt debconf-set-selections
        echo 'grub-pc grub-pc/install_devices_empty boolean true' | chroot /mnt debconf-set-selections
    }
    DEBIAN_FRONTEND=noninteractive chroot /mnt apt-get update -q
    DEBIAN_FRONTEND=noninteractive chroot /mnt apt-get install -y \
        iproute2 fuse3 ca-certificates btrfs-progs nano curl \
        linux-image-cloud-amd64 openssh-server zip unzip rsync 7zip cron zram-tools iputils-ping \
        $( [ "$USE_UEFI" = "1" ] \
            && echo "grub-efi-amd64-signed shim-signed efibootmgr" \
            || echo "grub-pc" )
}

configure_system() {
    ROOT_UUID=$(blkid -s UUID -o value $PART_ROOT)
    if [ "$USE_UEFI" = "1" ]; then
        EFI_UUID=$(blkid -s UUID -o value $PART_EFI)
        printf "UUID=%s\t/\t\tbtrfs\tdefaults,noatime,compress=zstd,space_cache=v2,discard=async\t0 0\nUUID=%s\t/boot/efi\tvfat\tdefaults,noatime\t0 2\n" \
            "$ROOT_UUID" "$EFI_UUID" > /mnt/etc/fstab
    else
        printf "UUID=%s\t/\tbtrfs\tdefaults,noatime,compress=zstd,space_cache=v2,discard=async\t0 0\n" \
            "$ROOT_UUID" > /mnt/etc/fstab
    fi

    printf "nameserver 9.9.9.9\nnameserver 2620:fe::fe\n" > /mnt/etc/resolv.conf
    echo "localhost" > /mnt/etc/hostname
    printf "127.0.0.1\tlocalhost\n::1\t\tlocalhost ip6-localhost ip6-loopback\n" > /mnt/etc/hosts
    printf "LANG=C\nLC_ALL=C\n" | tee /mnt/etc/default/locale > /mnt/etc/environment

    mkdir -p /mnt/etc/sysctl.d/ /mnt/etc/systemd/journald.conf.d/
    cat >> /mnt/etc/sysctl.d/99-sysctl.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=180
vm.watermark_boost_factor=0
vm.page-cluster=0
vm.extfrag_threshold=0
EOF
    printf "[Journal]\nSystemMaxUse=1M\nRuntimeMaxUse=1M\n" \
        > /mnt/etc/systemd/journald.conf.d/size.conf
}

configure_ssh() {
    mkdir -p /mnt/root/.ssh/
    echo "$SSH_KEY" > /mnt/root/.ssh/authorized_keys
    chmod 700 /mnt/root/.ssh && chmod 600 /mnt/root/.ssh/authorized_keys
    mkdir -p /mnt/etc/ssh/sshd_config.d/
    cat > /mnt/etc/ssh/sshd_config.d/99-local.conf << 'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF
}

configure_network() {
    mkdir -p /mnt/etc/systemd/network
    if [ "$USE_STATIC" = "1" ]; then
        { echo "[Match]"; echo "Name=en*"; echo ""; echo "[Network]"
          [ -n "$IPV4" ] && [ -n "$GW4" ] && printf "Address=%s\nGateway=%s\n" "$IPV4" "$GW4"
          [ -n "$IPV6" ] && [ -n "$GW6" ] && printf "Address=%s\n\n[Route]\nDestination=%s/128\nScope=link\n\n[Route]\nGateway=%s\nGatewayOnLink=yes\n" "$IPV6" "$GW6" "$GW6"
        } > /mnt/etc/systemd/network/20-wired.network
    else
        printf "[Match]\nName=en*\n\n[Network]\nDHCP=yes\nIPv6AcceptRA=yes\n" \
            > /mnt/etc/systemd/network/20-wired.network
    fi
    chroot /mnt systemctl enable systemd-networkd
}

configure_bootloader() {
    cat > /mnt/etc/default/grub << 'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Debian"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200"
GRUB_TERMINAL="serial console"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF
    if [ "$USE_UEFI" = "1" ]; then
        chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi \
            --bootloader-id=debian --recheck --no-floppy --removable
    else
        chroot /mnt grub-install "$DISK"
    fi
    chroot /mnt update-grub
    chroot /mnt update-initramfs -u -k all
}

configure_zram() {
    sed -i 's/^ALGO=lz4/ALGO=zstd/; s/^PERCENT=50/PERCENT=200/' /mnt/etc/default/zramswap
}

cleanup() {
    chroot /mnt passwd -l root
    DEBIAN_FRONTEND=noninteractive chroot /mnt apt-get clean
    rm -rf /mnt/usr/share/{locale,doc,man,info}/* /mnt/var/lib/apt/lists/*
    [ "$USE_UEFI" = "1" ] && umount /mnt/sys/firmware/efi/efivars 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true
    sync
}

modprobe btrfs

. /etc/os-release 2>/dev/null
if [ "$ID" = "alpine" ]; then
    apk add --no-cache util-linux debootstrap btrfs-progs parted e2fsprogs-extra zstd dosfstools
elif [ "$ID" = "debian" ] || [ "$ID" = "ubuntu" ]; then
    apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y util-linux debootstrap btrfs-progs parted e2fsprogs zstd dosfstools
else
    echo "Unsupported OS" && exit 1
fi

umount -R /mnt 2>/dev/null || true

detect_disk
[ "$USE_STATIC" = "1" ] && detect_network
partition_and_mount
bootstrap_debian
configure_apt
install_packages
configure_system
configure_ssh
configure_network
configure_bootloader
configure_zram
cleanup
reboot
