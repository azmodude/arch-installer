#!/bin/bash

# quick set all options for testing purposes in vagrant
sudo INSTALL_DISK=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi3-0-4 ROOT_PASSWORD=test LUKS_PASSPHRASE=test HOSTNAME_FQDN=test.azmo.ninja OS_SIZE=5 SWAP_SIZE=1 /vagrant/arch_install.sh
