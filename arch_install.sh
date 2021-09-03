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
    # install needed stuff for install
    echo "${green}Installing necessary packages${reset}"
    pacman -Sy --needed --noconfirm parted util-linux dialog bc dosfstools \
        arch-install-scripts btrfs-progs lvm2 gptfdisk openssl
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

partition_lvm_btrfs() {
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
    sgdisk --new=4:0:0 -c 4:"system" -t 4:8309 ${INSTALL_DISK}

    # try to re-read partitions for good measure...
    partprobe ${INSTALL_DISK}

    # ... still, give udev some time to create the new symlinks
    sleep 2
    # create boot luks encrypted partition with forced iterations since grub is dog slow
    # 200000 should be plenty for now, tho
    echo -n "${LUKS_PASSPHRASE}" |
        cryptsetup -v --type luks1 --pbkdf-force-iterations 200000 \
        --cipher aes-xts-plain64 \
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

    # create swap
    mkswap /dev/mapper/vg--system-swap
    swapon /dev/mapper/vg--system-swap

    mkfs.btrfs -L root /dev/mapper/vg--system-root
    mount /dev/mapper/vg--system-root /mnt
    # convention: subvolumes used as top-level mountpoints start with @
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@docker
    btrfs subvolume create /mnt/@libvirt
    btrfs subvolume create /mnt/@log
    umount /mnt

    mount -o subvol=@,noatime,autodefrag \
        /dev/mapper/vg--system-root /mnt
    # mount root btrfs into /mnt/btrfs-root and make it only root-accessible
    mkdir -p /mnt/mnt/btrfs-root && \
        chown root:root /mnt/mnt/btrfs-root && \
        chown 700 /mnt/mnt/btrfs-root
    mount -o subvolid=5,noatime,autodefrag \
        /dev/mapper/vg--system-root /mnt/mnt/btrfs-root

    mkdir /mnt/{boot,home}
    mount -o subvol=@home,relatime,autodefrag \
        /dev/mapper/vg--system-root /mnt/home
    mkdir -p /mnt/var/log
    mount -o subvol=@log,compress=none,noatime,autodefrag \
        /dev/mapper/vg--system-root /mnt/var/log

    mkdir -p /mnt/var/lib/docker
    mount -o subvol=@docker,compress=none,noatime,autodefrag \
        /dev/mapper/vg--system-root /mnt/var/lib/docker
    mkdir -p /mnt/var/lib/libvirt
    mount -o subvol=@libvirt,compress=none,nodatacow,noatime,noautodefrag \
        /dev/mapper/vg--system-root /mnt/var/lib/libvirt
    # set NOCOW on that directory - I wish btrfs had per subvolume options...
    chattr +C /mnt/var/lib/libvirt

    # enable compression where applicable
    btrfs property set /mnt compression zstd
    btrfs property set /mnt/home compression zstd
    btrfs property set /mnt/var/lib/docker compression zstd
    btrfs property set /mnt/var/log compression zstd

    # create extra subvolumes so we don't clobber our / snapshots
    btrfs subvolume create /mnt/var/abs
    btrfs subvolume create /mnt/var/cache
    btrfs subvolume create /mnt/var/tmp

    # setup boot partition
    mkfs.ext4 -L boot /dev/mapper/crypt-boot
    mkdir -p /mnt/boot && mount /dev/mapper/crypt-boot /mnt/boot

    # setup ESP
    mkfs.fat -F32 -n ESP "${INSTALL_DISK}-part2"
    mkdir -p /mnt/boot/efi && mount "${INSTALL_DISK}-part2" /mnt/boot/efi
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
    FSPOINTS="resume=/dev/mapper/vg--system-swap root=/dev/mapper/vg--system-root"
    EXTRA_PACKAGES+=("xfsprogs")
    pacstrap -i /mnt base base-devel dialog dhcpcd netctl iw iwd efibootmgr \
		systemd-resolvconf mkinitcpio zram-generator \
        linux linux-lts linux-firmware lvm2 grub cryptsetup terminus-font \
        apparmor btrfs-progs python-cffi git \
        neovim "${EXTRA_PACKAGES[@]}"
    genfstab -U /mnt >>/mnt/etc/fstab

    # generate a keyfile to be embedded in initrd so we don't have to enter our password twice
    mkdir /mnt/etc/luks && chown root:root /mnt/etc/luks && chmod 700 /mnt/etc/luks
    openssl rand -hex -out /mnt/etc/luks/luks_boot_keyfile
    chown root:root /mnt/etc/luks/luks_boot_keyfile
    chmod 600 /mnt/etc/luks/luks_boot_keyfile
    echo -n "${LUKS_PASSPHRASE}" | cryptsetup -v luksAddKey "${INSTALL_DISK}-part3" \
        /mnt/etc/luks/luks_boot_keyfile
    openssl rand -hex -out /mnt/etc/luks/luks_system_keyfile
    chown root:root /mnt/etc/luks/luks_system_keyfile
    chmod 600 /mnt/etc/luks/luks_system_keyfile
    echo -n "${LUKS_PASSPHRASE}" | cryptsetup -v luksAddKey "${INSTALL_DISK}-part4" \
        /mnt/etc/luks/luks_system_keyfile

    # copy pre-generated configuration files over
    cp -r "${mydir}"/etc/** /mnt/etc

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
    umount -R /mnt
    cryptsetup close crypt-boot
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
partition_lvm_btrfs
install
tear_down

echo "${green}Installation finished${reset}"
