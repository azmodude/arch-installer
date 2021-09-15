#!/bin/bash

set -Eeuxo pipefail

red=$(tput setaf 1)
green=$(tput setaf 2)
reset=$(tput sgr0)

HOSTNAME_FQDN="$(hostnamectl hostname)"
INSTALL_DISK=/dev/disk/by-id/....
POOL="dpool"
ZFS_PARTITION_NUMBER="9"

zfs_partition_present=1

if sgdisk -p ${INSTALL_DISK} | grep -E -q "\s+${ZFS_PARTITION_NUMBER}"; then
    zfs_partition_present=0
    echo "${red}INFO${reset}: ZFS target partition ${green}${ZFS_PARTITION_NUMBER}${reset} already exists."
    echo "${red}INFO${reset} Manual touching of zfs-list.cache required (e.g. set a property)."
else
    sgdisk --new=${ZFS_PARTITION_NUMBER}:0:0 \
        -c ${ZFS_PARTITION_NUMBER}:"zfs-${POOL}" \
        -t ${ZFS_PARTITION_NUMBER}:bf01 ${INSTALL_DISK}
    partprobe && sleep 2
fi

echo "${green}Setting up and enabling ZFS${reset}"
mkdir -p /etc/zfs/zfs-list.cache
systemctl enable --now zfs-zed.service
touch /etc/zfs/zfs-list.cache/${POOL}

if [[ "${zfs_partition_present}" -ne 0 ]]; then
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
    zfs create -o mountpoint=/var/lib/docker ${POOL}/docker
    zfs create -o mountpoint=/var/lib/libvirt ${POOL}/libvirt
fi

# set cachefile for import on boot
zpool set cachefile=/etc/zfs/zpool.cache ${POOL}
# enable zfs services
systemctl enable zfs-import-cache.service
systemctl enable zfs-import.target
systemctl enable zfs.target
# enable monthly scrubbing
systemctl enable zfs-scrub@${POOL}.timer

zpool export ${POOL} && zpool import ${POOL}
zfs load-key -L "file:///etc/zfs/zfskey_${POOL}_${HOSTNAME_FQDN}" ${POOL}
zfs mount -a
