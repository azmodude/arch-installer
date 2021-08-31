#!/bin/bash

ISO="/var/lib/libvirt/images/archlinux-2021.08.31-x86_64-azmo-zfs.iso"
IMAGE="/var/lib/libvirt/images/archtest.qcow2"

sudo virsh --connect qemu:///system destroy archtest

if [[ "$1" == "install" ]]; then
    set -vx
    sudo virsh --connect qemu:///system undefine --domain archtest --remove-all-storage
    sudo virt-install --name=archtest --vcpus=4 \
        --boot loader=//usr/share/OVMF/OVMF_CODE.fd \
        --memory=2048 --cdrom=${ISO} --disk \
        ${IMAGE},size=40,bus=sata --os-variant=archlinux
else
    set -vx
    sudo virsh --connect qemu:///system undefine --domain archtest
    sudo virt-install --name=archtest --vcpus=4 \
        --boot loader=//usr/share/OVMF/OVMF_CODE.fd \
        --memory=2048 --disk ${IMAGE},bus=sata --os-variant=archlinux
fi
