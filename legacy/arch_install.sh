#!/bin/bash

bootstrap_dialog() {
    dialog_result=$(dialog --clear --stdout --backtitle "Arch bootstrapper" --no-shadow "$@" 2>/dev/null)
    [ -z "${dialog_result}" ] && clear && exit 1
}
bootstrap_dialog_non_mandatory() {
    dialog_result=$(dialog --clear --stdout --backtitle "ZFS bootstrapper" --no-shadow "$@" 2>/dev/null)
}

setup() {
    if [ -z "${INSTALL_DISK}" ]; then
        declare -a disks
        for disk in /dev/disk/by-id/*; do
            disks+=("${disk}" "$(basename "$(readlink "$disk")")")
        done
        bootstrap_dialog --title "Choose installation disk" \
                        --menu "Which disk to install on?" 0 0 0 \
                        "${disks[@]}"
        INSTALL_DISK="${dialog_result}"
    fi

    if [ -z "${HOSTNAME_FQDN}" ]; then
        bootstrap_dialog --title "Hostname" --inputbox "Please enter a fqdn for this host.\n" 8 60
        HOSTNAME_FQDN="$dialog_result"
    fi

    if [ -z "${DISK_LAYOUT}" ]; then
        bootstrap_dialog --title "Disk Layout" --inputbox "'btrfs' or 'lvmext4' with ext4 or 'lvmxfs' with xfs" 8 60
        DISK_LAYOUT="$dialog_result"
    fi

    if [ -z "${SWAP_SIZE}" ]; then
        bootstrap_dialog --title "SWAP SIZE" --inputbox "Please enter a swap size in GB.\n" 8 60
        SWAP_SIZE="$dialog_result"
    fi

    if [ -z "${LUKS_PASSPHRASE}" ]; then
        bootstrap_dialog --title "Disk encryption" --passwordbox "Please enter a strong passphrase for the full disk encryption.\n" 8 60
        LUKS_PASSPHRASE="$dialog_result"
        bootstrap_dialog --title "Disk encryption" --passwordbox "Please re-enter passphrase to verify.\n" 8 60
        LUKS_PASSPHRASE_VERIFY="$dialog_result"
        if [[ "${LUKS_PASSPHRASE}" != "${LUKS_PASSPHRASE_VERIFY}" ]]; then
            echo "Passwords did not match."
            exit 3
        fi
    fi

    if [ -z "${ROOT_PASSWORD}" ]; then
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
    [ "${IS_EFI}" = false ] && echo "Perorming legacy BIOS install."
}

preinstall() {
    pacman -S --needed --noconfirm parted dialog bc dosfstools \
        arch-install-scripts btrfs-progs xfsprogs lvm2
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

create_luks() {
    echo -n "${LUKS_PASSPHRASE}" |
        cryptsetup -v --type luks2 --cipher aes-xts-plain64 \
        --key-size 512 --hash sha512 luksFormat "${1}"
    echo -n "${LUKS_PASSPHRASE}" |
        cryptsetup open --type luks "${1}" crypt-system
}

partition_lvm() {
    parted --script --align optimal "${INSTALL_DISK}" \
        mklabel gpt \
        mkpart BIOS_GRUB 1MiB 2MIB \
        set 1 bios_grub on \
        mkpart ESP fat32 2MiB 551MiB \
        set 2 esp on \
        mkpart boot 551MiB 1551MiB \
        mkpart primary 1551MiB 100%

    # give udev some time to create the new symlinks
    sleep 2
    create_luks "${INSTALL_DISK}-part4"
    LUKS_PARTITION_UUID=$(cryptsetup luksUUID "${INSTALL_DISK}-part4")

    pvcreate /dev/mapper/crypt-system
    vgcreate vg-system /dev/mapper/crypt-system
    lvcreate -L "${SWAP_SIZE}"G vg-system -n swap
    lvcreate -l 100%FREE vg-system -n root

    [[ ${DISK_LAYOUT} == "lvmext4" ]] &&
        mkfs.ext4 -m 1 -L root /dev/mapper/vg--system-root
    [[ ${DISK_LAYOUT} == "lvmxfs" ]] &&
        mkfs.xfs -L root /dev/mapper/vg--system-root
    mkswap /dev/mapper/vg--system-swap
    swapon /dev/mapper/vg--system-swap
    mount /dev/mapper/vg--system-root /mnt

    mkfs.ext4 -L boot "${INSTALL_DISK}-part3"
    mount "${INSTALL_DISK}-part3" /mnt/boot

    mkfs.fat -F32 -n ESP "${INSTALL_DISK}-part2"
    mkdir -p /mnt/boot/esp && mount "${INSTALL_DISK}-part2" /mnt/boot/esp
}

partition_btrfs() {
    #SWAP_END="$(echo "551+(${SWAP_SIZE}*1024)" | bc)MiB"
    parted --script --align optimal "${INSTALL_DISK}" \
        mklabel gpt \
        mkpart BIOS_GRUB 1MiB 2MIB \
        set 1 bios_grub on \
        mkpart ESP fat32 2MiB 551MiB \
        set 2 esp on \
        mkpart boot 551MiB 1551MiB \
        mkpart primary 1551MiB 100%

    # give udev some time to create the new symlinks
    sleep 2
    create_luks "${INSTALL_DISK}-part4"
    LUKS_PARTITION_UUID=$(cryptsetup luksUUID "${INSTALL_DISK}-part4")

    mkfs.btrfs -L root /dev/mapper/crypt-system
    mount /dev/mapper/crypt-system /mnt
    # convention: subvolumes used as mountpoints start with @
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@swap
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@docker
    btrfs subvolume create /mnt/@libvirt
    btrfs subvolume create /mnt/@var-log
    btrfs subvolume create /mnt/@srv
    umount /mnt

    mount -o subvol=@,noatime,autodefrag \
        /dev/mapper/crypt-system /mnt
    mkdir /mnt/{boot,home,swap}
    mount -o subvol=@home,relatime,autodefrag \
        /dev/mapper/crypt-system /mnt/home
    btrfs property set /mnt compression zstd
    btrfs property set /mnt/home compression zstd

    mount -o subvol=@swap,noatime,autodefrag \
        /dev/mapper/crypt-system /mnt/swap

    mkdir -p /mnt/srv
    mount -o subvol=@srv,compress=none,noatime,autodefrag \
        /dev/mapper/crypt-system /mnt/srv

    mkdir -p /mnt/var/log
    mount -o subvol=@var-log,compress=none,noatime,autodefrag \
        /dev/mapper/crypt-system /mnt/var/log

    mkdir -p /mnt/var/lib/{docker,libvirt}
    mount -o subvol=@docker,compress=none,noatime,autodefrag \
        /dev/mapper/crypt-system /mnt/var/lib/docker
    mount -o subvol=@libvirt,compress=none,nodatacow,noatime,autodefrag \
        /dev/mapper/crypt-system /mnt/var/lib/libvirt
    # set NOCOW on that directory
    chattr +C /mnt/var/lib/libvirt

    # create extra subvolumes so we don't clobber our / snapshots
    btrfs subvolume create /mnt/var/abs
    btrfs subvolume create /mnt/var/cache
    btrfs subvolume create /mnt/var/tmp

    # create swap file
    truncate -s 0 /mnt/swap/file
    # set NOCOW on that file
    chattr +C /mnt/swap/file
    # btrfs needs swapfiles to be not compressed and fully allocated
    btrfs property set /mnt/swap/file compression none
    fallocate -l "${SWAP_SIZE}"G /mnt/swap/file
    # set right permissions
    chmod 600 /mnt/swap/file
    # finally mkswap on the file
    mkswap /mnt/swap/file

    mkfs.ext4 -L boot "${INSTALL_DISK}-part3"
    mount "${INSTALL_DISK}-part3" /mnt/boot

    mkfs.fat -F32 -n ESP "${INSTALL_DISK}-part2"
    mkdir /mnt/boot/esp && mount "${INSTALL_DISK}-part2" /mnt/boot/esp
}

install() {
    declare -a EXTRA_PACKAGES
    MODULES=""

    if [[ "${IS_INTEL_CPU}" -eq 1 ]]; then
        EXTRA_PACKAGES=("intel-ucode")
        MODULES="intel_agp i915"
        set +e
        read -r -d '' INITRD <<-EOM
			initrd /intel-ucode.img
			initrd /initramfs-linux.img
EOM
        set -e
    elif [[ "${IS_AMD_CPU}" -eq 1 ]]; then
        EXTRA_PACKAGES=("amd-ucode")
        MODULES="amdgpu"
        set +e
        read -r -d '' INITRD <<-EOM
			initrd /amd-ucode.img
			initrd /initramfs-linux.img
EOM
        set -e
    else
        INITRD="initrd /initramfs-linux.img"
    fi
    if [[ "${DISK_LAYOUT}" == 'lvmext4' ]] ||
        [[ "${DISK_LAYOUT}" == 'lvmxfs' ]]; then
        FSPOINTS="resume=/dev/mapper/vg--system-swap root=/dev/mapper/vg--system-root"
        [[ "${DISK_LAYOUT}" == 'lvmxfs' ]] && EXTRA_PACKAGES+=("xfsprogs")
    elif [[ "${DISK_LAYOUT}" == 'btrfs' ]]; then
        # hibernate on encrypted swap is a pain in the ass without lvm
        FSPOINTS="root=/dev/mapper/crypt-system rootflags=subvol=@"
        EXTRA_PACKAGES+=("btrfs-progs")
    fi
    pacstrap /mnt base base-devel dialog dhcpcd netctl iw wpa_supplicant efibootmgr \
        linux linux-firmware lvm2 grub cryptsetup terminus-font apparmor \
        "${EXTRA_PACKAGES[@]}"
    genfstab -U /mnt >>/mnt/etc/fstab

    if [ "${DISK_LAYOUT}" == 'btrfs' ]; then
        # We are using a swap file when using btrfs, put that into fstab
        printf "\n# swapfile\n/swap/file\tnone\tswap\tdefaults\t0\t0\n" >>/mnt/etc/fstab
    fi

    arch-chroot /mnt /bin/bash <<-EOF
	echo "Setting timezone and time"
	ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
	echo "Generating and setting locale"
	cat > /etc/locale.gen << END
	en_US.UTF-8 UTF-8
	de_DE.UTF-8 UTF-8
	END
	locale-gen
	echo "LANG=en_US.UTF-8" > /etc/locale.conf
	echo "Setting console settings"
	cat > /etc/vconsole.conf << END
	KEYMAP=de-latin1-nodeadkeys
	FONT=ter-v16n
	END
	echo "Configuring hostname"
	echo "${HOSTNAME_FQDN}" > /etc/hostname
	cat > /etc/hosts << END
	127.0.0.1   localhost.localdomain localhost
	127.0.1.1   ${HOSTNAME_FQDN} ${HOSTNAME%%.*}
	END
	systemctl enable apparmor.service
	echo "Generating mkinitcpio.conf"
	cat > /etc/mkinitcpio.conf << END
	MODULES=(${MODULES})
	BINARIES=()
	FILES=()
	HOOKS="base systemd autodetect modconf sd-vconsole keyboard block sd-encrypt sd-lvm2 filesystems fsck"
	COMPRESSION=gzip
	END
	mkinitcpio -p linux
	echo "Setting root passwd"
	echo "root:${ROOT_PASSWORD}" | chpasswd
	echo "vfat" > /etc/modules-load.d/vfat.conf
	echo "Installing bootloader"
	sed -r -i "s/GRUB_CMDLINE_LINUX_DEFAULT=.*$/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/" /etc/default/grub
	sed -r -i "s/GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX=\"rd.luks.name=${LUKS_PARTITION_UUID}=crypt-system rd.luks.options=discard ${FSPOINTS//\//\\/} consoleblank=120 apparmor=1 lsm=lockdown,yama,apparmor rw\"/" /etc/default/grub
	[ "${IS_EFI}" = true ] && grub-install --target=x86_64-efi --efi-directory=/boot/esp --bootloader-id=GRUB --recheck
	[ "${IS_EFI}" = false ] && grub-install --target=i386-pc --recheck ${INSTALL_DISK}
	grub-mkconfig -o /boot/grub/grub.cfg
EOF
}

function tear_down() {
    swapoff -a
    umount -R /mnt
    cryptsetup close crypt-system
}

if [ "$(id -u)" != 0 ]; then
    echo "Please execute with root rights."
    exit 1
fi

if [ "$(systemd-detect-virt)" == 'kvm' ]; then # vagrant box, install stuff
    VIRT=1
    echo "Virtualization detected."
fi

preinstall
setup

if [[ "${DISK_LAYOUT}" == "lvmext4" ]] ||
    [[ "${DISK_LAYOUT}" == "lvmxfs" ]]; then
    partition_lvm
elif [[ "${DISK_LAYOUT}" == "btrfs" ]]; then
    hash mkfs.btrfs 2>/dev/null || {
        echo >&2 "btrfs-progs required"
        exit 1
    }
    partition_btrfs
fi

install
tear_down
