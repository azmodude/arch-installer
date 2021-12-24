#!/bin/bash

set -Eeuxo pipefail

green=$(tput setaf 2)
reset=$(tput sgr0)

echo "${green}Entered chroot${reset}"

echo "${green}Setting timezone and time${reset}"
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
echo "${green}Generating locale${reset}"
locale-gen
echo "${green}Configuring hostname${reset}"
echo "${HOSTNAME_FQDN}" >/etc/hostname
cat >/etc/hosts <<END
127.0.0.1   localhost.localdomain localhost
127.0.1.1   ${HOSTNAME_FQDN} ${HOSTNAME%%.*}
END

echo "${green}Enabling AppArmor${reset}"
sed -r -i 's/^#(write-cache)$/\1/' /etc/apparmor/parser.conf
systemctl enable apparmor.service

# setup systemd-resolved
systemctl enable systemd-resolved.service
# enable fstrim
systemctl enable fstrim.timer
# enable btrfs monthly scrub for /
systemctl enable btrfs-scrub@-.timer

# setup zram and oomd
systemctl enable systemd-zram-setup@zram0.service systemd-oomd.service

echo "${green}Cloning arch-installer repository to /root${reset}"
git clone https://github.com/azmodude/arch-installer /root/arch-installer
echo "${green}Cloning arch-bootstrap repository to /root${reset}"
git clone https://github.com/azmodude/arch-bootstrap /root/arch-bootstrap

echo "${green}Generating /etc/crypttab${reset}"

if [[ -n "${LUKS_PARTITION_UUID_BOOT}" ]]; then
    cat >/etc/crypttab <<END
crypt-system UUID=${LUKS_PARTITION_UUID_OS} /etc/luks/luks_system_keyfile discard
crypt-boot UUID=${LUKS_PARTITION_UUID_BOOT} /etc/luks/luks_boot_keyfile discard
END
    FILES="/etc/luks/luks_system_keyfile /etc/luks/luks_boot_keyfile"
else
    cat >/etc/crypttab <<END
crypt-system UUID=${LUKS_PARTITION_UUID_OS} none discard
END
    FILES=""
fi
if [[ -n "${LUKS_PARTITION_UUID_SWAP}" ]]; then
    if [[ -n "${LUKS_PARTITION_UUID_BOOT}" ]]; then
        echo "crypt-swap UUID=${LUKS_PARTITION_UUID_SWAP} /etc/luks/luks_swap_keyfile discard" >> /etc/crypttab
        FILES="${FILES} /etc/luks/luks_swap_keyfile"
    else
        echo "crypt-swap UUID=${LUKS_PARTITION_UUID_SWAP} none discard" >> /etc/crypttab
    fi
fi

# embed our crypttab in the initramfs for automatic unlock of volumes
ln -s /etc/crypttab /etc/crypttab.initramfs

echo "${green}Generating mkinitcpio.conf${reset}"
cat >/etc/mkinitcpio.conf <<END
MODULES=(${MODULES})
# We don't really need luks_boot_keyfile this early, here for good measure
FILES=(${FILES})
BINARIES=()
HOOKS="base systemd autodetect modconf sd-vconsole keyboard block sd-encrypt filesystems fsck"
COMPRESSION=zstd
END
echo "${green}Generating initrd${reset}"
mkinitcpio -p linux
mkinitcpio -p linux-lts
mkinitcpio -p linux-zen
echo "${green}Setting root password${reset}"
echo "root:${ROOT_PASSWORD}" | chpasswd
echo "${green}Installing bootloader${reset}"
sed -r -i "s/GRUB_CMDLINE_LINUX_DEFAULT=.*$/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/" /etc/default/grub
# cryptkey=... is kind of obsolete here, since sd-encrypt uses the embedded crypttab.initramfs
sed -r -i "s/GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX=\"cryptkey=rootfs:\/etc\/luks\/luks_system_keyfile ${FSPOINTS//\//\\/} consoleblank=120 apparmor=1 lsm=lockdown,yama,apparmor,bpf rw\"/" /etc/default/grub
sed -r -i "s/^GRUB_DEFAULT=.*$/GRUB_DEFAULT=saved/" /etc/default/grub
sed -r -i "s/^#GRUB_SAVEDEFAULT=true/GRUB_SAVEDEFAULT=true/" /etc/default/grub
sed -r -i "s/^#GRUB_DISABLE_SUBMENU=.*/GRUB_DISABLE_SUBMENU=y/" /etc/default/grub
sed -r -i "s/^#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/" /etc/default/grub

case "${IS_EFI}" in
true) grub-install --target=x86_64-efi --efi-directory=/boot/efi ;;
false) grub-install --target=i386-pc --recheck "${INSTALL_DISK}" ;;
esac
grub-mkconfig -o /boot/grub/grub.cfg
