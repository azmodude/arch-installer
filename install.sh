#!/bin/bash

# quick set all options for testing purposes in vagrant
sudo INSTALL_DISK=/dev/disk/by-id/ata-QEMU_HARDDISK_QM00001 \
    ROOT_PASSWORD=test LUKS_PASSPHRASE=test HOSTNAME_FQDN=test.azmo.ninja OS_SIZE=20 \
    SWAP_SIZE=4 ./arch_install.sh
