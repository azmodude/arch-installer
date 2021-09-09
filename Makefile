-include .env.mk

.env.mk: .env
		sed 's/"//g ; s/=/:=/' < $< > $@

up:
	vagrant up
reload:
	vagrant reload
ssh:
	TERM=xterm-256color vagrant ssh
move-iso:
	-mv archlinux-*-azmo-zfs.iso old-isos
build-iso:
	VAGRANT_VAGRANTFILE=./Vagrantfile.archiso vagrant up
rename-iso-zfs:
	$(eval FILE=$(shell find . -type f -regextype posix-extended -regex "./archlinux-[0-9\.]+-x86_64.iso"))
	$(eval FILE_NO_EXT=$(shell basename $(FILE) .iso))
	mv $(FILE) $(FILE_NO_EXT)-azmo-zfs.iso
rename-iso:
	$(eval FILE=$(shell find . -type f -regextype posix-extended -regex "./archlinux-[0-9\.]+-x86_64.iso"))
	$(eval FILE_NO_EXT=$(shell basename $(FILE) .iso))
	-mv $(FILE) $(FILE_NO_EXT)-azmo.iso
iso: build-iso move-iso rename-iso destroy
destroy:
	vagrant destroy -f

test-vm-install:
	sudo virt-install --name=archtest --vcpus=4 \
        --boot loader=//usr/share/OVMF/OVMF_CODE.fd \
        --memory=2048 --cdrom=${ISO} --disk \
        ${IMAGE},size=40,bus=sata --os-variant=archlinux
test-vm:
	-sudo virsh --connect qemu:///system undefine --domain archtest
	sudo virt-install --name=archtest --vcpus=4 \
        --boot loader=//usr/share/OVMF/OVMF_CODE.fd \
        --memory=2048 --disk ${IMAGE},bus=sata --os-variant=archlinux
destroy-vm:
	-sudo virsh --connect qemu:///system destroy archtest
rm-vm:
	-sudo virsh --connect qemu:///system undefine --domain archtest --remove-all-storage
test-install: destroy-vm rm-vm test-vm-install
test: destroy-vm test-vm

clean: destroy up reload
cleanssh: clean ssh
