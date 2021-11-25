#!/bin/bash

set -Eeuxo pipefail

ARCHZFS_KEY="DDF7DB817396A49B2A2723F7403BD972F75D9D76"

cat <<-'EOF' >> /etc/pacman.conf
[archzfs]
    Server = http://archzfs.com/$repo/x86_64
    Server = http://mirror.sum7.eu/archlinux/archzfs/$repo/$arch
    Server = https://mirror.biocrafting.net/archlinux/archzfs/$repo/$arch
    Server = https://mirror.in.themindsmaze.com/archzfs/$repo/$arch
[zfs-linux]
    Server = http://kernels.archzfs.com/$repo
EOF

# get and lsign archzfs keys
pacman-key --keyserver keyserver.ubuntu.com -r ${ARCHZFS_KEY}
pacman-key --lsign-key ${ARCHZFS_KEY}

pacman -Sy archzfs-linux archzfs-linux-lts archzfs-linux-zen

echo "zfs installed, please reboot to activate if kernel versions changed."

