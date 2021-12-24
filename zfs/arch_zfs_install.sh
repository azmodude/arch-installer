#!/bin/bash

set -Eeuxo pipefail

ARCHZFS_KEY="DDF7DB817396A49B2A2723F7403BD972F75D9D76"

[[ ! -e /etc/pacman.d/archzfs ]] && \
	cat <<-'EOF' >> /etc/pacman.d/archzfs
Server = http://archzfs.com/$repo/x86_64
Server = http://mirror.sum7.eu/archlinux/archzfs/$repo/x86_64
Server = https://mirror.biocrafting.net/archlinux/archzfs/$repo/x86_64
EOF

[[ ! -e /etc/pacman.d/archzfs-kernels ]] && echo 'Server = http://kernels.archzfs.com/$repo' > /etc/pacman.d/archzfs-kernels

if ! grep -q /etc/pacman.conf archzfs; then
	cat <<-'EOF' >> /etc/pacman.conf
[archzfs]
Include = /etc/pacman.d/archzfs
EOF
fi
if ! grep -q /etc/pacman.conf zfs-linux; then
	cat <<-'EOF' >> /etc/pacman.conf
[zfs-linux]
Include = /etc/pacman.d/archzfs-kernels
EOF
fi
if ! grep -q /etc/pacman.conf zfs-linux-lts; then
	cat <<-'EOF' >> /etc/pacman.conf
[zfs-linux-lts]
Include = /etc/pacman.d/archzfs-kernels
EOF
fi
if ! grep -q /etc/pacman.conf zfs-linux-zen; then
	cat <<-'EOF' >> /etc/pacman.conf
[zfs-linux-zen]
Include = /etc/pacman.d/archzfs-kernels
EOF
fi

# get and lsign archzfs keys
pacman-key --keyserver keyserver.ubuntu.com -r ${ARCHZFS_KEY}
pacman-key --lsign-key ${ARCHZFS_KEY}

# resize cowspace
findmnt /run/archiso/cowspace > /dev/null && mount -o remount,size=4G /run/archiso/cowspace
pacman -Sy archzfs-linux archzfs-linux-lts archzfs-linux-zen

echo "zfs installed, please reboot to activate if kernel versions changed."

