#!/bin/bash

set -Eeuxo pipefail

red=$(tput setaf 1)
green=$(tput setaf 2)
reset=$(tput sgr0)

# reboot required
HOSTNAME_FQDN=$(hostname --fqdn)
DISK=/dev/disk/by-id/....
pool="dpool"

# create a keyfile and save it to LUKS partition (later) for ZFS so it
# unlocks without entering our password twice
openssl rand -hex -out "/etc/zfs/zfskey_dpool_${HOSTNAME_FQDN}" 32
chown root:root "/etc/zfs/zfskey_dpool_${HOSTNAME_FQDN}" &&
    chmod 600 "/etc/zfs/zfskey_dpool_${HOSTNAME_FQDN}"

echo "${green}Setting up and enabling ZFS${reset}"
mkdir -p /etc/zfs/zfs-list.cache
systemctl enable --now zfs-zed.service
systemctl enable zfs.target
touch /etc/zfs/zfs-list.cache/${pool}

# setup ZFS pool
zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O encryption=aes-256-gcm \
    -O keylocation="file:///etc/zfs/zfskey_dpool_${HOSTNAME_FQDN}" \
    -O keyformat=hex -O acltype=posixacl -O compression=zstd \
    -O dnodesize=auto -O normalization=formD -O relatime=on \
    -O xattr=sa -O canmount=off -O mountpoint=/ dpool \
    -R /mnt "${INSTALL_DISK}"-part9

# setup generic ZFS datasets
zfs create -o mountpoint=/home dpool/home
chown root:root /mnt/root && chmod 700 /mnt/root
zfs create -o mountpoint=/var/lib/docker dpool/docker
zfs create -o mountpoint=/var/lib/libvirt dpool/libvirt


#zpool set cachefile=/etc/zfs/zpool.cache dpool
# enable zfs services
#systemctl enable zfs-import-cache.service
#systemctl enable zfs-import.target
#systemctl enable zfs-mount.service
#systemctl enable zfs.target
# automatically load keys on startup
systemctl enable zfs-load-key@dpool.service
# enable monthly scrubbing
systemctl enable zfs-scrub@dpool.timer
