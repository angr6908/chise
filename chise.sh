#!/bin/sh
set -eu

SUITE=trixie
MIRROR=http://deb.debian.org/debian
MOUNT_OPTS=compress=zstd,noatime,space_cache=v2,discard=async

if [ "${1:-}" = "--ssh-key" ] && [ -n "${2:-}" ]; then
    SSH_KEY=$2
else
    echo "Usage: $0 --ssh-key <public-key>" >&2
    exit 1
fi

[ -d /sys/firmware/efi/efivars ] && USE_UEFI=1 || USE_UEFI=0

printf "Network: 1) DHCP  2) Static [1/2]: "
read -r NET_MODE
[ "$NET_MODE" = "2" ] && USE_STATIC=1 || USE_STATIC=0

prepare_host() {
    modprobe btrfs 2>/dev/null || true
    . /etc/os-release 2>/dev/null || true
    case "${ID:-}" in
        alpine)
            apk add --no-cache util-linux debootstrap btrfs-progs parted \
                e2fsprogs-extra zstd dosfstools ;;
        debian|ubuntu)
            apt-get update -q
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                util-linux debootstrap btrfs-progs parted e2fsprogs zstd dosfstools ;;
        *)
            echo "Unsupported host OS: ${ID:-unknown}" >&2; exit 1 ;;
    esac
    umount -R /mnt 2>/dev/null || true
}

detect_disk() {
    DISK=
    for d in vda sda; do
        if [ -b "/dev/$d" ]; then DISK="/dev/$d"; break; fi
    done
    [ -n "$DISK" ] || { echo "No disk found" >&2; exit 1; }
    if [ "$USE_UEFI" = 1 ]; then
        PART_EFI="${DISK}1"
        PART_ROOT="${DISK}2"
    else
        PART_ROOT="${DISK}1"
    fi
}

detect_network() {
    ETH=$(ip -o link show | awk 'NR==2{gsub(/:$/,"",$2); print $2}')
    IPV4=$(ip -4 -o addr show dev "$ETH" | awk 'NR==1{print $4}')
    GW4=$(ip -4 route show default | awk '{print $3}')
    IPV6=$(ip -6 -o addr show dev "$ETH" scope global | awk 'NR==1{print $4}')
    GW6=$(ip -6 route show default | awk '{print $3}')
}

settle() { udevadm settle 2>/dev/null || partprobe "$DISK" 2>/dev/null || true; }

make_root_fs() {
    mkfs.btrfs -f -L root -M "$PART_ROOT"
    btrfs device scan --forget 2>/dev/null || true
    btrfs device scan 2>/dev/null || true
    settle
}

partition_and_mount() {
    wipefs -a "$DISK" 2>/dev/null || true
    btrfs device scan --forget 2>/dev/null || true
    dd if=/dev/zero of="$DISK" bs=1M count=300 conv=fsync 2>/dev/null || true

    if [ "$USE_UEFI" = 1 ]; then
        parted -s "$DISK" mklabel gpt \
            mkpart ESP fat16 1MiB 9MiB set 1 esp on \
            mkpart primary btrfs 9MiB 100%
        settle
        mkfs.fat -n ESP "$PART_EFI"
        make_root_fs
        mount -o "$MOUNT_OPTS" "$PART_ROOT" /mnt
        mkdir -p /mnt/boot/efi
        mount "$PART_EFI" /mnt/boot/efi
    else
        parted -s "$DISK" mklabel msdos mkpart primary btrfs 1MiB 100% set 1 boot on
        settle
        make_root_fs
        mount -o "$MOUNT_OPTS" "$PART_ROOT" /mnt
    fi
}

bootstrap_debian() {
    debootstrap --arch=amd64 --variant=minbase \
        --include=systemd,systemd-sysv,ca-certificates,curl,dbus,zstd \
        "$SUITE" /mnt "$MIRROR"
    for d in /dev /dev/pts /proc /sys /run; do mkdir -p "/mnt$d"; mount -B "$d" "/mnt$d"; done
    [ "$USE_UEFI" = 1 ] && mount --bind /sys/firmware/efi/efivars \
        /mnt/sys/firmware/efi/efivars || true
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
    echo "deb $MIRROR $SUITE main" > /mnt/etc/apt/sources.list
}

install_packages() {
    echo 'debconf debconf/frontend select Noninteractive' | chroot /mnt debconf-set-selections
    if [ "$USE_UEFI" = 1 ]; then
        GRUB_PKGS="grub-efi-amd64-signed shim-signed efibootmgr"
    else
        GRUB_PKGS="grub-pc"
        echo "grub-pc grub-pc/install_devices string $DISK" | chroot /mnt debconf-set-selections
        echo 'grub-pc grub-pc/install_devices_empty boolean true' | chroot /mnt debconf-set-selections
    fi
    DEBIAN_FRONTEND=noninteractive chroot /mnt apt-get update -q
    DEBIAN_FRONTEND=noninteractive chroot /mnt apt-get install -y \
        iproute2 ca-certificates btrfs-progs nano curl \
        linux-image-cloud-amd64 openssh-server cron zram-tools iputils-ping \
        $GRUB_PKGS
}

configure_system() {
    if [ "$USE_UEFI" = 1 ]; then
        printf "LABEL=root\t/\t\tbtrfs\t%s\t0 0\nLABEL=ESP\t/boot/efi\tvfat\tdefaults,noatime\t0 2\n" \
            "$MOUNT_OPTS" > /mnt/etc/fstab
    else
        printf "LABEL=root\t/\tbtrfs\t%s\t0 0\n" \
            "$MOUNT_OPTS" > /mnt/etc/fstab
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
    if [ "$USE_STATIC" = 1 ]; then
        {
            printf "[Match]\nName=en*\n\n[Network]\n"
            [ -n "${IPV4:-}" ] && [ -n "${GW4:-}" ] && \
                printf "Address=%s\nGateway=%s\n" "$IPV4" "$GW4" || true
            [ -n "${IPV6:-}" ] && [ -n "${GW6:-}" ] && \
                printf "Address=%s\n\n[Route]\nDestination=%s/128\nScope=link\n\n[Route]\nGateway=%s\nGatewayOnLink=yes\n" \
                    "$IPV6" "$GW6" "$GW6" || true
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
    if [ "$USE_UEFI" = 1 ]; then
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
    for d in locale doc man info; do rm -rf "/mnt/usr/share/$d"/*; done
    rm -rf /mnt/var/lib/apt/lists/*
    [ "$USE_UEFI" = 1 ] && umount /mnt/sys/firmware/efi/efivars 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true
    sync
}

prepare_host
detect_disk
[ "$USE_STATIC" = 1 ] && detect_network || true
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
