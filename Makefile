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
	 BUILDISO=1 vagrant up
rename-iso:
	$(eval FILE=$(shell find . -type f -regextype posix-extended -regex "./archlinux-[0-9\.]+-x86_64.iso"))
	$(eval FILE_NO_EXT=$(shell basename $(FILE) .iso))
	-mv $(FILE) $(FILE_NO_EXT)-azmo-zfs.iso
iso: build-iso move-iso rename-iso destroy
destroy:
	vagrant destroy -f

test-vm-install:
	virt-install --name=archtest --vcpus=4 \
		--boot ${BOOT} \
        --memory=4096 --cdrom=${ISO} --disk \
        ${IMAGE},size=40,bus=sata --os-variant=archlinux
test-vm:
	virt-install --name=archtest --vcpus=4 --boot ${BOOT} --import \
        --memory=2048 --disk ${IMAGE},bus=sata --os-variant=archlinux
destroy-vm-install:
	-virsh destroy archtest
	-virsh undefine --nvram --domain "archtest" --remove-all-storage
destroy-vm:
	-virsh undefine --nvram --domain "archtest"
test-install: destroy-vm-install test-vm-install
test: destroy-vm test-vm

clean: destroy up reload
cleanssh: clean ssh


