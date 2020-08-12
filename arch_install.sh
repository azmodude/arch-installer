#!/bin/bash

set -Eeuxo pipefail

red=$(tput setaf 1)
green=$(tput setaf 2)
reset=$(tput sgr0)

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

    [ ! -e "${INSTALL_DISK}" ] && \
        echo "${red}${INSTALL_DISK} does not exist!${reset}" && \
        exit 1

    grep vendor_id /proc/cpuinfo | grep -q Intel && IS_INTEL_CPU=1 ||
        IS_INTEL_CPU=0
    grep vendor_id /proc/cpuinfo | grep -q AMD && IS_AMD_CPU=1 ||
        IS_AMD_CPU=0
    [ -d /sys/firmware/efi ] && IS_EFI=true || IS_EFI=false
    case "${IS_EFI}" in
        (true)  echo "${green}Performing UEFI install${reset}";;
        (false) echo "${green}Performing legacy BIOS install${reset}";;
    esac
}

preinstall() {
    # install needed stuff for install
    echo "${green}Installing necessary packages${reset}"
    pacman -Sy --needed --noconfirm parted util-linux dialog bc dosfstools \
        arch-install-scripts xfsprogs lvm2 zfs-utils
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
    OS_END="$(echo "1551+(${OS_SIZE}*1024)" | bc)MiB"
    # create partitions
    parted --script --align optimal "${INSTALL_DISK}" \
        mklabel gpt \
        mkpart BIOS_GRUB 1MiB 2MIB \
        set 1 bios_grub on \
        mkpart ESP fat32 2MiB 551MiB \
        set 2 esp on \
        mkpart boot 551MiB 1551MiB \
        mkpart primary 1551MiB "${OS_END}" \
        mkpart primary "${OS_END}" 100%

    # change ZFS partition to its correct type, default is 8300 for linux
    # see https://en.wikipedia.org/wiki/GUID_Partition_Table for GUID ids
    sfdisk --part-type "${INSTALL_DISK}" 5 6A898CC3-1DD2-11B2-99A6-080020736631

    # give udev some time to create the new symlinks
    sleep 2
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
    # unlocks # without entering our password twice
    dd bs=1 if=/dev/random of="/etc/zfskey" count=32
    chown root:root "/etc/zfskey" && chmod 600 "/etc/zfskey"

    # setup ZFS pool
    zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -O encryption=aes-256-gcm \
    -O keylocation=file:///etc/zfskey -O keyformat=raw \
    -O acltype=posixacl -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -O relatime=on \
    -O xattr=sa -O canmount=off -O mountpoint=/ dpool \
    -R /mnt "${INSTALL_DISK}"-part5
    # setup generic ZFS datasets
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
    pacstrap /mnt base base-devel dialog dhcpcd netctl iw iwd efibootmgr \
        linux linux-firmware lvm2 grub cryptsetup terminus-font apparmor \
        zfs-linux zfs-utils python-cffi neovim "${EXTRA_PACKAGES[@]}"
    genfstab -U /mnt >> /mnt/etc/fstab
    # genfstab puts our zfs datasets into /ec/fstab, which causes all sorts
    # of problems on reboot. Remove them
    # sed does not backtrack, therefore reverse file, search for zfs, then
    # remove that line and one more (which is the comment) and re-reverse it
    tac /mnt/etc/fstab | sed -r '/.*\Wzfs\W.*/I,+1 d' > /tmp/fstab.tmp
    tac /tmp/fstab.tmp > /mnt/etc/fstab

    # copy pre-generated configuration files over
    cp -r "${mydir}"/etc/** /mnt/etc

    # copy over our ZFS key
    cp "/etc/zfskey" /mnt/etc/zfskey
    chown root:root && chmod 600 /mnt/etc/zfskey

    echo "${green}Entering chroot${reset}"
    # enter chroot and perform initial configuration
    cp "${mydir}/arch_install_chroot.sh" /mnt
    arch-chroot /mnt /usr/bin/env \
        MODULES="${MODULES}" \
        HOSTNAME="${HOSTNAME}" \
        HOSTNAME_FQDN="${HOSTNAME_FQDN}" \
        ROOT_PASSWORD="${ROOT_PASSWORD}" \
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
