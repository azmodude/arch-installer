#!/bin/bash

ISO="/var/lib/libvirt/images/archlinux-2021.08.23-x86_64-azmo-zfs.iso"
IMAGE="/var/lib/libvirt/images/archtest.qcow2"

set -vx
sudo virsh --connect qemu:///system destroy archtest
sudo virsh --connect qemu:///system undefine --domain archtest --remove-all-storage
sudo virt-install --name=archtest --vcpus=4 \
    --boot loader=//usr/share/OVMF/OVMF_CODE.fd \
    --memory=2048 --cdrom=${ISO} --disk \
    ${IMAGE},size=20,bus=sata --os-variant=archlinux
