#!/bin/bash

ISO="/var/lib/libvirt/images/archlinux-2021.04.06-x86_64-azmo-zfs.iso"
IMAGE="/var/lib/libvirt/images/archtest.qcow2"

sudo virsh --connect qemu:///system destroy archtest
sudo virsh --connect qemu:///system undefine --domain archtest --remove-all-storage
sudo virt-install --name=archtest --vcpus=2 --memory=1024 --cdrom=${ISO} --disk ${IMAGE},size=10,bus=sata --os-variant=archlinux
