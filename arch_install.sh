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
  grep vendor_id /proc/cpuinfo | grep -q Intel && IS_INTEL_CPU=1 ||
    IS_INTEL_CPU=0
  grep vendor_id /proc/cpuinfo | grep -q AMD && IS_AMD_CPU=1 ||
    IS_AMD_CPU=0
  lspci -mm | grep -q "VGA.*AMD" && IS_AMD_GPU=1 || IS_AMD_GPU=0

  [ -d /sys/firmware/efi ] && IS_EFI=true || IS_EFI=false
  [ ${IS_EFI} == false ] && USE_GRUB=1 && USE_SYSTEMD_BOOT=0

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
    bootstrap_dialog_yesno --title "Encrypted /boot" --yesno "Encrypt boot (implies GRUB)?\n" 8 60
    ENCRYPTED_BOOT="${dialog_result}"
    [[ "${ENCRYPTED_BOOT}" -eq 1 ]] && ENCRYPT_BOOT=false || ENCRYPT_BOOT=true
    [[ "${ENCRYPT_BOOT}" == true ]] && USE_GRUB=1
  fi

  if [ -z "${USE_GRUB:-}" ] && [ -z "${USE_SYSTEMD_BOOT}" ]; then
    declare -a loaders
    loaders=("systemd-boot" "Minimal Bootloader (recommended)" "grub" "Fully blown operating system (not recommended)")
    bootstrap_dialog --title "Bootloader" \
      --menu "Use which bootloader?" 0 0 0 \
      "${loaders[@]}"
    [[ "${dialog_result}" == "grub" ]] && USE_GRUB=1 || USE_GRUB=0
    [[ "${dialog_result}" == "systemd-boot" ]] && USE_SYSTEMD_BOOT=1 || USE_SYSTEMD_BOOT=0
  fi

  if [ -z "${OS_SIZE:-}" ]; then
    bootstrap_dialog --title "OS Size" --inputbox "Please enter a size of partition for OS in GB.\n" 8 60
    OS_SIZE="$dialog_result"
  fi

  if [ -z "${SWAP_SIZE:-}" ]; then
    bootstrap_dialog --title "Swap Size" --inputbox "Please enter a swap size in GB. 0 to disable.\n" 8 60
    SWAP_SIZE="$dialog_result"
    [[ "${SWAP_SIZE}" == "0" ]] && SWAP_ENABLED=false || SWAP_ENABLED=true
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

  bootstrap_dialog_non_mandatory --title "WARNING" \
    --msgbox "This script will NUKE Partitions 1 to 3 on ${INSTALL_DISK}.\nPress <Enter> to continue or <Esc> to cancel.\n" \
    6 60

  clear

  if [ ! -e "${INSTALL_DISK}" ]; then
    echo "${red}${INSTALL_DISK} does not exist!${reset}"
    exit 1
  fi

  case "${IS_EFI}" in
  true) echo "${green}Performing UEFI install${reset}" ;;
  false) echo "${green}Performing legacy BIOS install${reset}" ;;
  esac
}

preinstall() {
  # load necessary modules incase arch decides to update the kernel mid-flight
  modprobe dm_mod && modprobe dm_crypt && modprobe btrfs && modprobe vfat
  echo "${green}Resizing /run/archiso/cowspace to 4GB to facilitate updates"
  mount -o remount,size=4G /run/archiso/cowspace
  # install needed stuff for install
  echo "${green}Installing necessary packages${reset}"
  pacman -Sy --needed --noconfirm parted util-linux dialog bc dosfstools \
    arch-install-scripts gptfdisk openssl btrfs-progs
  # set keys to German
  loadkeys de
  # enable NTP
  timedatectl set-ntp true
  # Set up reflector
  echo "${green}Setting up reflector${reset}"
  pacman -S --needed --noconfirm reflector
  reflector --verbose --latest 8 --sort rate --protocol https \
    --country DE --country NL --save /etc/pacman.d/mirrorlist \
    --save /etc/pacman.d/mirrorlist
}

partition() {
  echo "${green}Setting up partitions${reset}"
  # calculate end of our OS partition
  #OS_END="$(echo "1551+(${LVM_SIZE}*1024)" | bc)MiB"
  # create partitions
  for partition in 1 2 3; do
    sgdisk --delete=${partition} "${INSTALL_DISK}" || true
  done
  # EFI / Boot
  sgdisk --new=1:0:+1G -c 1:"EFI ESP" -t 1:ef00 "${INSTALL_DISK}"
  # swap
  if [ "${SWAP_ENABLED}" = true ]; then
    sgdisk --new=2:0:+"${SWAP_SIZE}G" -c 2:"swap" -t 2:8200 "${INSTALL_DISK}"
  fi
  # root
  sgdisk --new=3:0:+"${OS_SIZE}G" -c 3:"system" -t 2:8300 "${INSTALL_DISK}"

  # try to re-read partitions for good measure...
  partprobe "${INSTALL_DISK}"
  # ... still, give udev some time to create the new symlinks
  sleep 2

  # totally wipe old fs information
  for partition in 1 2 3; do
    wipefs -af "${INSTALL_DISK}"-part${partition}
  done

  # create boot luks encrypted partition with forced iterations since grub is dog slow
  # 200000 should be plenty for now, tho
  #echo -n "${LUKS_PASSPHRASE}" |
  #    cryptsetup -v --type luks1 --pbkdf-force-iterations 200000 \
  #    --cipher aes-xts-plain64 \
  #    --key-size 512 --hash sha512 luksFormat "${INSTALL_DISK}-part3"
  #if [ "${ENCRYPT_BOOT}" = true ]; then
  #    echo -n "${LUKS_PASSPHRASE}" |
  #        cryptsetup -v --type luks1 \
  #        --cipher aes-xts-plain64 \
  #        --key-size 512 --hash sha512 luksFormat "${INSTALL_DISK}-part2"
  #    echo -n "${LUKS_PASSPHRASE}" | cryptsetup open --type luks "${INSTALL_DISK}-part2" \
  #        crypt-boot
  #    LUKS_PARTITION_UUID_BOOT=$(cryptsetup luksUUID "${INSTALL_DISK}-part2")
  #fi
  # create swap encrypted partition
  if [ "${SWAP_ENABLED}" = true ]; then
    echo -n "${LUKS_PASSPHRASE}" |
      cryptsetup -v --type luks2 --cipher aes-xts-plain64 \
        --key-size 512 --hash sha512 luksFormat "${INSTALL_DISK}-part2"
    echo -n "${LUKS_PASSPHRASE}" | cryptsetup open --type luks "${INSTALL_DISK}-part2" \
      crypt-swap
    LUKS_PARTITION_UUID_SWAP=$(cryptsetup luksUUID "${INSTALL_DISK}-part2")
  fi
  # create OS luks encrypted partition
  echo -n "${LUKS_PASSPHRASE}" |
    cryptsetup -v --type luks2 --cipher aes-xts-plain64 \
      --key-size 512 --hash sha512 luksFormat "${INSTALL_DISK}-part3"
  echo -n "${LUKS_PASSPHRASE}" | cryptsetup open --type luks "${INSTALL_DISK}-part3" \
    crypt-system
  LUKS_PARTITION_UUID_OS=$(cryptsetup luksUUID "${INSTALL_DISK}-part3")

  # create OS filesystem and swap
  mkfs.btrfs -L root /dev/mapper/crypt-system
  mount /dev/mapper/crypt-system /mnt

  if [ "${SWAP_ENABLED}" = true ]; then
    mkswap /dev/mapper/crypt-swap
    swapon /dev/mapper/crypt-swap
  fi

  # create btrfs subvolumes
  btrfs subvolume create /mnt/@
  # don't create anything non / for now, we are using zfs for the foreseeable future
  #btrfs subvolume create /mnt/@home
  #btrfs subvolume create /mnt/@docker
  #btrfs subvolume create /mnt/@libvirt
  umount /mnt

  mount -o subvol=@,noatime,autodefrag \
    /dev/mapper/crypt-system /mnt
  # mount root btrfs into /mnt/btrfs-root and make it only root-accessible
  mkdir -p /mnt/mnt/btrfs-root &&
    chown root:root /mnt/mnt/btrfs-root &&
    chown 700 /mnt/mnt/btrfs-root
  mount -o subvolid=5,noatime,autodefrag \
    /dev/mapper/crypt-system /mnt/mnt/btrfs-root

  # on zfs for now
  #mkdir /mnt/home
  #mount -o subvol=@home,relatime,autodefrag \
  #    /dev/mapper/crypt-system /mnt/home
  #
  #mkdir -p /mnt/var/lib/docker
  #mount -o subvol=@docker,compress=none,noatime,autodefrag \
  #    /dev/mapper/crypt-system /mnt/var/lib/docker
  #mkdir -p /mnt/var/lib/libvirt
  #mount -o subvol=@libvirt,compress=none,nodatacow,noatime,noautodefrag \
  #    /dev/mapper/crypt-system /mnt/var/lib/libvirt
  ## set NOCOW on that directory - I wish btrfs had per subvolume options...
  #chattr +C /mnt/var/lib/libvirt

  # enable compression where applicable
  btrfs property set /mnt compression zstd
  #btrfs property set /mnt/home compression zstd
  #btrfs property set /mnt/var/lib/docker compression zstd

  # create extra subvolumes so we don't clobber our / snapshots
  mkdir -p /mnt/var || true
  btrfs subvolume create /mnt/var/abs
  btrfs subvolume create /mnt/var/cache
  btrfs subvolume create /mnt/var/tmp

  # setup boot partition
  #if [ "${ENCRYPT_BOOT}" = true ]; then
  #    mkfs.ext4 -f -L boot /dev/mapper/crypt-boot
  #    mount --mkdir /dev/mapper/crypt-boot /mnt/boot
  #else
  #    mkfs.ext4 -f -L boot "${INSTALL_DISK}-part2"
  #    mount --mkdir "${INSTALL_DISK}-part2" /mnt/boot
  #fi

  # setup ESP
  mkfs.fat -F32 -n ESP "${INSTALL_DISK}-part1"
  mount --mkdir "${INSTALL_DISK}-part1" /mnt/boot
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
  if [[ "${IS_AMD_GPU}" -eq 1 ]] && [[ "${IS_AMD_CPU}" -ne 1 ]]; then
    MODULES="${MODULES} amdgpu"
  fi

  FSPOINTS="root=/dev/mapper/crypt-system"
  if [ ${SWAP_ENABLED} = true ]; then
    FSPOINTS="${FSPOINTS} resume=/dev/mapper/crypt-swap"
  fi
  EXTRA_PACKAGES+=("xfsprogs" "btrfs-progs")
  [[ "${USE_GRUB}" -eq 1 ]] && EXTRA_PACKAGES+=("grub")
  pacstrap -i /mnt base base-devel dialog dhcpcd netctl iw iwd efibootmgr \
    systemd-resolvconf mkinitcpio gptfdisk parted \
    linux linux-lts linux-zen linux-firmware \
    cryptsetup terminus-font apparmor python-cffi git \
    neovim "${EXTRA_PACKAGES[@]}"
  genfstab -U /mnt >>/mnt/etc/fstab

  if [ "${ENCRYPT_BOOT}" = true ]; then
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
    if [ "${SWAP_ENABLED}" = true ]; then
      echo -n "${LUKS_PASSPHRASE}" | cryptsetup -v luksAddKey "${INSTALL_DISK}-part3" \
        /mnt/etc/luks/luks_system_keyfile
      openssl rand -hex -out /mnt/etc/luks/luks_swap_keyfile
      chown root:root /mnt/etc/luks/luks_swap_keyfile
      chmod 600 /mnt/etc/luks/luks_swap_keyfile
      echo -n "${LUKS_PASSPHRASE}" | cryptsetup -v luksAddKey "${INSTALL_DISK}-part4" \
        /mnt/etc/luks/luks_swap_keyfile
    fi
  fi

  # copy pre-generated configuration files over
  cp -r "${mydir}"/system-config/** /mnt/
  chmod 700 /root/.ssh &&
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
    LUKS_PARTITION_UUID_SWAP="${LUKS_PARTITION_UUID_SWAP:-}" \
    INSTALL_DISK="${INSTALL_DISK}" \
    IS_EFI="${IS_EFI}" \
    USE_GRUB="${USE_GRUB}" \
    USE_SYSTEMD_BOOT="${USE_SYSTEMD_BOOT}" \
    IS_INTEL_CPU="${IS_INTEL_CPU}" \
    IS_AMD_CPU="${IS_AMD_CPU}" \
    IS_AMD_GPU="${IS_AMD_GPU}" \
    FSPOINTS="${FSPOINTS}" \
    /bin/bash --login -c /arch_install_chroot.sh
  # remove temporary chroot script
  rm /mnt/arch_install_chroot.sh
}

function tear_down() {
  # tear down our installation environment
  echo "${green}Tearing down installation environment${reset}"
  swapoff -a
  rm -f /mnt/arch_install_chroot.sh
  umount -R /mnt
  [ "${ENCRYPT_BOOT}" = true ] && cryptsetup close crypt-boot
  [ "${SWAP_ENABLED}" = true ] && cryptsetup close crypt-swap
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
