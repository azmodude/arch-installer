#!/bin/bash

set -Eeuxo pipefail

red=$(tput setaf 1)
green=$(tput setaf 2)
reset=$(tput sgr0)

HOSTNAME_FQDN=$(hostnamectl hostname)
INSTALL_DISK=/dev/disk/by-id/....
POOL="dpool"
ZFS_PARTITION_NUMBER="9"

zfs_partition_present=$(sgdisk -p ${INSTALL_DISK} | grep "^[ 0-9]" | \
    sed -r 's/^\s*([0-9]).*'/\1/ | grep ${ZFS_PARTITION_NUMBER})
if [[ -n "${zfs_partition_present}" ]]; then
    echo "ZFS partition ${ZFS_PARTITION_NUMBER} already exists." && \
    echo "Manual touching of zfs-list.cache required (e.g. set a property)."
else
    sgdisk --new=${ZFS_PARTITION_NUMBER}:0:0 \
        -c ${ZFS_PARTITION_NUMBER}:"zfs-${POOL}" \
        -t ${ZFS_PARTITION_NUMBER}:bf01 ${INSTALL_DISK}
    partprobe && sleep 2
fi

echo "${green}Setting up and enabling ZFS${reset}"
mkdir -p /etc/zfs/zfs-list.cache
systemctl enable --now zfs-zed.service
systemctl enable zfs.target
touch /etc/zfs/zfs-list.cache/${POOL}

if [[ -z "${zfs_partition_present}" ]]; then
    # create a keyfile and save it to LUKS partition (later) for ZFS so it
    # unlocks without entering our password twice
    openssl rand -hex -out "/etc/zfs/zfskey_${POOL}_${HOSTNAME_FQDN}" 32
    chown root:root "/etc/zfs/zfskey_${POOL}_${HOSTNAME_FQDN}" &&
        chmod 600 "/etc/zfs/zfskey_${POOL}_${HOSTNAME_FQDN}"

    # setup ZFS pool
    zpool create -f \
        -o ashift=12 \
        -o autotrim=on \
        -O encryption=aes-256-gcm \
        -O keylocation="file:///etc/zfs/zfskey_${POOL}_${HOSTNAME_FQDN}" \
        -O keyformat=hex -O acltype=posixacl -O compression=zstd \
        -O dnodesize=auto -O normalization=formD -O relatime=on \
        -O xattr=sa -O canmount=off -O mountpoint=/ ${POOL} \
        -R /mnt "${INSTALL_DISK}"-part"${ZFS_PARTITION_NUMBER}"

    # setup generic ZFS datasets
    zfs create -o mountpoint=/home ${POOL}/home
    chown root:root /mnt/root && chmod 700 /mnt/root
    zfs create -o mountpoint=/var/lib/docker ${POOL}/docker
    zfs create -o mountpoint=/var/lib/libvirt ${POOL}/libvirt
fi

#zpool set cachefile=/etc/zfs/zpool.cache ${POOL}
# enable zfs services
#systemctl enable zfs-import-cache.service
#systemctl enable zfs-import.target
#systemctl enable zfs-mount.service
#systemctl enable zfs.target
# automatically load keys on startup
systemctl enable zfs-load-key@${POOL}.service
# enable monthly scrubbing
systemctl enable zfs-scrub@${POOL}.timer
