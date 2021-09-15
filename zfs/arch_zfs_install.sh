#!/bin/bash

set -Eeuxo pipefail

ARCHZFS_KEY="DDF7DB817396A49B2A2723F7403BD972F75D9D76"

# get and lsign archzfs keys
pacman-key --keyserver keyserver.ubuntu.com -r ${ARCHZFS_KEY}
pacman-key --lsign-key ${ARCHZFS_KEY}

pacman -Sy archzfs-linux archzfs-linux-lts archzfs-linux-zen

echo "zfs installed, please reboot to activate if kernel versions changed."

