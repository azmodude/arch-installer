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

# get and lsign archzfs keys
pacman-key --keyserver keyserver.ubuntu.com -r DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76

echo "${green}Enabling AppArmor${reset}"
sed -r -i 's/^#(write-cache)$/\1/' /etc/apparmor/parser.conf
systemctl enable apparmor.service

echo "${green}Setting up and enabling ZFS${reset}"
zpool set cachefile=/etc/zfs/zpool.cache dpool
# enable zfs services
systemctl enable zfs-import-cache.service
systemctl enable zfs-import.target
systemctl enable zfs-mount.service
systemctl enable zfs.target
# automatically load keys on startup
systemctl enable zfs-load-key.service
# enable monthly scrubbing
systemctl enable zfs-scrub@dpool.timer

# bind mount /root into /home/root for better organization
systemctl enable home-root.mount

# setup systemd-resolved
systemctl enable systemd-resolved.service
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

echo "${green}Generating mkinitcpio.conf${reset}"
cat >/etc/mkinitcpio.conf <<END
MODULES=(${MODULES})
BINARIES=()
FILES=()
HOOKS="base systemd autodetect modconf sd-vconsole keyboard block sd-encrypt lvm2 filesystems fsck"
COMPRESSION=zstd
END
echo "${green}Generating initrd${reset}"
mkinitcpio -p linux
mkinitcpio -p linux-lts
echo "${green}Setting root password${reset}"
echo "root:${ROOT_PASSWORD}" | chpasswd
echo "${green}Installing bootloader${reset}"
sed -r -i "s/GRUB_CMDLINE_LINUX_DEFAULT=.*$/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/" /etc/default/grub
sed -r -i "s/GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX=\"rd.luks.name=${LUKS_PARTITION_UUID_OS}=crypt-system rd.luks.options=discard ${FSPOINTS//\//\\/} consoleblank=120 apparmor=1 lsm=lockdown,yama,apparmor rw\"/" /etc/default/grub
sed -r -i "s/^GRUB_DEFAULT=.*$/GRUB_DEFAULT=saved/" /etc/default/grub
sed -r -i "s/^#GRUB_SAVEDEFAULT=true/GRUB_SAVEDEFAULT=true/" /etc/default/grub
sed -r -i "s/^#GRUB_DISABLE_SUBMENU/GRUB_DISABLE_SUBMENU=y/" /etc/default/grub

case "${IS_EFI}" in
true) grub-install --target=x86_64-efi --efi-directory=/boot/esp --bootloader-id=GRUB --recheck ;;
false) grub-install --target=i386-pc --recheck "${INSTALL_DISK}" ;;
esac
grub-mkconfig -o /boot/grub/grub.cfg
