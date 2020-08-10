#!/bin/bash

set -Eeuxo pipefail

# zfs datasets

mydir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

bootstrap_dialog() {
    dialog_result=$(dialog --clear --stdout --backtitle "Arch bootstrapper" --no-shadow "$@" 2>/dev/null)
    if [ -z "${dialog_result}" ]; then
        clear
        exit 1
    fi
}
bootstrap_dialog_non_mandatory() {
    dialog_result=$(dialog --clear --stdout --backtitle "ZFS bootstrapper" --no-shadow "$@" 2>/dev/null)
}

setup() {
    if [ -z "${INSTALL_DISK:-}" ]; then
        declare -a disks
        for disk in /dev/disk/by-id/*; do
            disks+=("${disk}" "$(basename "$(readlink "$disk")")")
        done
        bootstrap_dialog --title "Choose installation disk" \
                        --menu "Which disk to install on?" 0 0 0 \
                        "${disks[@]}"
        INSTALL_DISK="${dialog_result}"
    fi

    if [ -z "${HOSTNAME_FQDN:-}" ]; then
        bootstrap_dialog --title "Hostname" --inputbox "Please enter a fqdn for this host.\n" 8 60
        HOSTNAME_FQDN="$dialog_result"
    fi
    if [ -z "${OS_SIZE:-}" ]; then
        bootstrap_dialog --title "OS Size" --inputbox "Please enter a size of OS partition in GB.\n" 8 60
        OS_SIZE="$dialog_result"
    fi

    if [ -z "${SWAP_SIZE:-}" ]; then
        bootstrap_dialog --title "Swap Size" --inputbox "Please enter a swap size in GB.\n" 8 60
        SWAP_SIZE="$dialog_result"
    fi

    if [ -z "${LUKS_PASSPHRASE:-}" ]; then
        bootstrap_dialog --title "Disk encryption" --passwordbox "Please enter a strong passphrase for the full disk encryption.\n" 8 60
        LUKS_PASSPHRASE="$dialog_result"
        bootstrap_dialog --title "Disk encryption" --passwordbox "Please re-enter passphrase to verify.\n" 8 60
        LUKS_PASSPHRASE_VERIFY="$dialog_result"
        if [[ "${LUKS_PASSPHRASE}" != "${LUKS_PASSPHRASE_VERIFY}" ]]; then
            echo "Passwords did not match."
            exit 3
        fi
    fi

    if [ -z "${ROOT_PASSWORD:-}" ]; then
        bootstrap_dialog --title "Root password" --passwordbox "Please enter a strong password for the root user.\n" 8 60
        ROOT_PASSWORD="$dialog_result"
        bootstrap_dialog --title "Root password" --passwordbox "Please re-enter passphrase to verify.\n" 8 60
        ROOT_PASSWORD_VERIFY="$dialog_result"
        if [[ "${ROOT_PASSWORD}" != "${ROOT_PASSWORD_VERIFY}" ]]; then
            echo "Passwords did not match."
            exit 3
        fi
    fi

    bootstrap_dialog_non_mandatory --title "WARNING" --msgbox "This script will NUKE ${INSTALL_DISK}.\nPress <Enter> to continue or <Esc> to cancel.\n" 6 60

    clear

    [ ! -e "${INSTALL_DISK}" ] && echo "${INSTALL_DISK} does not exist!" && exit 1

    grep vendor_id /proc/cpuinfo | grep -q Intel && IS_INTEL_CPU=1 ||
        IS_INTEL_CPU=0
    grep vendor_id /proc/cpuinfo | grep -q AMD && IS_AMD_CPU=1 ||
        IS_AMD_CPU=0
    [ -d /sys/firmware/efi ] && IS_EFI=true || IS_EFI=false
    [ "${IS_EFI}" = true ] && echo "Performing UEFI install."
    [ "${IS_EFI}" = false ] && echo "Performing legacy BIOS install."
}

preinstall() {
    pacman -S --needed --noconfirm parted dialog bc dosfstools \
        arch-install-scripts xfsprogs lvm2 zfs-utils
    loadkeys de
    [ ! "${VIRT}" ] && ! ping -c 1 -q 8.8.8.8 >/dev/null && wifi-menu
    timedatectl set-ntp true
    # Set up reflector
    pacman -Sy &&
        pacman -S --needed --noconfirm reflector
    reflector --verbose --latest 15 --sort rate --protocol https \
        --country DE --country NL --save /etc/pacman.d/mirrorlist \
        --save /etc/pacman.d/mirrorlist
}

partition_lvm_zfs() {
    OS_END="$(echo "1551+(${OS_SIZE}*1024)" | bc)MiB"
    parted --script --align optimal "${INSTALL_DISK}" \
        mklabel gpt \
        mkpart BIOS_GRUB 1MiB 2MIB \
        set 1 bios_grub on \
        mkpart ESP fat32 2MiB 551MiB \
        set 2 esp on \
        mkpart boot 551MiB 1551MiB \
        mkpart primary 1551MiB "${OS_END}" \
        mkpart primary "${OS_END}" 100%

    # give udev some time to create the new symlinks
    sleep 2
    echo -n "${LUKS_PASSPHRASE}" |
        cryptsetup -v --type luks2 --cipher aes-xts-plain64 \
        --key-size 512 --hash sha512 luksFormat "${INSTALL_DISK}-part4"
    echo -n "${LUKS_PASSPHRASE}" | cryptsetup open --type luks "${INSTALL_DISK}-part4" crypt-system
    LUKS_PARTITION_UUID_OS=$(cryptsetup luksUUID "${INSTALL_DISK}-part4")

    # setup lvm for the OS
    pvcreate /dev/mapper/crypt-system
    vgcreate vg-system /dev/mapper/crypt-system
    lvcreate -L "${SWAP_SIZE}"G vg-system -n swap
    lvcreate -l 100%FREE vg-system -n root

    # create OS filesystem and swap
    mkfs.xfs -L root /dev/mapper/vg--system-root
    mkswap /dev/mapper/vg--system-swap
    swapon /dev/mapper/vg--system-swap
    mount /dev/mapper/vg--system-root /mnt

    # create a keyfile and add it to LUKS partition for ZFS so it unlocks
    # without entering our password twice
    dd bs=1 if=/dev/random of="/etc/zfs_keyfile" count=32
    chmod 600 "/etc/zfs_keyfile"

    # setup ZFS
    zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -O encryption=aes-256-gcm \
    -O keylocation=file:///etc/zfs_keyfile -O keyformat=raw \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -O relatime=on \
    -O xattr=sa -O mountpoint=none dpool \
    -R /mnt "${INSTALL_DISK}"-part5
    zfs create -o mountpoint=/home dpool/home
    zfs create -o mountpoint=/var/lib/docker dpool/docker

    # setup boot partition
    mkfs.ext4 -L boot "${INSTALL_DISK}-part3"
    mkdir -p /mnt/boot && mount "${INSTALL_DISK}-part3" /mnt/boot

    # setup ESP
    mkfs.fat -F32 -n ESP "${INSTALL_DISK}-part2"
    mkdir -p /mnt/boot/esp && mount "${INSTALL_DISK}-part2" /mnt/boot/esp
}

install() {
    declare -a EXTRA_PACKAGES
    MODULES=""

    if [[ "${IS_INTEL_CPU}" -eq 1 ]]; then
        EXTRA_PACKAGES=("intel-ucode")
        MODULES="zfs intel_agp i915"
        set +e
        read -r -d '' INITRD <<-EOM
			initrd /intel-ucode.img
			initrd /initramfs-linux.img
EOM
        set -e
    elif [[ "${IS_AMD_CPU}" -eq 1 ]]; then
        EXTRA_PACKAGES=("amd-ucode")
        MODULES="zfs amdgpu"
        set +e
        read -r -d '' INITRD <<-EOM
			initrd /amd-ucode.img
			initrd /initramfs-linux.img
EOM
        set -e
    else
        INITRD="initrd /initramfs-linux.img"
    fi
    FSPOINTS="resume=/dev/mapper/vg--system-swap root=/dev/mapper/vg--system-root"
    EXTRA_PACKAGES+=("xfsprogs")
    pacstrap /mnt base base-devel dialog dhcpcd netctl iw iwd efibootmgr \
        linux linux-firmware lvm2 grub cryptsetup terminus-font apparmor \
        zfs-linux zfs-utils python-cffi "${EXTRA_PACKAGES[@]}"
    genfstab -U /mnt >> /mnt/etc/fstab
    # genfstab puts our zfs datasets into /ec/fstab, which causes all sorts
    # of problems on reboot. Remove them
    # sed does not backtrack, therefore reverse file, search for zfs, then
    # remove that line and one more (which is the comment) and re-reverse it
    tac /mnt/etc/fstab | sed -r '/.*\Wzfs\W.*/I,+1 d' > /tmp/fstab.tmp
    tac /tmp/fstab.tmp > /mnt/etc/fstab

    cp -r "${mydir}"/etc/** /mnt/etc
    cp "/etc/zfs_keyfile" /mnt/etc/zfs_keyfile
    chmod 600 /mnt/etc/zfs_keyfile

    cp "${mydir}/arch_install_zfs_chroot.sh" /mnt
    arch-chroot /mnt /usr/bin/env \
        MODULES="${MODULES}" \
        HOSTNAME="${HOSTNAME}" \
        HOSTNAME_FQDN="${HOSTNAME_FQDN}" \
        ROOT_PASSWORD="${ROOT_PASSWORD}" \
        LUKS_PARTITION_UUID_OS="${LUKS_PARTITION_UUID_OS}" \
        INSTALL_DISK="${INSTALL_DISK}" \
        IS_EFI="${IS_EFI}" \
        FSPOINTS="${FSPOINTS}" \
        /bin/bash --login -c /arch_install_zfs_chroot.sh
    rm /mnt/arch_install_zfs_chroot.sh
}

function tear_down() {
    swapoff -a
    zpool export dpool
    umount -R /mnt
    cryptsetup close crypt-data
    cryptsetup close crypt-system
}

if [ "$(id -u)" != 0 ]; then
    echo "Please execute with root rights."
    exit 1
fi

if ! modinfo zfs &>/dev/null; then
    echo "ZFS kernel module not available"
    exit 1
fi

if [ "$(systemd-detect-virt)" == 'kvm' ]; then # vagrant box, install stuff
    VIRT=1
    echo "Virtualization detected."
fi

preinstall
setup
partition_lvm_zfs
install
#tear_down
