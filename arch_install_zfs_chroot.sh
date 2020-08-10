#!/bin/bash

set -Eeuxo pipefail

echo "Setting timezone and time"
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
echo "Generating and setting locale"
locale-gen
echo "Configuring hostname"
echo "${HOSTNAME_FQDN}" > /etc/hostname
cat > /etc/hosts << END
127.0.0.1   localhost.localdomain localhost
127.0.1.1   ${HOSTNAME_FQDN} ${HOSTNAME%%.*}
END

sed -r -i 's/^#(write-cache)$/\1/' /etc/apparmor/parser.conf
systemctl enable apparmor.service

zpool set cachefile=/etc/zfs/zpool.cache dpool
mkdir -p /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/dpool
ln -s /usr/lib/zfs/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d
# shellcheck disable=SC2015
zed && sleep 5 && zfs set canmount=on dpool && zfs set canmount=off dpool && \
    pkill zed || true
sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*

systemctl enable zfs-import-cache
systemctl enable zfs-import.target
systemctl enable zfs-zed.service
systemctl enable zfs-load-key.service
systemctl enable zfs.target

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
echo "Installing bootloader"
sed -r -i "s/GRUB_CMDLINE_LINUX_DEFAULT=.*$/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/" /etc/default/grub
sed -r -i "s/GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX=\"rd.luks.name=${LUKS_PARTITION_UUID_OS}=crypt-system rd.luks.options=discard ${FSPOINTS//\//\\/} consoleblank=120 apparmor=1 lsm=lockdown,yama,apparmor rw\"/" /etc/default/grub
[ "${IS_EFI}" = true ] && grub-install --target=x86_64-efi --efi-directory=/boot/esp --bootloader-id=GRUB --recheck
[ "${IS_EFI}" = false ] && grub-install --target=i386-pc --recheck ${INSTALL_DISK}
grub-mkconfig -o /boot/grub/grub.cfg
