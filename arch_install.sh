#!/bin/bash

set -Eeuxo pipefail

red=$(tput setaf 1)
green=$(tput setaf 2)
reset=$(tput sgr0)

mydir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

bootstrap_dialog() {
    dialog_result=$(dialog --clear --stdout --backtitle "Arch bootstrapper" --no-shadow "$@" 2>/dev/null)
    if [ -z "${dialog_result}" ]; then
        clear
        exit 1
    fi
}
bootstrap_dialog_non_mandatory() {
    dialog_result=$(dialog --clear --stdout --backtitle "Arch bootstrapper" --no-shadow "$@" 2>/dev/null)
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
    if [ -z "${LVM_SIZE:-}" ]; then
        bootstrap_dialog --title "LVM Size" --inputbox "Please enter a size of LVM partition for OS and swap (combined) in GB.\n" 8 60
        LVM_SIZE="$dialog_result"
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
            echo "${red}Passwords did not match.${reset}"
            exit 3
        fi
    fi

    if [ -z "${ROOT_PASSWORD:-}" ]; then
        bootstrap_dialog --title "Root password" --passwordbox "Please enter a strong password for the root user.\n" 8 60
        ROOT_PASSWORD="$dialog_result"
        bootstrap_dialog --title "Root password" --passwordbox "Please re-enter passphrase to verify.\n" 8 60
        ROOT_PASSWORD_VERIFY="$dialog_result"
        if [[ "${ROOT_PASSWORD}" != "${ROOT_PASSWORD_VERIFY}" ]]; then
            echo "${red}Passwords did not match.${reset}"
            exit 3
        fi
    fi

    bootstrap_dialog_non_mandatory --title "WARNING" --msgbox "This script will NUKE ${INSTALL_DISK}.\nPress <Enter> to continue or <Esc> to cancel.\n" 6 60

    clear

    if [ ! -e "${INSTALL_DISK}" ]; then
        echo "${red}${INSTALL_DISK} does not exist!${reset}"
        exit 1
    fi

    grep vendor_id /proc/cpuinfo | grep -q Intel && IS_INTEL_CPU=1 ||
        IS_INTEL_CPU=0
    grep vendor_id /proc/cpuinfo | grep -q AMD && IS_AMD_CPU=1 ||
        IS_AMD_CPU=0
    [ -d /sys/firmware/efi ] && IS_EFI=true || IS_EFI=false
    case "${IS_EFI}" in
    true) echo "${green}Performing UEFI install${reset}" ;;
    false) echo "${green}Performing legacy BIOS install${reset}" ;;
    esac
}

preinstall() {
    sudo modprobe dm_mod zfs
    # install needed stuff for install
    echo "${green}Installing necessary packages${reset}"
    pacman -Sy --needed --noconfirm parted util-linux dialog bc dosfstools \
        arch-install-scripts xfsprogs lvm2 gptfdisk openssl
    # set keys to German
    loadkeys de
    # enable NTP
    timedatectl set-ntp true
    # Set up reflector
    echo "${green}Setting up reflector${reset}"
    pacman -Sy &&
        pacman -S --needed --noconfirm reflector
    reflector --verbose --latest 15 --sort rate --protocol https \
        --country DE --country NL --save /etc/pacman.d/mirrorlist \
        --save /etc/pacman.d/mirrorlist
}

partition_lvm_zfs() {
    echo "${green}Setting up partitions${reset}"
    # calculate end of our OS partition
    OS_END="$(echo "1551+(${LVM_SIZE}*1024)" | bc)MiB"
    # create partitions
    sgdisk --zap-all ${INSTALL_DISK}
    # grub
    sgdisk --new=1:0:+2M -c 1:"BIOS boot" -t 1:ef02 ${INSTALL_DISK}
    # EFI
    sgdisk --new=2:0:+512M -c 2:"EFI ESP" -t 2:ef00 ${INSTALL_DISK}
    # boot
    sgdisk --new=3:0:+5G -c 3:"boot" -t 3:8309 ${INSTALL_DISK}
    # data
    sgdisk --new=4:0:+${LVM_SIZE}G -c 4:"system" -t 4:8309 ${INSTALL_DISK}
	# zfs
	sgdisk --new:5:0:0 -c 5:"dpool" -t 5:bf01 ${INSTALL_DISK}

    # give udev some time to create the new symlinks
    sleep 2
    # create boot luks encrypted partition
    echo -n "${LUKS_PASSPHRASE}" |
        cryptsetup -v --type luks1 --cipher aes-xts-plain64 \
            --key-size 512 --hash sha512 luksFormat "${INSTALL_DISK}-part3"
    echo -n "${LUKS_PASSPHRASE}" | cryptsetup open --type luks "${INSTALL_DISK}-part3" crypt-boot
    LUKS_PARTITION_UUID_BOOT=$(cryptsetup luksUUID "${INSTALL_DISK}-part3")
    # create OS luks encrypted partition
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

    # create a keyfile and save it to LUKS partition (later) for ZFS so it
    # unlocks without entering our password twice
    openssl rand -hex -out "/etc/zfs/zfskey_dpool_${HOSTNAME_FQDN}" 32
    chown root:root "/etc/zfs/zfskey_dpool_${HOSTNAME_FQDN}" &&
        chmod 600 "/etc/zfs/zfskey_dpool_${HOSTNAME_FQDN}"

    # setup ZFS pool
    zpool create -f \
        -o ashift=12 \
        -o autotrim=on \
        -O encryption=aes-256-gcm \
        -O keylocation="file:///etc/zfskey_dpool_${HOSTNAME_FQDN}" \
        -O keyformat=hex -O acltype=posixacl -O compression=zstd \
        -O dnodesize=auto -O normalization=formD -O relatime=on \
        -O xattr=sa -O canmount=off -O mountpoint=/ dpool \
        -R /mnt "${INSTALL_DISK}"-part5
    # setup generic ZFS datasets
    zfs create -o mountpoint=/home dpool/home
    zfs create -o mountpoint=/root dpool/home/root
    chown root:root /mnt/root && chmod 700 /mnt/root
    zfs create -o mountpoint=/var/lib/docker dpool/docker
    zfs create -o canmount=off -o mountpoint=none dpool/libvirt
    zfs create -o mountpoint=/var/lib/libvirt/images dpool/libvirt/images

    # setup boot partition
    mkfs.ext4 -L boot /dev/mapper/crypt-boot
    mkdir -p /mnt/boot && mount /dev/mapper/crypt-boot /mnt/boot

    # setup ESP
    mkfs.fat -F32 -n ESP "${INSTALL_DISK}-part2"
    mkdir -p /mnt/efi && mount "${INSTALL_DISK}-part2" /mnt/efi
}

install() {
    declare -a EXTRA_PACKAGES
    MODULES=""

    # probably not needed to bake zfs into the initrd, but it won't hurt either
    if [[ "${IS_INTEL_CPU}" -eq 1 ]]; then
        EXTRA_PACKAGES=("intel-ucode")
        MODULES="zfs intel_agp i915"
    elif [[ "${IS_AMD_CPU}" -eq 1 ]]; then
        EXTRA_PACKAGES=("amd-ucode")
        MODULES="zfs amdgpu"
    fi
    FSPOINTS="resume=/dev/mapper/vg--system-swap root=/dev/mapper/vg--system-root"
    EXTRA_PACKAGES+=("xfsprogs")
    pacstrap -i /mnt base base-devel dialog dhcpcd netctl iw iwd efibootmgr \
        linux linux-lts linux-firmware lvm2 grub cryptsetup terminus-font \
        apparmor zfs-linux zfs-linux-lts zfs-utils python-cffi git \
        neovim "${EXTRA_PACKAGES[@]}"
    genfstab -U /mnt >>/mnt/etc/fstab
    # genfstab puts our zfs datasets into /ec/fstab, which causes all sorts
    # of problems on reboot. Remove them
    # sed does not backtrack, therefore reverse file, search for zfs, then
    # remove that line and one more (which is the comment) and re-reverse it
    tac /mnt/etc/fstab | sed -r '/.*\Wzfs\W.*/I,+1 d' >/tmp/fstab.tmp
    tac /tmp/fstab.tmp >/mnt/etc/fstab
    # generate a keyfile to be embedded in initrd so we don't have to enter our password twice
    mkdir /mnt/root/secrets && chown root:root /mnt/root/secrets && chmod 700 /mnt/root/secrets
    openssl rand -hex -out /mnt/root/secrets/luks_boot_keyfile
    chown root:root /mnt/root/secrets/luks_boot_keyfile
    chmod 600 /mnt/root/secrets/luks_boot_keyfile
    echo -n "${LUKS_PASSPHRASE}" | cryptsetup -v luksAddKey "${INSTALL_DISK}-part3" /mnt/root/secrets/luks_boot_keyfile
    openssl rand -hex -out /mnt/root/secrets/luks_system_keyfile
    chown root:root /mnt/root/secrets/luks_system_keyfile
    chmod 600 /mnt/root/secrets/luks_system_keyfile
    echo -n "${LUKS_PASSPHRASE}" | cryptsetup -v luksAddKey "${INSTALL_DISK}-part4" /mnt/root/secrets/luks_system_keyfile

    # copy pre-generated configuration files over
    cp -r "${mydir}"/etc/** /mnt/etc

    # copy over our ZFS key
	mkdir /mnt/etc/zfs
    cp "/etc/zfs/zfskey_dpool_${HOSTNAME_FQDN}" \
        "/mnt/etc/zfs/zfskey_dpool_${HOSTNAME_FQDN}"
    chown root:root "/mnt/etc/zfs/zfskey_dpool_${HOSTNAME_FQDN}" && \
        chmod 600 "/mnt/etc/zfs/zfskey_dpool_${HOSTNAME_FQDN}"

    echo "${green}Entering chroot${reset}"
    # enter chroot and perform initial configuration
    cp "${mydir}/arch_install_chroot.sh" /mnt
    arch-chroot /mnt /usr/bin/env \
        MODULES="${MODULES}" \
        HOSTNAME="${HOSTNAME}" \
        HOSTNAME_FQDN="${HOSTNAME_FQDN}" \
        ROOT_PASSWORD="${ROOT_PASSWORD}" \
        LUKS_PARTITION_UUID_BOOT="${LUKS_PARTITION_UUID_BOOT}" \
        LUKS_PARTITION_UUID_OS="${LUKS_PARTITION_UUID_OS}" \
        INSTALL_DISK="${INSTALL_DISK}" \
        IS_EFI="${IS_EFI}" \
        FSPOINTS="${FSPOINTS}" \
        /bin/bash --login -c /arch_install_chroot.sh
    # remove temporary chroot script
    rm /mnt/arch_install_chroot.sh
}

function tear_down() {
    # tear down our installation environment
    echo "${green}Tearing down installation environment${reset}"
    swapoff -a
    zpool export dpool
    umount -R /mnt
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
    # VIRT=1
    echo "Virtualization detected."
fi

echo "${green}Installation starting${reset}"

preinstall
setup
partition_lvm_zfs
install
tear_down

echo "${green}Installation finished${reset}"
