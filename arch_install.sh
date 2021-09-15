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
bootstrap_dialog_yesno() {
    # allow errors here because no = 1 = error = abort
    set +e
    dialog_result=$(dialog --clear --stdout --backtitle "Arch bootstrapper" --no-shadow "$@" 2>/dev/null)
    dialog_result=$?
    set -e
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

    if [ -z "${ENCRYPTED_BOOT:-}" ]; then
        bootstrap_dialog_yesno --title "Encrypted /boot" --yesno "Encrypt boot?\n" 8 60
        ENCRYPTED_BOOT="${dialog_result}"
    fi

    if [ -z "${OS_SIZE:-}" ]; then
        bootstrap_dialog --title "OS Size" --inputbox "Please enter a size of partition for OS in GB.\n" 8 60
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
    # load necessary modules incase arch decides to update the kernel mid-flight
    modprobe dm_mod dm_crypt
    # install needed stuff for install
    echo "${green}Installing necessary packages${reset}"
    pacman -Sy --needed --noconfirm parted util-linux dialog bc dosfstools \
        arch-install-scripts xfsprogs gptfdisk openssl
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

partition() {
    echo "${green}Setting up partitions${reset}"
    # calculate end of our OS partition
    #OS_END="$(echo "1551+(${LVM_SIZE}*1024)" | bc)MiB"
    # create partitions
    for partition in 1 2 3 4; do
        sgdisk --delete=${partition} ${INSTALL_DISK} || true
    done
    # EFI
    sgdisk --new=1:0:+512M -c 1:"EFI ESP" -t 1:ef00 ${INSTALL_DISK}
    # boot
    sgdisk --new=2:0:+5G -c 2:"boot" -t 2:8300 ${INSTALL_DISK}
    # swap
    sgdisk --new=3:0:+${SWAP_SIZE}G -c 3:"swap" -t 3:8200 ${INSTALL_DISK}
    # root
    sgdisk --new=4:0:+${OS_SIZE}G -c 4:"system" -t 4:8300 ${INSTALL_DISK}

    # try to re-read partitions for good measure...
    partprobe ${INSTALL_DISK}

    # ... still, give udev some time to create the new symlinks
    sleep 2
    # create boot luks encrypted partition with forced iterations since grub is dog slow
    # 200000 should be plenty for now, tho
    #echo -n "${LUKS_PASSPHRASE}" |
    #    cryptsetup -v --type luks1 --pbkdf-force-iterations 200000 \
    #    --cipher aes-xts-plain64 \
    #    --key-size 512 --hash sha512 luksFormat "${INSTALL_DISK}-part3"
    if [[ "${ENCRYPTED_BOOT}" -eq 0 ]]; then
        echo -n "${LUKS_PASSPHRASE}" |
            cryptsetup -v --type luks1 \
            --cipher aes-xts-plain64 \
            --key-size 512 --hash sha512 luksFormat "${INSTALL_DISK}-part2"
        echo -n "${LUKS_PASSPHRASE}" | cryptsetup open --type luks "${INSTALL_DISK}-part2" \
            crypt-boot
        LUKS_PARTITION_UUID_BOOT=$(cryptsetup luksUUID "${INSTALL_DISK}-part2")
    fi
    # create swap encrypted partition
    echo -n "${LUKS_PASSPHRASE}" |
        cryptsetup -v --type luks2 --cipher aes-xts-plain64 \
            --key-size 512 --hash sha512 luksFormat "${INSTALL_DISK}-part3"
    echo -n "${LUKS_PASSPHRASE}" | cryptsetup open --type luks "${INSTALL_DISK}-part3" \
        crypt-swap
    LUKS_PARTITION_UUID_SWAP=$(cryptsetup luksUUID "${INSTALL_DISK}-part3")
    # create OS luks encrypted partition
    echo -n "${LUKS_PASSPHRASE}" |
        cryptsetup -v --type luks2 --cipher aes-xts-plain64 \
            --key-size 512 --hash sha512 luksFormat "${INSTALL_DISK}-part4"
    echo -n "${LUKS_PASSPHRASE}" | cryptsetup open --type luks "${INSTALL_DISK}-part4" \
        crypt-system
    LUKS_PARTITION_UUID_OS=$(cryptsetup luksUUID "${INSTALL_DISK}-part4")

    # create OS filesystem and swap
    mkfs.xfs -L root /dev/mapper/crypt-system
    mount /dev/mapper/crypt-system /mnt

    mkswap /dev/mapper/crypt-swap
    swapon /dev/mapper/crypt-swap

    # setup boot partition
    if [[ "${ENCRYPTED_BOOT}" -eq 0 ]]; then
        mkfs.xfs -L boot /dev/mapper/crypt-boot
        mkdir -p /mnt/boot && mount /dev/mapper/crypt-boot /mnt/boot
    else
        mkfs.xfs -L boot ${INSTALL_DISK}-part2
        mkdir -p /mnt/boot && mount ${INSTALL_DISK}-part2 /mnt/boot
    fi

    # setup ESP
    mkfs.fat -F32 -n ESP "${INSTALL_DISK}-part1"
    mkdir -p /mnt/boot/efi && mount "${INSTALL_DISK}-part1" /mnt/boot/efi
}

install() {
    declare -a EXTRA_PACKAGES
    MODULES=""

    if [[ "${IS_INTEL_CPU}" -eq 1 ]]; then
        EXTRA_PACKAGES=("intel-ucode")
        MODULES="intel_agp i915"
    elif [[ "${IS_AMD_CPU}" -eq 1 ]]; then
        EXTRA_PACKAGES=("amd-ucode")
        MODULES="amdgpu"
    fi
    FSPOINTS="resume=/dev/mapper/crypt-swap root=/dev/mapper/crypt-system"
    EXTRA_PACKAGES+=("xfsprogs")
    pacstrap -i /mnt base base-devel dialog dhcpcd netctl iw iwd efibootmgr \
        systemd-resolvconf mkinitcpio zram-generator gptfdisk parted \
        linux linux-lts linux-zen linux-firmware grub \
        cryptsetup terminus-font apparmor python-cffi git \
        neovim "${EXTRA_PACKAGES[@]}"
    genfstab -U /mnt >>/mnt/etc/fstab

    if [[ "${ENCRYPTED_BOOT}" -eq 0 ]]; then
        # generate a keyfile to be embedded in initrd so we don't have to enter our password twice
        mkdir /mnt/etc/luks && chown root:root /mnt/etc/luks && chmod 700 /mnt/etc/luks
        openssl rand -hex -out /mnt/etc/luks/luks_boot_keyfile
        chown root:root /mnt/etc/luks/luks_boot_keyfile
        chmod 600 /mnt/etc/luks/luks_boot_keyfile
        echo -n "${LUKS_PASSPHRASE}" | cryptsetup -v luksAddKey "${INSTALL_DISK}-part2" \
            /mnt/etc/luks/luks_boot_keyfile
        openssl rand -hex -out /mnt/etc/luks/luks_system_keyfile
        chown root:root /mnt/etc/luks/luks_system_keyfile
        chmod 600 /mnt/etc/luks/luks_system_keyfile
        echo -n "${LUKS_PASSPHRASE}" | cryptsetup -v luksAddKey "${INSTALL_DISK}-part3" \
            /mnt/etc/luks/luks_system_keyfile
        openssl rand -hex -out /mnt/etc/luks/luks_swap_keyfile
        chown root:root /mnt/etc/luks/luks_swap_keyfile
        chmod 600 /mnt/etc/luks/luks_swap_keyfile
        echo -n "${LUKS_PASSPHRASE}" | cryptsetup -v luksAddKey "${INSTALL_DISK}-part4" \
            /mnt/etc/luks/luks_swap_keyfile
    fi

    # copy pre-generated configuration files over
    cp -r "${mydir}"system-config/** /mnt/
    chmod 600 /mnt/root/.ssh/authorized_keys

    echo "${green}Entering chroot${reset}"
    # enter chroot and perform initial configuration
    cp "${mydir}/arch_install_chroot.sh" /mnt
    arch-chroot /mnt /usr/bin/env \
        MODULES="${MODULES}" \
        HOSTNAME="${HOSTNAME}" \
        HOSTNAME_FQDN="${HOSTNAME_FQDN}" \
        ROOT_PASSWORD="${ROOT_PASSWORD}" \
        LUKS_PARTITION_UUID_BOOT="${LUKS_PARTITION_UUID_BOOT:-}" \
        LUKS_PARTITION_UUID_OS="${LUKS_PARTITION_UUID_OS}" \
        LUKS_PARTITION_UUID_SWAP="${LUKS_PARTITION_UUID_SWAP}" \
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
    umount -R /mnt
    cryptsetup close crypt-boot
    cryptsetup close crypt-swap
    cryptsetup close crypt-system
}

if [ "$(id -u)" != 0 ]; then
    echo "Please execute with root rights."
    exit 1
fi

if [ "$(systemd-detect-virt)" == 'kvm' ]; then # vagrant box, install stuff
    # VIRT=1
    echo "Virtualization detected."
fi

echo "${green}Installation starting${reset}"

preinstall
setup
partition
install
tear_down

echo "${green}Installation finished${reset}"
